//! Incremental, read-only Linux sysfs enumeration. No shell, device-node open,
//! interface enumeration authority, or native unbounded inventory allocation.

use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::discovery::{
    CandidateId, DiscoveryBus, DiscoveryCandidate, DiscoveryError, DiscoverySnapshot,
    DiscoverySource, Serial, SysfsPath, Topology, valid_ports,
};
use crate::{MAX_CANDIDATES, MAX_SERIAL_BYTES, MAX_SYSFS_PATH_BYTES};

/// Includes interfaces and root hubs, so even hostile noncandidate entries
/// cannot make a snapshot spend unbounded iteration work.
pub const MAX_SYSFS_ENTRIES: usize = 4_096;
pub const MAX_UEVENT_BYTES: usize = 4_096;

pub struct LinuxUsbDiscovery {
    sysfs_root: PathBuf,
}

impl std::fmt::Debug for LinuxUsbDiscovery {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LinuxUsbDiscovery")
            .field("sysfs_root", &"[redacted]")
            .finish()
    }
}

impl Default for LinuxUsbDiscovery {
    fn default() -> Self {
        Self {
            sysfs_root: PathBuf::from("/sys"),
        }
    }
}

impl LinuxUsbDiscovery {
    /// Explicit sysfs root for deterministic synthetic filesystem tests. The
    /// production default always reads /sys; this API confers no POS role.
    pub fn with_sysfs_root(root: impl Into<PathBuf>) -> Self {
        Self {
            sysfs_root: root.into(),
        }
    }
}

fn attribute(path: &Path, max_bytes: usize) -> Result<String, DiscoveryError> {
    let file = File::open(path).map_err(|_| DiscoveryError::Io)?;
    read_attribute(file, max_bytes)
}

fn read_attribute(file: File, max_bytes: usize) -> Result<String, DiscoveryError> {
    let mut bytes = Vec::new();
    // Sysfs text attributes have one trailing newline, not selector whitespace.
    file.take((max_bytes + 2) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| DiscoveryError::Io)?;
    if bytes.last() == Some(&b'\n') {
        bytes.pop();
    }
    if bytes.len() > max_bytes {
        return Err(DiscoveryError::InvalidAttribute);
    }
    String::from_utf8(bytes).map_err(|_| DiscoveryError::InvalidAttribute)
}

fn hex_id(value: &str) -> Result<u16, DiscoveryError> {
    if value.len() != 4 || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(DiscoveryError::InvalidAttribute);
    }
    u16::from_str_radix(value, 16).map_err(|_| DiscoveryError::InvalidAttribute)
}

fn usb_device(uevent: &str) -> Result<bool, DiscoveryError> {
    let mut devtype = None;
    for line in uevent.lines() {
        if let Some(value) = line.strip_prefix("DEVTYPE=")
            && devtype.replace(value).is_some()
        {
            return Err(DiscoveryError::InvalidAttribute);
        }
    }
    match devtype {
        Some("usb_device") => Ok(true),
        Some("usb_interface") => Ok(false),
        _ => Err(DiscoveryError::InvalidAttribute),
    }
}

impl DiscoverySource for LinuxUsbDiscovery {
    fn snapshot(&self) -> Result<DiscoverySnapshot, DiscoveryError> {
        let root = fs::canonicalize(&self.sysfs_root).map_err(|_| DiscoveryError::Io)?;
        let entries = fs::read_dir(root.join("bus/usb/devices")).map_err(|_| DiscoveryError::Io)?;
        let paths = entries.map(|entry| {
            let entry = entry.map_err(|_| DiscoveryError::Io)?;
            fs::canonicalize(entry.path()).map_err(|_| DiscoveryError::Io)
        });
        snapshot_paths(&root, paths)
    }
}

