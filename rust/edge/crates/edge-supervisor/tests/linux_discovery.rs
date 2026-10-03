#![cfg(target_os = "linux")]

use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use edge_supervisor::discovery::{DiscoveryError, DiscoverySource};
use edge_supervisor::linux::{LinuxUsbDiscovery, MAX_SYSFS_ENTRIES};

static NEXT: AtomicU64 = AtomicU64::new(0);

struct SysfsFixture(PathBuf);

impl SysfsFixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "edge-sysfs-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        let fixture = Self(root);
        fs::create_dir_all(fixture.0.join("bus/usb/devices")).unwrap();
        fixture.hub(1);
        fixture
    }

    fn hub(&self, bus: u16) -> PathBuf {
        let hub = self
            .0
            .join(format!("devices/pci0000:00/0000:00:14.0/usb{bus}"));
        fs::create_dir_all(&hub).unwrap();
        // Kernel sysfs.c uses %2x.%02x, including a leading space.
        fs::write(hub.join("version"), " 2.00\n").unwrap();
        hub
    }

    fn device(&self, bus: u16, port: &str) -> PathBuf {
        let name = format!("{bus}-{port}");
        let path = self.hub(bus).join(&name);
        fs::create_dir_all(&path).unwrap();
        for (key, value) in [
            ("uevent", "DEVTYPE=usb_device\n"),
            ("idVendor", "1234\n"),
            ("idProduct", "5678\n"),
        ] {
            fs::write(path.join(key), value).unwrap();
        }
        fs::write(path.join("devpath"), format!("{port}\n")).unwrap();
        symlink(&path, self.0.join("bus/usb/devices").join(name)).unwrap();
        path
    }

    fn source(&self) -> LinuxUsbDiscovery {
        LinuxUsbDiscovery::with_sysfs_root(&self.0)
    }
}

impl Drop for SysfsFixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

#[test]
fn physical_device_snapshot_excludes_interfaces_and_unread_descriptors() {
    let fixture = SysfsFixture::new();
    let device = fixture.device(1, "2.3");
    fs::write(device.join("serial"), "synthetic-unit\n").unwrap();
    // Descriptors unrelated to matching must never be read/copied/logged.
    fs::write(device.join("manufacturer"), vec![0xff; 100_000]).unwrap();
    fs::write(device.join("descriptors"), vec![0xff; 100_000]).unwrap();
    fs::write(device.join("bos_descriptors"), vec![0xff; 100_000]).unwrap();
    let interface = device.join("1-2.3:1.0");
    fs::create_dir(&interface).unwrap();
    fs::write(interface.join("uevent"), "DEVTYPE=usb_interface\n").unwrap();
    symlink(&interface, fixture.0.join("bus/usb/devices/1-2.3:1.0")).unwrap();
    let snapshot = fixture.source().snapshot().unwrap();
    assert_eq!(snapshot.candidates().len(), 1);
    let candidate = &snapshot.candidates()[0];
    assert_eq!(candidate.vendor_id, 0x1234);
    assert_eq!(candidate.product_id, 0x5678);
    assert_eq!(
        candidate.serial.as_ref().unwrap().as_str(),
        "synthetic-unit"
    );
    assert_eq!(
        candidate.topology.as_str(),
        "sysfs:/devices/pci0000:00/0000:00:14.0;usb=2.00;ports=2.3"
    );
    assert!(!format!("{snapshot:?}").contains("synthetic-unit"));
}

#[test]
fn bus_renumbering_changes_access_context_but_not_port_identity() {
    let fixture = SysfsFixture::new();
    fixture.device(1, "2");
    let before = fixture.source().snapshot().unwrap().candidates()[0].clone();
    fs::remove_file(fixture.0.join("bus/usb/devices/1-2")).unwrap();
    fixture.device(42, "2");
    let after = fixture.source().snapshot().unwrap().candidates()[0].clone();
    assert_eq!(before.topology, after.topology);
    assert_ne!(before.id, after.id);
    assert_ne!(before.sysfs_path, after.sysfs_path);
}

#[test]
fn malformed_or_unbounded_attributes_reject_the_entire_snapshot() {
    let cases: &[(&str, &[u8])] = &[
        ("idVendor", b"xyz\n"),
        ("idProduct", b"10000\n"),
        ("serial", b"bad\nembedded\n"),
        ("serial", &[0xff]),
        ("devpath", b"1..2\n"),
        ("uevent", b"DEVTYPE=pci_device\n"),
        ("uevent", b"DEVTYPE=usb_device\nDEVTYPE=usb_device\n"),
    ];
    for (attribute, bytes) in cases {
        let fixture = SysfsFixture::new();
        let path = fixture.device(1, "1");
        fs::write(path.join(attribute), bytes).unwrap();
        assert_eq!(
            fixture.source().snapshot().unwrap_err(),
            DiscoveryError::InvalidAttribute
        );
    }
    for attribute in ["serial", "uevent", "devpath"] {
        let fixture = SysfsFixture::new();
        fs::write(fixture.device(1, "1").join(attribute), vec![b'x'; 65_536]).unwrap();
        assert_eq!(
            fixture.source().snapshot().unwrap_err(),
            DiscoveryError::InvalidAttribute
        );
    }
}

