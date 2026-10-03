use edge_protocol::{AdapterKind, AgentInstanceId, Capability, DeviceAvailability};
use edge_supervisor::{
    catalog::{AdapterCatalog, CompiledAdapter},
    config::{ConfigError, Configuration},
};

fn catalog() -> AdapterCatalog {
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

const MINIMAL: &str = r#"schema_version = 1
[[devices]]
device_id = "lane-01.scanner"
enabled = true
adapter_kind = "example.scanner"
allowed_capabilities = ["scanner.barcode"]
[devices.selector]
kind = "usb"
vendor_id = 0x1234
product_id = 0x5678
"#;

#[test]
fn minimal_scanner_seed_is_unbound_observation_authority() {
    let config = Configuration::parse(MINIMAL.as_bytes(), &catalog()).unwrap();
    let seeds = config.core_seeds(&AgentInstanceId::new("agent").unwrap());
    assert_eq!(seeds.len(), 1);
    let seed = &seeds[0];
    assert_eq!(seed.snapshot.availability, DeviceAvailability::Absent);
    assert_eq!(seed.snapshot.adapter_kind.as_str(), "example.scanner");
    assert!(seed.snapshot.binding_instance_id.is_none());
    assert!(seed.snapshot.capabilities.is_empty());
    assert!(seed.snapshot.conditions.is_empty());
    assert_eq!(seed.snapshot.state_revision.get(), 0);
    assert_eq!(seed.allowed_capabilities[0].as_str(), "scanner.barcode");
    assert!(seed.capability_resources.is_empty());
}

#[test]
fn strict_toml_and_authorization_fail_closed() {
    let cases = [
        MINIMAL.replace("schema_version = 1", "schema_version = 2"),
        MINIMAL.replace("schema_version = 1", ""),
        MINIMAL.replace("schema_version = 1", "schema_version = 1\nunknown = true"),
        MINIMAL.replace("enabled = true", "enabled = true\nunknown = true"),
        format!("{MINIMAL}unknown = true\n"),
        format!("{MINIMAL}vendor_id = 1\n"),
        MINIMAL.replace("example.scanner", "missing.scanner"),
        MINIMAL.replace("scanner.barcode", "unsupported.capability"),
        MINIMAL.replace("lane-01.scanner", ""),
        MINIMAL.replace("lane-01.scanner", "/dev/hidraw3"),
        MINIMAL.replace("example.scanner", ""),
        MINIMAL.replace("example.scanner", "../adapter.so"),
        MINIMAL.replace("scanner.barcode", ""),
        MINIMAL.replace("scanner.barcode", "bad capability"),
        MINIMAL.replace("enabled = true", "enabled = \"true\""),
        MINIMAL.replace("scanner.barcode", "scanner.barcode\", \"scanner.barcode"),
        MINIMAL.replace("[\"scanner.barcode\"]", "[]"),
        MINIMAL.replace("kind = \"usb\"", "kind = \"serial\""),
        MINIMAL.replace("vendor_id = 0x1234", "vendor_id = -1"),
        MINIMAL.replace("vendor_id = 0x1234", "vendor_id = 65536"),
        MINIMAL.replace("product_id = 0x5678", "product_id = -1"),
        MINIMAL.replace("product_id = 0x5678", "product_id = 65536"),
        MINIMAL.replace("vendor_id = 0x1234\nproduct_id = 0x5678", ""),
        format!("{MINIMAL}serial = \"{}\"\n", "a".repeat(257)),
        format!("{MINIMAL}topology = \"{}\"\n", "a".repeat(513)),
        format!("{MINIMAL}serial = \"\"\n"),
        format!("{MINIMAL}topology = \"/dev/bus/usb/003/014\"\n"),
        format!(
            "{MINIMAL}[[devices]]{}",
            MINIMAL.split_once("[[devices]]").unwrap().1
        ),
    ];
    for (index, input) in cases.iter().enumerate() {
        assert!(
            Configuration::parse(input.as_bytes(), &catalog()).is_err(),
            "case {index}"
        );
    }
    assert_eq!(
        Configuration::parse(&[0xff], &catalog()).unwrap_err(),
        ConfigError::InvalidUtf8
    );
    assert_eq!(
        Configuration::parse(&vec![b' '; 65_537], &catalog()).unwrap_err(),
        ConfigError::TooLarge
    );
}

#[test]
fn exact_serial_topology_and_usb_integer_boundaries_are_valid() {
    for extra in [
        "serial = \"synthetic-unit\"\n".to_owned(),
        "topology = \"sysfs:/devices/pci0000:00/0000:00:14.0;usb=2.00;ports=1.4\"\n".to_owned(),
        "serial = \"synthetic-unit\"\ntopology = \"sysfs:/devices/pci0000:00/0000:00:14.0;usb=2.00;ports=1.4\"\n".to_owned(),
        format!("serial = \"{}\"\n", "a".repeat(256)),
    ] {
        Configuration::parse(format!("{MINIMAL}{extra}").as_bytes(), &catalog()).unwrap();
    }
    for bound in [0, 65535] {
        let input = MINIMAL
            .replace("0x1234", &bound.to_string())
            .replace("0x5678", &bound.to_string());
        Configuration::parse(input.as_bytes(), &catalog()).unwrap();
    }
}

#[test]
fn configuration_file_and_slot_bounds_are_exact() {
    let empty = Configuration::parse(
        b"schema_version = 1\ndevices = []\n",
        &AdapterCatalog::new(vec![]).unwrap(),
    )
    .unwrap();
    assert_eq!(empty.slots().count(), 0);
    let mut at_limit = MINIMAL.to_owned();
    at_limit.push('#');
    at_limit.extend(std::iter::repeat_n('x', 65_536 - at_limit.len()));
    Configuration::parse(at_limit.as_bytes(), &catalog()).unwrap();
    at_limit.push('x');
    assert_eq!(
        Configuration::parse(at_limit.as_bytes(), &catalog()).unwrap_err(),
        ConfigError::TooLarge
    );
    let build = |count| {
        let mut text = "schema_version = 1\n".to_owned();
        for n in 0..count {
            text.push_str(
                &MINIMAL
                    .split_once("\n")
                    .unwrap()
                    .1
                    .replace("lane-01.scanner", &format!("slot-{n}")),
            );
        }
        text
    };
    assert_eq!(
        Configuration::parse(build(32).as_bytes(), &catalog())
            .unwrap()
            .slots()
            .count(),
        32
    );
    assert_eq!(
        Configuration::parse(build(33).as_bytes(), &catalog()).unwrap_err(),
        ConfigError::TooManyDevices
    );
}

#[test]
fn loader_reads_only_a_bounded_file_and_never_rewrites_it() {
    use std::fs;
    let path = std::env::temp_dir().join(format!("edge-config-{}.toml", std::process::id()));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .unwrap();
    use std::io::Write;
    file.write_all(MINIMAL.as_bytes()).unwrap();
    drop(file);
    Configuration::load(&path, &catalog()).unwrap();
    assert_eq!(fs::read(&path).unwrap(), MINIMAL.as_bytes());
    fs::write(&path, vec![b' '; 65_537]).unwrap();
    assert_eq!(
        Configuration::load(&path, &catalog()).unwrap_err(),
        ConfigError::TooLarge
    );
    fs::remove_file(&path).unwrap();
    assert_eq!(
        Configuration::load(&path, &catalog()).unwrap_err(),
        ConfigError::Io
    );
}

#[test]
fn resource_groups_share_only_within_a_slot_and_seed_order_is_stable() {
    let capabilities: Vec<_> = ["receipt.print", "printer.status", "drawer.open"]
        .into_iter()
        .map(|s| Capability::new(s).unwrap())
        .collect();
    let catalog = AdapterCatalog::new(vec![
        CompiledAdapter::usb(
            AdapterKind::new("example.printer").unwrap(),
            capabilities,
            vec![
                (Capability::new("receipt.print").unwrap(), 0),
                (Capability::new("drawer.open").unwrap(), 0),
            ],
        )
        .unwrap(),
    ])
    .unwrap();
    let printer = MINIMAL
        .replace("example.scanner", "example.printer")
        .replace(
            "scanner.barcode",
            "receipt.print\", \"printer.status\", \"drawer.open",
        );
    let slot = printer.split_once("\n").unwrap().1;
    let a = slot.replace("lane-01.scanner", "a");
    let b = slot
        .replace("lane-01.scanner", "b")
        .replace("enabled = true", "enabled = false");
    let parse = |s: &str| {
        Configuration::parse(s.as_bytes(), &catalog)
            .unwrap()
            .core_seeds(&AgentInstanceId::new("agent").unwrap())
    };
    let forward = parse(&format!("schema_version = 1\n{a}{b}"));
    let reverse = parse(&format!("schema_version = 1\n{b}{a}"));
    for (f, r) in forward.iter().zip(&reverse) {
        assert_eq!(f.snapshot, r.snapshot);
        assert_eq!(f.allowed_capabilities, r.allowed_capabilities);
        assert_eq!(f.capability_resources, r.capability_resources);
        assert_eq!(f.capability_resources.len(), 2);
        assert_eq!(f.capability_resources[0].1, f.capability_resources[1].1);
        assert_eq!(f.allowed_capabilities.len(), 3);
    }
    assert_ne!(
        forward[0].capability_resources[0].1,
        forward[1].capability_resources[0].1
    );
    assert_eq!(
        forward[1].snapshot.availability,
        DeviceAvailability::Disabled
    );
}

#[test]
fn compiled_catalog_does_not_accept_duplicate_or_invented_authority() {
    use edge_supervisor::catalog::CatalogError;
    let cap = Capability::new("scanner.barcode").unwrap();
    let kind = AdapterKind::new("example.scanner").unwrap();
    assert_eq!(
        CompiledAdapter::usb(kind.clone(), vec![cap.clone(), cap.clone()], vec![]).unwrap_err(),
        CatalogError::InvalidCapabilities
    );
    assert_eq!(
        CompiledAdapter::usb(
            kind.clone(),
            vec![cap.clone()],
            vec![(Capability::new("arbitrary.command").unwrap(), 0)]
        )
        .unwrap_err(),
        CatalogError::InvalidCommandGroups
    );
    assert_eq!(
        CompiledAdapter::usb(
            kind.clone(),
            vec![cap.clone()],
            vec![(cap.clone(), 0), (cap.clone(), 1)]
        )
        .unwrap_err(),
        CatalogError::InvalidCommandGroups
    );
    let adapter = CompiledAdapter::usb(kind, vec![cap], vec![]).unwrap();
    assert_eq!(
        AdapterCatalog::new(vec![adapter.clone(), adapter]).unwrap_err(),
        CatalogError::DuplicateAdapter
    );
}

#[test]
fn capability_bounds_and_parser_nesting_are_not_unbounded() {
    let capabilities: Vec<_> = (0..32)
        .map(|n| Capability::new(format!("observation.{n}")).unwrap())
        .collect();
    let catalog = AdapterCatalog::new(vec![
        CompiledAdapter::usb(
            AdapterKind::new("example.scanner").unwrap(),
            capabilities,
            vec![],
        )
        .unwrap(),
    ])
    .unwrap();
    let list = |count| {
        (0..count)
            .map(|n| format!("\"observation.{n}\""))
            .collect::<Vec<_>>()
            .join(",")
    };
    let valid = MINIMAL.replace("\"scanner.barcode\"", &list(32));
    assert_eq!(
        Configuration::parse(valid.as_bytes(), &catalog)
            .unwrap()
            .core_seeds(&AgentInstanceId::new("a").unwrap())[0]
            .allowed_capabilities
            .len(),
        32
    );
    let excess = MINIMAL.replace("\"scanner.barcode\"", &list(33));
    assert_eq!(
        Configuration::parse(excess.as_bytes(), &catalog).unwrap_err(),
        ConfigError::InvalidCapabilities
    );
    let deeply_nested = format!(
        "schema_version = 1\ndevices = {}{}",
        "[".repeat(1_000),
        "]".repeat(1_000)
    );
    assert!(Configuration::parse(deeply_nested.as_bytes(), &catalog).is_err());
}

#[test]
fn hostile_toml_fails_at_the_typed_boundary_for_enabled_and_disabled_slots() {
    let mut cases = vec![
        String::new(),
        "# comments only\n".to_owned(),
        "schema_version = 1\n".to_owned(),
        MINIMAL.replace(
            "schema_version = 1",
            "schema_version = 1\nschema_version = 1",
        ),
        MINIMAL.replace("schema_version = 1", "schema_version = \"1\""),
        MINIMAL.replace("schema_version = 1", "schema_version = -1"),
        MINIMAL.replace("device_id = \"lane-01.scanner\"", "device_id = 1"),
        MINIMAL.replace("adapter_kind = \"example.scanner\"", "adapter_kind = []"),
        MINIMAL.replace(
            "allowed_capabilities = [\"scanner.barcode\"]",
            "allowed_capabilities = \"scanner.barcode\"",
        ),
        format!("{MINIMAL}serial = false\n"),
        format!("{MINIMAL}topology = []\n"),
        MINIMAL.replace("kind = \"usb\"", "kind = 1"),
        MINIMAL.replace("kind = \"usb\"", "kind = \"hidraw\""),
    ];
    for field in ["vendor_id = 0x1234", "product_id = 0x5678"] {
        let name = field.split_once(" = ").unwrap().0;
        for value in [
            "-1",
            "65536",
            "9223372036854775808",
            "[]",
            "{}",
            "\"1234\"",
            "true",
            "1.0",
        ] {
            cases.push(MINIMAL.replace(field, &format!("{name} = {value}")));
        }
    }
    for (index, input) in cases.iter().enumerate() {
        for enabled in [true, false] {
            let input = input.replace("enabled = true", &format!("enabled = {enabled}"));
            assert_eq!(
                Configuration::parse(input.as_bytes(), &catalog()).unwrap_err(),
                ConfigError::InvalidToml,
                "case {index}"
            );
        }
    }
    for enabled in [true, false] {
        let input = MINIMAL.replace("enabled = true", &format!("enabled = {enabled}"));
        assert_eq!(
            Configuration::parse(
                input
                    .replace("example.scanner", "missing.scanner")
                    .as_bytes(),
                &catalog()
            )
            .unwrap_err(),
            ConfigError::UnknownAdapter
        );
        assert_eq!(
            Configuration::parse(
                format!("{input}serial = \"\\u0000\"\n").as_bytes(),
                &catalog()
            )
            .unwrap_err(),
            ConfigError::InvalidSelector
        );
        assert_eq!(
            Configuration::parse(
                input
                    .replace("scanner.barcode", "scanner.barcode\", \"scanner.barcode")
                    .as_bytes(),
                &catalog()
            )
            .unwrap_err(),
            ConfigError::InvalidCapabilities
        );
    }
}

#[test]
fn utf8_limits_count_bytes_and_errors_never_echo_input() {
    use edge_protocol::DeviceId;
    let at_limit = "🦀".repeat(64);
    let beyond = format!("{at_limit}x");
    assert!(DeviceId::new(&at_limit).is_ok());
    assert!(AdapterKind::new(&at_limit).is_ok());
    assert!(Capability::new(&at_limit).is_ok());
    assert!(DeviceId::new(&beyond).is_err());
    assert!(AdapterKind::new(&beyond).is_err());
    assert!(Capability::new(&beyond).is_err());
    for original in ["lane-01.scanner", "example.scanner", "scanner.barcode"] {
        let input = MINIMAL.replace(original, &at_limit);
        assert_eq!(
            Configuration::parse(input.as_bytes(), &catalog()).unwrap_err(),
            ConfigError::InvalidName
        );
        assert_eq!(
            Configuration::parse(MINIMAL.replace(original, &beyond).as_bytes(), &catalog())
                .unwrap_err(),
            ConfigError::InvalidToml
        );
    }
    Configuration::parse(
        format!("{MINIMAL}serial = \"{at_limit}\"\n").as_bytes(),
        &catalog(),
    )
    .unwrap();
    assert_eq!(
        Configuration::parse(
            format!("{MINIMAL}serial = \"{beyond}\"\n").as_bytes(),
            &catalog()
        )
        .unwrap_err(),
        ConfigError::InvalidSelector
    );
    for input in [
        format!("{MINIMAL}serial = \"private-serial\\n\"\n"),
        format!("{MINIMAL}topology = \"private-topology\"\n"),
        format!("{MINIMAL}unknown = \"private-descriptor\"\n"),
    ] {
        let error = Configuration::parse(input.as_bytes(), &catalog()).unwrap_err();
        let diagnostic = format!("{error}: {error:?}");
        assert!(!diagnostic.contains("private-"));
        assert!(std::error::Error::source(&error).is_none());
    }
    let input = format!(
        "{MINIMAL}serial = \"private-serial\"\ntopology = \"sysfs:/devices/private-controller;usb=2.00;ports=1\"\n"
    );
    let parsed = Configuration::parse(input.as_bytes(), &catalog()).unwrap();
    let diagnostic = format!("{parsed:?} {:?}", parsed.slots().next().unwrap().selector());
    assert!(!diagnostic.contains("private-"));
}

#[test]
fn catalog_bounds_and_empty_command_maps_have_deliberate_semantics() {
    use edge_supervisor::catalog::CatalogError;
    let kind = || AdapterKind::new("example.scanner").unwrap();
    let caps = |count| {
        (0..count)
            .map(|n| Capability::new(format!("observation.{n}")).unwrap())
            .collect::<Vec<_>>()
    };
    assert_eq!(
        CompiledAdapter::usb(kind(), vec![], vec![]).unwrap_err(),
        CatalogError::InvalidCapabilities
    );
    assert_eq!(
        CompiledAdapter::usb(kind(), caps(33), vec![]).unwrap_err(),
        CatalogError::InvalidCapabilities
    );
    assert_eq!(
        CompiledAdapter::usb(AdapterKind::new("../driver").unwrap(), caps(1), vec![]).unwrap_err(),
        CatalogError::InvalidName
    );
    assert_eq!(
        CompiledAdapter::usb(
            kind(),
            vec![Capability::new("bad capability").unwrap()],
            vec![]
        )
        .unwrap_err(),
        CatalogError::InvalidName
    );
    let mapped: Vec<_> = caps(32)
        .into_iter()
        .enumerate()
        .map(|(n, c)| (c, n as u16))
        .collect();
    CompiledAdapter::usb(kind(), caps(32), mapped.clone()).unwrap();
    let mut excess = mapped;
    excess.push((Capability::new("observation.0").unwrap(), 0));
    assert_eq!(
        CompiledAdapter::usb(kind(), caps(32), excess).unwrap_err(),
        CatalogError::InvalidCommandGroups
    );
    let adapters = |count| {
        (0..count)
            .map(|n| {
                CompiledAdapter::usb(
                    AdapterKind::new(format!("example.{n}")).unwrap(),
                    caps(1),
                    vec![],
                )
                .unwrap()
            })
            .collect()
    };
    AdapterCatalog::new(adapters(32)).unwrap();
    assert_eq!(
        AdapterCatalog::new(adapters(33)).unwrap_err(),
        CatalogError::TooManyAdapters
    );
    let empty_catalog = AdapterCatalog::new(vec![]).unwrap();
    assert_eq!(
        Configuration::parse(MINIMAL.as_bytes(), &empty_catalog).unwrap_err(),
        ConfigError::UnknownAdapter
    );
    // Explicit empty configuration produces no invented slot or resource.
    assert!(
        Configuration::parse(b"schema_version = 1\ndevices = []\n", &empty_catalog)
            .unwrap()
            .core_seeds(&AgentInstanceId::new("agent").unwrap())
            .is_empty()
    );
}
