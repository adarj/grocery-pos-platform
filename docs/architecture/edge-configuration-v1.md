# Edge configuration v1 and USB reconciliation

M8.3.1 supplies strict restart-only configuration, Linux USB discovery, and
deterministic **binding eligibility**. It does not install a scanner runtime,
decode barcodes, publish barcode events, or qualify physical hardware. Flutter
presents; Racket decides; SQLite remembers; Rust talks to edges.

## Ownership and configuration source

`edge-supervisor` owns privileged composition above `edge-core` and the adapter
API. Configuration, compiled adapter metadata, physical discovery, selectors,
and reconciliation remain outside Core's command/event authority and outside
the HTTP server. Discovery does not mutate Core snapshots.

Production configuration resides at `/etc/grocery-pos/edge.toml`. The loader
also accepts an explicit path for tests and future bootstrap. It reads once,
never rewrites the file, and implements no hot reload. Changes require
privileged administration and restart with a new agent epoch. Root ownership,
read-only edge access, exclusion of Racket/Flutter writes, DAC, systemd, and
SELinux enforcement remain M8.7 deployment work; parsing alone does not prove
those controls. There is no production daemon/bootstrap in this checkpoint.

## Schema v1

This is an **illustrative synthetic adapter**, used in tests. It is not a
registered production scanner driver, and these VID/PID values do not identify
a Zebra DS2208:

```toml
schema_version = 1

[[devices]]
device_id = "lane-01.scanner"
enabled = true
adapter_kind = "example.scanner"
allowed_capabilities = ["scanner.barcode"]

[devices.selector]
kind = "usb"
vendor_id = 0x1234
product_id = 0x5678
# Optional exact constraints, combined with VID/PID using AND:
# serial = "synthetic-unit"
# topology = "sysfs:/devices/pci0000:00/0000:00:14.0;usb=2.00;ports=1.4"
```

Every displayed field except serial/topology is required. `devices = []` is
valid and authorizes no hardware; this permits composition with an empty
compiled catalog while no production adapters exist. Disabled slots still need
a valid adapter, selector, and nonempty allowlist. Disabling a slot cannot make
invalid privileged configuration acceptable. Names use lowercase ASCII letters,
digits, `.`, `_`, and `-`, start with a letter/digit, and obey the existing
256-byte protocol text ceiling. This configuration grammar is deliberately
narrower than opaque protocol identifiers.

An empty deployment is written explicitly as `schema_version = 1` followed by
`devices = []`; omitting the required `devices` field is a configuration error.

Typed Serde TOML decoding rejects duplicate keys, unknown fields at every level,
wrong types, missing/unsupported schema, unknown selector kinds, malformed text,
duplicate device IDs/capabilities, and unsupported compiled adapter authority.
Parser errors are reduced to authored error classes; input excerpts and physical
identities are not diagnostics. No dynamic TOML maps escape validation.

| Hard bound | Value / behavior |
| --- | --- |
| Configuration file | 65,536 bytes; loader reads at most one extra byte to detect overflow |
| Configured logical slots | 32; explicit empty list allowed |
| Capabilities per slot / compiled adapter | 32; nonempty, unique, bounded semantic names |
| Compiled adapter descriptions | 32; unique kinds |
| USB VID/PID | Integer `0..=65535`, including TOML hexadecimal syntax |
| Serial | 256 UTF-8 bytes, nonempty, no control characters; exact, no trimming |
| Topology | 512 bytes in the canonical format below |
| Candidate identity / sysfs access context | 1,024 bytes each; ephemeral, not a configured identity |
| USB candidates | 256, including enumerated physical root hubs; 257 rejects the entire snapshot |
| Scanned sysfs directory entries | 4,096, including interfaces; 4,097 rejects the entire snapshot |
| `uevent` read | 4,096 bytes plus bounded overflow/newline detection |
| Port chain | At most seven nonzero `1..=255` ports; `0` identifies a root hub |

Raw VID/PID reads require four hexadecimal digits. Other sysfs reads have narrow
field-specific ceilings. Only a final sysfs newline is removed; kernel revision
padding is normalized explicitly. Missing serial stays absent. Malformed,
overlong, non-UTF-8, inaccessible, or disappearing required attributes reject
the snapshot. A failed scan supplies no partial eligibility input.