#[test]
fn missing_serial_stays_missing_and_required_attribute_loss_fails_closed() {
    let fixture = SysfsFixture::new();
    let device = fixture.device(1, "1");
    assert!(
        fixture.source().snapshot().unwrap().candidates()[0]
            .serial
            .is_none()
    );
    fs::write(device.join("serial"), "before\n").unwrap();
    assert!(
        fixture.source().snapshot().unwrap().candidates()[0]
            .serial
            .is_some()
    );
    fs::remove_file(device.join("serial")).unwrap();
    assert!(
        fixture.source().snapshot().unwrap().candidates()[0]
            .serial
            .is_none()
    );
    fs::remove_file(device.join("idVendor")).unwrap();
    assert_eq!(fixture.source().snapshot().unwrap_err(), DiscoveryError::Io);
}

#[test]
fn real_backend_capacity_is_256_not_a_truncated_first_match_list() {
    let fixture = SysfsFixture::new();
    for n in 1..=256 {
        fixture.device(1, &format!("{}.{}", (n - 1) / 255 + 1, (n - 1) % 255 + 1));
    }
    assert_eq!(fixture.source().snapshot().unwrap().candidates().len(), 256);
    fixture.device(1, "3.1");
    assert_eq!(
        fixture.source().snapshot().unwrap_err(),
        DiscoveryError::InventoryTooLarge
    );
}

#[test]
fn noncandidate_scan_work_is_bounded_and_symlink_aliases_fail_closed() {
    let fixture = SysfsFixture::new();
    let path = fixture.device(1, "1");
    symlink(&path, fixture.0.join("bus/usb/devices/alias")).unwrap();
    assert_eq!(
        fixture.source().snapshot().unwrap_err(),
        DiscoveryError::DuplicateCandidate
    );
    fs::remove_file(fixture.0.join("bus/usb/devices/alias")).unwrap();
    fs::write(path.join("uevent"), "DEVTYPE=usb_interface\n").unwrap();
    for n in 1..MAX_SYSFS_ENTRIES {
        symlink(
            &path,
            fixture.0.join(format!("bus/usb/devices/interface-{n}")),
        )
        .unwrap();
    }
    assert!(fixture.source().snapshot().unwrap().candidates().is_empty());
    symlink(&path, fixture.0.join("bus/usb/devices/excess")).unwrap();
    assert_eq!(
        fixture.source().snapshot().unwrap_err(),
        DiscoveryError::ScanTooLarge
    );
}

#[test]
fn syspath_outside_sysfs_devices_is_rejected() {
    let fixture = SysfsFixture::new();
    symlink(Path::new("/tmp"), fixture.0.join("bus/usb/devices/outside")).unwrap();
    assert_eq!(
        fixture.source().snapshot().unwrap_err(),
        DiscoveryError::InvalidAttribute
    );
}

#[test]
fn discovery_source_debug_redacts_the_configured_filesystem_root() {
    let fixture = SysfsFixture::new();
    assert!(!format!("{:?}", fixture.source()).contains(fixture.0.to_str().unwrap()));
}

#[test]
fn serial_normalization_removes_only_one_final_lf_and_preserves_spaces() {
    let fixture = SysfsFixture::new();
    let path = fixture.device(1, "1");
    for (raw, expected) in [
        ("unit\n", "unit"),
        ("unit", "unit"),
        (" unit \n", " unit "),
        ("  \n", "  "),
    ] {
        fs::write(path.join("serial"), raw).unwrap();
        let snapshot = fixture.source().snapshot().unwrap();
        assert_eq!(
            snapshot.candidates()[0].serial.as_ref().unwrap().as_str(),
            expected
        );
    }
    let at_limit = "🦀".repeat(64);
    fs::write(path.join("serial"), format!("{at_limit}\n")).unwrap();
    assert_eq!(
        fixture.source().snapshot().unwrap().candidates()[0]
            .serial
            .as_ref()
            .unwrap()
            .as_str(),
        at_limit
    );
    for raw in [
        "".to_owned(),
        "\n".to_owned(),
        "unit\n\n".to_owned(),
        "unit\t\n".to_owned(),
        "unit\0\n".to_owned(),
        "unit\r\n".to_owned(),
        format!("{at_limit}x\n"),
    ] {
        fs::write(path.join("serial"), raw).unwrap();
        assert_eq!(
            fixture.source().snapshot().unwrap_err(),
            DiscoveryError::InvalidAttribute
        );
    }
}

