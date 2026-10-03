mod support;

use edge_protocol::DeviceId;
use edge_supervisor::discovery::{DiscoveryError, DiscoverySnapshot};
use edge_supervisor::reconcile::{SlotDisposition, reconcile};
use support::*;

fn id(value: &str) -> DeviceId {
    DeviceId::new(value).unwrap()
}

#[test]
fn disabled_absent_eligible_and_ambiguous_are_distinct() {
    let disabled = config(&[slot("disabled", false, "")]);
    let enabled = config(&[slot("scanner", true, "")]);
    let empty = DiscoverySnapshot::new(vec![]).unwrap();
    assert_eq!(
        reconcile(&disabled, &empty)[&id("disabled")],
        SlotDisposition::Disabled
    );
    assert_eq!(
        reconcile(&enabled, &empty)[&id("scanner")],
        SlotDisposition::Absent
    );
    let a = candidate("a", None, 1);
    let one = DiscoverySnapshot::new(vec![a.clone()]).unwrap();
    assert_eq!(
        reconcile(&enabled, &one)[&id("scanner")],
        SlotDisposition::Eligible(a.id)
    );
    let two =
        DiscoverySnapshot::new(vec![candidate("a", None, 1), candidate("b", None, 2)]).unwrap();
    assert_eq!(
        reconcile(&enabled, &two)[&id("scanner")],
        SlotDisposition::Ambiguous
    );
    assert_eq!(
        SlotDisposition::Ambiguous.condition().unwrap().as_str(),
        "edge.discovery_ambiguous"
    );
}

#[test]
fn all_conflicting_slots_fail_closed_independent_of_input_order() {
    let slots = vec![
        slot("a", true, ""),
        slot("b", true, ""),
        slot("disabled", false, ""),
    ];
    let reversed: Vec<_> = slots.iter().cloned().rev().collect();
    let snapshot =
        DiscoverySnapshot::new(vec![candidate("physical", Some("synthetic"), 1)]).unwrap();
    let forward = reconcile(&config(&slots), &snapshot);
    assert_eq!(forward, reconcile(&config(&reversed), &snapshot));
    assert_eq!(forward[&id("a")], SlotDisposition::Conflict);
    assert_eq!(forward[&id("b")], SlotDisposition::Conflict);
    assert_eq!(forward[&id("disabled")], SlotDisposition::Disabled);
    assert_eq!(
        SlotDisposition::Conflict.condition().unwrap().as_str(),
        "edge.discovery_conflict"
    );
}

#[test]
fn independent_claims_and_ambiguity_are_order_independent() {
    let slots = vec![
        slot("a", true, "serial = \"first\""),
        slot("b", true, "serial = \"second\""),
        slot("broad", true, ""),
    ];
    let candidates = vec![
        candidate("physical-a", Some("first"), 1),
        candidate("physical-b", Some("second"), 2),
    ];
    let expected = reconcile(
        &config(&slots),
        &DiscoverySnapshot::new(candidates.clone()).unwrap(),
    );
    let reversed_slots: Vec<_> = slots.into_iter().rev().collect();
    assert_eq!(
        expected,
        reconcile(
            &config(&reversed_slots),
            &DiscoverySnapshot::new(candidates.into_iter().rev().collect()).unwrap()
        )
    );
    assert!(matches!(expected[&id("a")], SlotDisposition::Eligible(_)));
    assert!(matches!(expected[&id("b")], SlotDisposition::Eligible(_)));
    assert_eq!(expected[&id("broad")], SlotDisposition::Ambiguous);
}

#[test]
fn serial_and_topology_are_conjunctive_without_fallback() {
    let topology = topology(1);
    let configured = config(&[slot(
        "scanner",
        true,
        &format!("serial = \"exact\"\ntopology = \"{}\"", topology.as_str()),
    )]);
    let selector = configured.slots().next().unwrap().selector();
    assert!(selector.matches(&candidate("yes", Some("exact"), 1)));
    for wrong in [
        candidate("missing", None, 1),
        candidate("changed", Some("other"), 1),
        candidate("port", Some("exact"), 2),
    ] {
        assert!(!selector.matches(&wrong));
        let result = reconcile(&configured, &DiscoverySnapshot::new(vec![wrong]).unwrap());
        assert_eq!(result[&id("scanner")], SlotDisposition::Absent);
    }
    let mut wrong = candidate("wrong-vendor", Some("exact"), 1);
    wrong.vendor_id = 0xabcd;
    assert!(!selector.matches(&wrong));
    wrong.vendor_id = 0x1234;
    wrong.product_id = 0xabcd;
    assert!(!selector.matches(&wrong));
    wrong.product_id = 0x5678;
    wrong.bus = edge_supervisor::discovery::DiscoveryBus::Unsupported;
    assert!(!selector.matches(&wrong));
}