// Keep traversal incremental. The iterator seam also lets tests remove a
// previously resolved target during a scan without relying on thread timing.
fn snapshot_paths(
    root: &Path,
    paths: impl Iterator<Item = Result<PathBuf, DiscoveryError>>,
) -> Result<DiscoverySnapshot, DiscoveryError> {
    let mut candidates = Vec::new();
    for (index, path) in paths.enumerate() {
        if index >= MAX_SYSFS_ENTRIES {
            return Err(DiscoveryError::ScanTooLarge);
        }
        let path = path?;
        let relative = path
            .strip_prefix(root)
            .map_err(|_| DiscoveryError::InvalidAttribute)?;
        let relative = relative.to_str().ok_or(DiscoveryError::InvalidAttribute)?;
        if relative.len() >= MAX_SYSFS_PATH_BYTES || !relative.starts_with("devices/") {
            return Err(DiscoveryError::InvalidAttribute);
        }
        if !usb_device(&attribute(&path.join("uevent"), MAX_UEVENT_BYTES)?)? {
            continue;
        }
        if candidates.len() == MAX_CANDIDATES {
            return Err(DiscoveryError::InventoryTooLarge);
        }
        // Find the root hub boundary; controller identity precedes usbN.
        let components: Vec<_> = relative.split('/').collect();
        let hub_index = components
            .iter()
            .position(|part| {
                part.strip_prefix("usb")
                    .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
            })
            .ok_or(DiscoveryError::InvalidAttribute)?;
        let hub_path = root.join(components[..=hub_index].join("/"));
        let controller = format!("/{}", components[..hub_index].join("/"));
        let ports = attribute(&path.join("devpath"), 32)?;
        if !valid_ports(&ports) {
            return Err(DiscoveryError::InvalidAttribute);
        }
        // Linux formats version as %2x.%02x (one leading space for a
        // single-digit major). Normalize only that documented padding.
        let revision = attribute(&hub_path.join("version"), 5)?;
        let revision = revision.strip_prefix(' ').unwrap_or(&revision);
        let topology = Topology::from_parts(&controller, revision, &ports)?;
        let serial = match File::open(path.join("serial")) {
            Ok(file) => Some(Serial::new(&read_attribute(file, MAX_SERIAL_BYTES)?)?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => return Err(DiscoveryError::Io),
        };
        let context = format!("/{relative}");
        candidates.push(DiscoveryCandidate {
            id: CandidateId::new(&context)?,
            bus: DiscoveryBus::Usb,
            sysfs_path: SysfsPath::new(path.to_str().ok_or(DiscoveryError::InvalidAttribute)?)?,
            vendor_id: hex_id(&attribute(&path.join("idVendor"), 4)?)?,
            product_id: hex_id(&attribute(&path.join("idProduct"), 4)?)?,
            serial,
            topology,
        });
    }
    DiscoverySnapshot::new(candidates)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    struct Fixture(PathBuf);

    impl Drop for Fixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[test]
    fn mid_scan_loss_or_malformation_never_returns_the_valid_prefix() {
        for change in 0..3 {
            let fixture = Fixture(
                std::env::temp_dir().join(format!("edge-mid-scan-{}-{change}", std::process::id())),
            );
            let hub = fixture.0.join("devices/controller/usb1");
            fs::create_dir_all(&hub).unwrap();
            fs::write(hub.join("version"), " 2.00\n").unwrap();
            let paths: Vec<_> = ["1", "2"]
                .into_iter()
                .map(|port| {
                    let path = hub.join(format!("1-{port}"));
                    fs::create_dir(&path).unwrap();
                    for (name, value) in [
                        ("uevent", "DEVTYPE=usb_device\n"),
                        ("idVendor", "1234\n"),
                        ("idProduct", "5678\n"),
                    ] {
                        fs::write(path.join(name), value).unwrap();
                    }
                    fs::write(path.join("devpath"), format!("{port}\n")).unwrap();
                    fs::canonicalize(path).unwrap()
                })
                .collect();
            let root = fs::canonicalize(&fixture.0).unwrap();
            assert_eq!(
                snapshot_paths(&root, paths.iter().cloned().map(Ok))
                    .unwrap()
                    .candidates()
                    .len(),
                2
            );
            let visited = Cell::new(0);
            let changing = paths.into_iter().enumerate().map(|(index, path)| {
                visited.set(visited.get() + 1);
                if index == 1 {
                    match change {
                        0 => fs::remove_file(path.join("idVendor")).unwrap(),
                        1 => fs::remove_dir_all(&path).unwrap(),
                        _ => fs::write(path.join("idVendor"), "private-malformed-id\n").unwrap(),
                    }
                }
                Ok(path)
            });
            let error = snapshot_paths(&root, changing).unwrap_err();
            assert_eq!(visited.get(), 2);
            assert_eq!(
                error,
                if change == 2 {
                    DiscoveryError::InvalidAttribute
                } else {
                    DiscoveryError::Io
                }
            );
            assert!(!format!("{error}: {error:?}").contains("private-"));
        }
    }
}