## Compiled adapter authority and Core seeds

`AdapterCatalog` contains first-party metadata: kind, supported selector family
(USB in v1), supported capabilities, and a command-capability-to-local-resource
group map. There is no runtime code loading, shared-object path, or plugin
directory. M8.3.1 ships no production scanner catalog entry. Tests explicitly
construct synthetic manifests.

Configuration validates `allowed capabilities ⊆ compiled adapter support`.
Command resource groups are a subset of that allowlist; several commands within
one slot may serialize on one resource. Seed construction allocates deterministic
resource IDs in sorted logical-slot/capability order, never shares resources
between slots, and retains unmapped observation capabilities as privileged
allowlist entries. A printer may allow `receipt.print`, `printer.status`, and
`drawer.open` while mapping only print/drawer to their shared command resource.

Each enabled seed is absent; each disabled seed is disabled. Both have no binding,
no published capabilities/conditions, and revision zero. The configured adapter
kind is retained. Configuration alone does not publish an active capability.
Core validates later published capabilities against the independent allowlist,
while command admission requires both publication and an actual command-resource
mapping. An allowed observation cannot manufacture executable authority.

M8.3.1 established registry/configuration support for observation-only slots.
M8.3.2 now provides [owned observation runtimes and complete binding proofs](edge-observations.md).
The command executor still rejects empty/incomplete installation; observation-only
activation requires a real owned source component.
There is no synthetic `scanner.read`, trigger/noop command, or dummy resource.
Binding must additionally intersect allowed/compiled capabilities with verified
hardware support. Synthetic runtime tests establish composition, not physical proof.

## Linux discovery and physical topology