#[test]
fn inventory_limit_and_duplicate_physical_context_fail_closed() {
    let candidates: Vec<_> = (0..256)
        .map(|n| candidate(&format!("device-{n}"), None, 1))
        .collect();
    assert_eq!(
        DiscoverySnapshot::new(candidates.clone())
            .unwrap()
            .candidates()
            .len(),
        256
    );
    let mut too_many = candidates;
    too_many.push(candidate("excess", None, 1));
    assert_eq!(
        DiscoverySnapshot::new(too_many).unwrap_err(),
        DiscoveryError::InventoryTooLarge
    );
    let a = candidate("a", None, 1);
    assert_eq!(
        DiscoverySnapshot::new(vec![a.clone(), a.clone()]).unwrap_err(),
        DiscoveryError::DuplicateCandidate
    );
    let mut alias = candidate("alias", None, 1);
    alias.sysfs_path = a.sysfs_path.clone();
    assert_eq!(
        DiscoverySnapshot::new(vec![a, alias]).unwrap_err(),
        DiscoveryError::DuplicateCandidate
    );
}

#[test]
fn replug_access_context_does_not_weaken_durable_selector() {
    let configured = config(&[slot("scanner", true, "serial = \"same-unit\"")]);
    let before = candidate("old-os-path", Some("same-unit"), 1);
    let after = candidate("new-os-path", Some("same-unit"), 1);
    for physical in [before, after] {
        assert!(matches!(
            reconcile(
                &configured,
                &DiscoverySnapshot::new(vec![physical]).unwrap()
            )[&id("scanner")],
            SlotDisposition::Eligible(_)
        ));
    }
}

#[test]
fn independent_serial_only_and_topology_only_constraints_never_fall_back() {
    for extra in [
        "serial = \"expected\"".to_owned(),
        format!("topology = \"{}\"", topology(1).as_str()),
    ] {
        let configured = config(&[slot("scanner", true, &extra)]);
        for wrong in [
            candidate("missing", None, 2),
            candidate("changed", Some("changed"), 2),
        ] {
            assert_eq!(
                reconcile(&configured, &DiscoverySnapshot::new(vec![wrong]).unwrap())
                    [&id("scanner")],
                SlotDisposition::Absent
            );
        }
    }
}

#[test]
fn discovery_text_is_bounded_and_diagnostics_are_redacted() {
    use edge_supervisor::discovery::{CandidateId, Serial, SysfsPath, Topology};
    assert!(Serial::new(&"x".repeat(256)).is_ok());
    assert!(Serial::new(&"x".repeat(257)).is_err());
    for malformed in ["", "line\nbreak", "nul\0byte"] {
        assert!(Serial::new(malformed).is_err());
    }
    assert!(CandidateId::new(&"x".repeat(1_025)).is_err());
    assert!(SysfsPath::new(&"x".repeat(1_025)).is_err());
    let prefix = "sysfs:/devices/";
    let suffix = ";usb=2.00;ports=1";
    let at_limit = format!(
        "{prefix}{}{suffix}",
        "x".repeat(512 - prefix.len() - suffix.len())
    );
    assert!(Topology::new(&at_limit).is_ok());
    // A controller can legitimately have "usb" in its authored platform name;
    // only kernel usbN enumeration components are excluded from topology.
    assert!(Topology::new("sysfs:/devices/platform/usb-host;usb=2.00;ports=1").is_ok());
    assert!(Topology::new(&at_limit.replace("/devices/", "/devices/x")).is_err());
    for malformed in [
        "/dev/input/event7",
        "sysfs:/devices/usb1;usb=2.00;ports=1",
        "sysfs:/devices/controller;usb=2.00;ports=01",
        "sysfs:/devices/../controller;usb=2.00;ports=1",
    ] {
        assert!(Topology::new(malformed).is_err());
    }
    let candidate = candidate("private-context", Some("private-serial"), 1);
    let diagnostic = format!("{candidate:?}");
    assert!(!diagnostic.contains("private-context"));
    assert!(!diagnostic.contains("private-serial"));
    assert!(!diagnostic.contains("pci0000"));
}

#[test]
fn sysfs_context_rejects_noncanonical_path_spellings() {
    use edge_supervisor::discovery::SysfsPath;
    for path in [
        "sys/devices/unit",
        "/sys/devices/./unit",
        "/sys/devices/other/../unit",
        "/sys//devices/unit",
        "/sys/devices/unit/",
        "/",
    ] {
        assert_eq!(
            SysfsPath::new(path).unwrap_err(),
            DiscoveryError::InvalidAttribute
        );
    }
    assert!(SysfsPath::new("/sys/devices/unit").is_ok());
}