#[test]
fn hex_identity_and_uevent_byte_bounds_follow_the_sysfs_abi() {
    let fixture = SysfsFixture::new();
    let path = fixture.device(1, "1");
    for (raw, expected) in [
        ("0000\n", 0),
        ("ffff\n", 65535),
        ("FFFF\n", 65535),
        ("aB12\n", 0xab12),
    ] {
        fs::write(path.join("idVendor"), raw).unwrap();
        assert_eq!(
            fixture.source().snapshot().unwrap().candidates()[0].vendor_id,
            expected
        );
    }
    for raw in [
        "", "\n", "123", "12345", "-123", "0x1234", "g123", " 1234\n", "1234 \n", "1234\n\n",
    ] {
        fs::write(path.join("idVendor"), raw).unwrap();
        assert_eq!(
            fixture.source().snapshot().unwrap_err(),
            DiscoveryError::InvalidAttribute
        );
    }
    fs::write(path.join("idVendor"), "1234\n").unwrap();
    let mut uevent = "DEVTYPE=usb_device\nIGNORED=".to_owned();
    uevent.push_str(&"🦀".repeat((4096 - uevent.len()) / 4));
    uevent.extend(std::iter::repeat_n('x', 4096 - uevent.len()));
    assert_eq!(uevent.len(), 4096);
    fs::write(path.join("uevent"), format!("{uevent}\n")).unwrap();
    assert_eq!(fixture.source().snapshot().unwrap().candidates().len(), 1);
    fs::write(path.join("uevent"), format!("{uevent}x\n")).unwrap();
    assert_eq!(
        fixture.source().snapshot().unwrap_err(),
        DiscoveryError::InvalidAttribute
    );
}

#[test]
fn root_and_external_hubs_are_physical_candidates_but_interfaces_are_not() {
    let fixture = SysfsFixture::new();
    let root_hub = fixture.hub(1);
    for (attribute, value) in [
        ("uevent", "DEVTYPE=usb_device\n"),
        ("idVendor", "1d6b\n"),
        ("idProduct", "0002\n"),
        ("devpath", "0\n"),
    ] {
        fs::write(root_hub.join(attribute), value).unwrap();
    }
    symlink(&root_hub, fixture.0.join("bus/usb/devices/usb1")).unwrap();
    let hub = fixture.device(1, "1");
    fs::write(hub.join("idVendor"), "05e3\n").unwrap();
    let child = fixture.device(1, "1.4");
    fs::remove_file(fixture.0.join("bus/usb/devices/1-1.4")).unwrap();
    let nested = hub.join("1-1.4");
    fs::rename(&child, &nested).unwrap();
    symlink(&nested, fixture.0.join("bus/usb/devices/1-1.4")).unwrap();
    for device in [&hub, &nested] {
        for number in 0..2 {
            let name = format!(
                "{}:1.{number}",
                device.file_name().unwrap().to_str().unwrap()
            );
            let interface = device.join(&name);
            fs::create_dir(&interface).unwrap();
            fs::write(interface.join("uevent"), "DEVTYPE=usb_interface\n").unwrap();
            symlink(&interface, fixture.0.join("bus/usb/devices").join(name)).unwrap();
        }
    }
    let snapshot = fixture.source().snapshot().unwrap();
    assert_eq!(snapshot.candidates().len(), 3);
    assert_eq!(
        snapshot
            .candidates()
            .iter()
            .map(|c| c.topology.as_str().rsplit_once(";ports=").unwrap().1)
            .collect::<Vec<_>>(),
        ["0", "1", "1.4"]
    );
    assert_eq!(
        snapshot.candidates()[2].sysfs_path.as_str(),
        nested.to_str().unwrap()
    );
}

#[test]
fn broken_looped_or_nondirectory_entries_reject_the_whole_snapshot() {
    let fixture = SysfsFixture::new();
    let device = fixture.device(1, "1");
    let bad = fixture.0.join("bus/usb/devices/bad");
    symlink(&bad, &bad).unwrap();
    assert_eq!(fixture.source().snapshot().unwrap_err(), DiscoveryError::Io);
    fs::remove_file(&bad).unwrap();
    symlink(device.join("missing"), &bad).unwrap();
    assert_eq!(fixture.source().snapshot().unwrap_err(), DiscoveryError::Io);
    fs::remove_file(&bad).unwrap();
    let file = fixture.hub(1).join("ordinary-file");
    fs::write(&file, "private-path-sentinel").unwrap();
    symlink(&file, &bad).unwrap();
    let error = fixture.source().snapshot().unwrap_err();
    assert_eq!(error, DiscoveryError::Io);
    assert!(!format!("{error}: {error:?}").contains("private-"));
    assert!(std::error::Error::source(&error).is_none());
    fs::remove_file(&bad).unwrap();
    // A lexical alias resolves to the same kernel target and is rejected.
    symlink(device.join(".").join("..").join("1-1"), &bad).unwrap();
    assert_eq!(
        fixture.source().snapshot().unwrap_err(),
        DiscoveryError::DuplicateCandidate
    );
}
