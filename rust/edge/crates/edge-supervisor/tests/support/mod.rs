use edge_protocol::{AdapterKind, Capability};
use edge_supervisor::catalog::{AdapterCatalog, CompiledAdapter};
use edge_supervisor::config::Configuration;
use edge_supervisor::discovery::{
    CandidateId, DiscoveryBus, DiscoveryCandidate, Serial, SysfsPath, Topology,
};

pub fn catalog() -> AdapterCatalog {
    AdapterCatalog::new(vec![
        CompiledAdapter::usb(
            AdapterKind::new("example.scanner").unwrap(),
            vec![Capability::new("scanner.barcode").unwrap()],
            vec![],
        )
        .unwrap(),
    ])
    .unwrap()
}

pub fn slot(id: &str, enabled: bool, extra_selector: &str) -> String {
    format!(
        r#"[[devices]]
device_id = "{id}"
enabled = {enabled}
adapter_kind = "example.scanner"
allowed_capabilities = ["scanner.barcode"]
[devices.selector]
kind = "usb"
vendor_id = 0x1234
product_id = 0x5678
{extra_selector}
"#
    )
}

pub fn config(slots: &[String]) -> Configuration {
    Configuration::parse(
        format!("schema_version = 1\n{}", slots.concat()).as_bytes(),
        &catalog(),
    )
    .unwrap()
}

pub fn topology(port: u8) -> Topology {
    Topology::from_parts(
        "/devices/pci0000:00/0000:00:14.0",
        "2.00",
        &port.to_string(),
    )
    .unwrap()
}

pub fn candidate(id: &str, serial: Option<&str>, port: u8) -> DiscoveryCandidate {
    DiscoveryCandidate {
        id: CandidateId::new(id).unwrap(),
        bus: DiscoveryBus::Usb,
        vendor_id: 0x1234,
        product_id: 0x5678,
        serial: serial.map(|s| Serial::new(s).unwrap()),
        topology: topology(port),
        sysfs_path: SysfsPath::new(&format!("/sys/devices/test/{id}")).unwrap(),
    }
}