#[test]
fn broad_ambiguity_becomes_global_conflict_when_the_other_candidate_disappears() {
    let slots = [
        slot("broad", true, ""),
        slot("specific", true, "serial = \"x\""),
        slot("disabled", false, ""),
    ];
    let x = candidate("x", Some("x"), 1);
    let y = candidate("y", Some("y"), 2);
    // Exercise all six slot permutations and both candidate orders, starting
    // with deliberately unsorted input rather than a pre-sorted fixture.
    for order in [
        [2, 1, 0],
        [2, 0, 1],
        [1, 2, 0],
        [1, 0, 2],
        [0, 2, 1],
        [0, 1, 2],
    ] {
        let configured = config(&order.map(|n| slots[n].clone()));
        for candidates in [vec![y.clone(), x.clone()], vec![x.clone(), y.clone()]] {
            let result = reconcile(&configured, &DiscoverySnapshot::new(candidates).unwrap());
            assert_eq!(result[&id("broad")], SlotDisposition::Ambiguous);
            assert_eq!(
                result[&id("specific")],
                SlotDisposition::Eligible(x.id.clone())
            );
            assert_eq!(result[&id("disabled")], SlotDisposition::Disabled);
            assert_eq!(
                result.keys().map(|key| key.as_str()).collect::<Vec<_>>(),
                ["broad", "disabled", "specific"]
            );
        }
        let result = reconcile(
            &configured,
            &DiscoverySnapshot::new(vec![x.clone()]).unwrap(),
        );
        assert_eq!(result[&id("broad")], SlotDisposition::Conflict);
        assert_eq!(result[&id("specific")], SlotDisposition::Conflict);
        assert_eq!(result[&id("disabled")], SlotDisposition::Disabled);
    }
    let configured = config(&[slot("disabled", false, ""), slot("enabled", true, "")]);
    let result = reconcile(
        &configured,
        &DiscoverySnapshot::new(vec![x.clone()]).unwrap(),
    );
    assert_eq!(result[&id("disabled")], SlotDisposition::Disabled);
    assert_eq!(result[&id("enabled")], SlotDisposition::Eligible(x.id));
}

#[test]
fn different_adapter_roles_cannot_share_one_candidate() {
    use edge_protocol::{AdapterKind, Capability};
    use edge_supervisor::{
        catalog::{AdapterCatalog, CompiledAdapter},
        config::Configuration,
    };
    let catalog = AdapterCatalog::new(vec![
        CompiledAdapter::usb(
            AdapterKind::new("example.scanner").unwrap(),
            vec![Capability::new("scanner.barcode").unwrap()],
            vec![],
        )
        .unwrap(),
        CompiledAdapter::usb(
            AdapterKind::new("example.printer").unwrap(),
            vec![Capability::new("printer.status").unwrap()],
            vec![],
        )
        .unwrap(),
    ])
    .unwrap();
    let scanner = slot("scanner", true, "");
    let printer = slot("printer", true, "")
        .replace("example.scanner", "example.printer")
        .replace("scanner.barcode", "printer.status");
    for text in [
        format!("schema_version = 1\n{scanner}{printer}"),
        format!("schema_version = 1\n{printer}{scanner}"),
    ] {
        let config = Configuration::parse(text.as_bytes(), &catalog).unwrap();
        let result = reconcile(
            &config,
            &DiscoverySnapshot::new(vec![candidate("one", None, 1)]).unwrap(),
        );
        assert_eq!(result[&id("scanner")], SlotDisposition::Conflict);
        assert_eq!(result[&id("printer")], SlotDisposition::Conflict);
    }
}

#[test]
fn utf8_candidate_limits_and_port_grammar_are_exact() {
    use edge_supervisor::discovery::{CandidateId, Serial, SysfsPath, Topology};
    let serial = "🦀".repeat(64);
    assert!(Serial::new(&serial).is_ok());
    assert_eq!(
        Serial::new(&format!("{serial}x")).unwrap_err(),
        DiscoveryError::InvalidAttribute
    );
    let id = "🦀".repeat(256);
    assert!(CandidateId::new(&id).is_ok());
    assert!(CandidateId::new(&format!("{id}x")).is_err());
    let path = format!("/{}xxx", "🦀".repeat(255));
    assert_eq!(path.len(), 1024);
    assert!(SysfsPath::new(&path).is_ok());
    assert!(SysfsPath::new(&format!("{path}x")).is_err());
    for valid in ["0", "1", "255", "1.2.3.4.5.6.7"] {
        Topology::from_parts("/devices/controller", "2.00", valid).unwrap();
    }
    for invalid in [
        "",
        "00",
        "0.1",
        "1.0",
        "-1",
        "256",
        "01",
        "1..2",
        ".1",
        "1.",
        "1:1.0",
        "1.2.3.4.5.6.7.8",
    ] {
        assert_eq!(
            Topology::from_parts("/devices/controller", "2.00", invalid).unwrap_err(),
            DiscoveryError::InvalidAttribute
        );
    }
    assert!(Topology::from_parts("/devices/🦀", "2.00", "1").is_err());
}