`LinuxUsbDiscovery` incrementally reads `/sys/bus/usb/devices`, follows canonical
sysfs links under `/sys/devices`, and accepts only `DEVTYPE=usb_device`.
`usb_interface` entries are ignored. It reads VID, PID, optional serial, device
port chain (`devpath`), and root-hub USB revision (`version`). It never reads
manufacturer/product descriptor dumps, opens device nodes, or invokes shell
tools. Safe standard-library sysfs traversal was selected to enforce scan and
attribute limits before collecting an inventory; no libudev build dependency
or unbounded native enumeration list is required. These attributes follow the
[Linux USB sysfs implementation](https://github.com/torvalds/linux/blob/master/drivers/usb/core/sysfs.c).

Root hubs and external hubs are physical USB device objects and count toward
the candidate limit. Their presence grants no role: eligibility still requires
an enabled validated slot with an exact selector and compiled-adapter metadata.
Future adapter opening must establish actual hardware support. Binary
`descriptors` and `bos_descriptors` are never opened. Required-attribute loss or
malformation after a valid scan prefix rejects the complete snapshot.

The typed candidate carries an ephemeral identity, bus family, VID/PID, optional bounded
serial, canonical topology, and current sysfs access context. Private identity,
serial, topology, and path `Debug` output is redacted. Candidates have no public
Edge Protocol serialization. USB identity is operational matching, not
cryptographic attestation; descriptors remain untrusted.
Discovery sources must resolve sysfs symlinks before supplying candidates.
The typed access path rejects relative paths, `.`/`..`, repeated separators,
and trailing separators; it does not itself perform filesystem resolution.

Topology format is:

```text
sysfs:<controller path relative to /sys>;usb=<root-hub revision>;ports=<port chain>
```

The controller begins `/devices/` and ends before `usbN`. Kernel USB bus numbers,
USB addresses, `/dev` node numbers, and enumeration order are excluded. For
example, re-enumerating bus `1` as bus `42` leaves controller/revision/ports
unchanged while candidate identity/access context changes. Revision separates
USB root-hub families under the same controller. Indistinguishable topologies
remain ambiguous rather than picking a winner. Topology follows a configured
port and may intentionally authorize a compatible replacement there; serial
follows an operational unit identity. Neither is attestation.

Here `usb=2.00` is the root hub's reported USB specification revision
(`bcdUSB`), not the peripheral's negotiated speed. This is a **host-specific USB
topology identity suitable for controlled appliance hardware**, not an immutable
physical-connector identity. Companion-controller routing, speed-dependent USB
tree changes, firmware, controller replacement, or host topology changes can
invalidate a selector. Such a change stops matching; it never enables fallback.
Linux describes those stability limits in
[the USB path API](https://docs.kernel.org/driver-api/usb/usb.html).

Candidate IDs are keys within a snapshot. The kernel can reuse a sysfs path after
replacement; equal candidate IDs do not prove continuing hardware attachment or
permit reuse of a binding epoch.

Snapshots are bounded scans, not an atomic kernel hotplug transaction or binding
proof. I/O failure during a scan discards it. Future udev add/remove/change events
will be hints to call `DiscoverySource::snapshot()` again, not inputs that directly
grant a role. Binding begins with current global reconciliation and fences
disappearance/replacement through the binding lifecycle.
`Eligible` is provisional: a scan can miss an insertion occurring during
enumeration or retain facts read immediately before removal. **After preparing
an owned attachment, M8.3.2 revalidates current discovery and global
reconciliation and checks that held attachment before installation and creation
of Core binding authority.** An old eligibility
result or reused sysfs identity is never sufficient authorization or an
installation witness. Revalidation must also protect the gap through activation.
The M8.3.2 `BindingManager` now performs preparation, fresh global reconciliation
and a held-attachment check before complete runtime installation. The compiled
factory must hold the exact attachment and reject replacement rather than follow
a reused path. Real hardware must qualify that factory/handle contract later.

## Selectors and global reconciliation

USB VID and PID must both match. Supplied serial and topology constraints must
also match exactly. Missing serial cannot satisfy a serial constraint. There is
no fallback, regex, glob, scoring, description selector, `/dev` selector, or
first-match rule. Non-USB candidate metadata never matches; the Linux backend
emits only USB physical candidates. The defensive unsupported-bus marker adds no
other bus implementation, and unsupported selectors are rejected at parsing.

| Per configured slot | Internal result |
| --- | --- |
| Disabled | `Disabled`, regardless of physical presence |
| Enabled, zero matches | `Absent` |
| Enabled, exactly one match | Tentatively `Eligible(candidate_id)` |
| Enabled, more than one match | `Ambiguous`, authored `edge.discovery_ambiguous` |
| A candidate tentatively claimed by multiple slots | Every claimant becomes `Conflict`, authored `edge.discovery_conflict` |

An already ambiguous slot has no tentative claim. No configuration-order winner
exists. Sorted maps/snapshots plus a separate global conflict pass make results
independent of configuration, candidate, and hash iteration order. Duplicate
candidate IDs or aliased physical sysfs paths reject the whole snapshot. Identical
USB models at different physical paths remain separate candidates and can make a
broad selector ambiguous. Error/condition codes never embed descriptors, serials,
or paths. Results stay supervisory and do not activate Core bindings.
For example, if broad slot A matches X and Y while serial-specific slot B
matches only X, A is ambiguous and B is provisionally eligible for X. If Y
disappears, both uniquely claim X and both become conflicting. A disabled
overlapping slot never participates in ownership claims.

## Validation and deferred scope

Hardware-free tests cover strict configuration, exact constraints, N/N+1 bounds,
order reversal, global conflicts, bus renumbering, physical/interface separation,
malformed attributes, descriptor non-reading, and redacted diagnostics. Existing
Core/executor/transport regressions still protect command identity and binding
witnesses. `just check-rust` and `just check` remain canonical development gates.

M8.3.2 supplies generic observation installation, typed barcode events and opt-in
Racket callback delivery. Later M8.3 work must supply scanner adapters, physical
barcode decoding, Racket business decisions, Flutter presentation, and
selected physical-device qualification. Production bootstrap, hotplug orchestration,
service identities/DAC/udev/SELinux policy, printers/drawers/displays/scales,
payments, and integrated-lane qualification remain later work. No DS2208 hardware
or driver claim is made. SQLite stays v12 and Rust gains no persistence authority.
Frozen M8.2 acceptance remains unchanged for its recorded source commit.
The current cumulative M8.3 Core source is newer than that qualified source; frozen M8.2
evidence does not directly certify this refactor. Later cumulative M8
qualification must establish the current hardware-edge contract.
