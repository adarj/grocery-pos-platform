# E1–E30 disposition matrix

This maps the frozen threat model to **planned evidence**. No row asserts that Phase 2 has run. “Qualified” below identifies the intended M8.2 Tier-A coverage upon a passing ledger.

| Invariant | Requirement | M8.2 disposition | Stable requirement IDs | Planned evidence | Residual limitation |
| --- | --- | --- | --- | --- | --- |
| E1 | Racket-only caller | Structurally established; Tier B required | M8.2-CP1-001, M8.2-CP5-001 | M8.2-A-004, M8.2-A-008 | UID seam/same-user tests do not prove deployed service identity. |
| E2 | Flutter has no edge/raw authority | Structurally established; Tier B required | M8.2-CP1-001 | M8.2-A-004, M8.2-A-013 | Flatpak/device DAC/SELinux isolation requires appliance evidence. |
| E3 | No Edge business facts | Structurally established | M8.2-CP1-002 | M8.2-A-004, M8.2-A-003 | Source tripwire/manual classification; not protection against arbitrary daemon compromise. |
| E4 | No Edge SQLite | Structurally established; Tier B required | M8.2-CP1-002 | M8.2-A-004, M8.2-A-013 | OS filesystem denial remains Tier B. |
| E5 | Presence is not authorization | Generic capability constraint qualified; discovery deferred | M8.2-CP1-004, M8.2-CP4-003 | M8.2-A-007, M8.2-A-004 | Physical selector authorization absent; no OS presence claim. |
| E6 | Agent and binding epochs | Qualified in M8.2 | M8.2-CP2-001 | M8.2-A-005, M8.2-A-009 | Ephemeral identities, not durable exactly-once effects. |
| E7 | Stale epochs cannot affect replacement | Qualified in M8.2 | M8.2-CP4-002, M8.2-CP4-003 | M8.2-A-007, M8.2-A-011 | Cooperative bounded adapter contract; real I/O Tier C. |
| E8 | Record before effect | Qualified in M8.2 | M8.2-CP2-002 | M8.2-A-005, M8.2-A-006 | In-memory record, not durable intent. |
| E9 | Exact replay starts once | Qualified in M8.2 | M8.2-CP2-003, M8.2-CP2-007, M8.2-CP6-003 | M8.2-A-005, M8.2-A-009, M8.2-A-010 | After safe eviction original freshness is stale. |
| E10 | Changed retained semantics conflict | Qualified in M8.2 | M8.2-CP2-003, M8.2-CP6-001 | M8.2-A-005, M8.2-A-009 | Recycled evicted ID with new deadline is prohibited client behavior; not permanent server memory. |
| E11 | Dual terminal retention | Qualified in M8.2 | M8.2-CP2-006, M8.2-CP2-007 | M8.2-A-005, M8.2-A-010 | 404 never proves non-effect. |
| E12 | Known failure vs uncertainty | Qualified in M8.2 | M8.2-CP3-002, M8.2-CP6-003 | M8.2-A-006, M8.2-A-009 | Synthetic effect evidence does not prove a physical device outcome. |
| E13 | Unknown is not silently rewritten | Qualified in M8.2 | M8.2-CP2-008, M8.2-CP3-002 | M8.2-A-006, M8.2-A-009 | Business reconciliation remains Racket. |
| E14 | No Rust business retry policy | Structurally established and regression protected | M8.2-CP3-005 | M8.2-A-004, M8.2-A-009, M8.2-A-011 | Later workflow clients require separate review. |
| E15 | No automatic repeat after Possible | Qualified in M8.2 | M8.2-CP3-003, M8.2-CP3-005, M8.2-CP6-002 | M8.2-A-006, M8.2-A-009, M8.2-A-011 | Does not prevent human-created new attempts. |
| E16 | One active per resource | Qualified in M8.2 | M8.2-CP3-004 | M8.2-A-006, M8.2-A-010 | Configured resource identity, not discovered topology. |
| E17 | All buffers bounded | Generic implemented boundaries qualified; production config deferred | M8.2-CP2-005, M8.2-CP4-001, M8.2-CP4-006, M8.2-CP5-002, M8.2-CP6-004, M8.2-CP6-005 | M8.2-A-005, M8.2-A-007, M8.2-A-008, M8.2-A-010, M8.2-A-012 | Full configuration and later observation buffers unimplemented. |
| E18 | Detectable event loss | Qualified in M8.2 | M8.2-CP4-006, M8.2-CP5-005, M8.2-CP6-006 | M8.2-A-007, M8.2-A-008, M8.2-A-009 | Future transient device observations require their own overflow tests. |
| E19 | Ephemeral events | Structurally established and regression protected | M8.2-CP4-006 | M8.2-A-004, M8.2-A-007, M8.2-A-011 | No durable event replay or business event store. |
| E20 | Reconnect creates fresh binding | Qualified in M8.2 | M8.2-CP4-001, M8.2-CP4-003 | M8.2-A-007, M8.2-A-010 | Synthetic attachment lifecycle, not physical hotplug. |
| E21 | Adapter cannot mutate Core identity | Structurally established and qualified | M8.2-CP2-002, M8.2-CP3-001, M8.2-CP4-004 | M8.2-A-001, M8.2-A-006, M8.2-A-007 | Arbitrary driver code execution remains process compromise. |
| E22 | Fatal control requires new epoch | Qualified transport abandonment/process restart | M8.2-CP3-006, M8.2-CP5-004, M8.2-CP7-005 | M8.2-A-008, M8.2-A-011 | Fixture supplies distinct injected agent IDs; production secure generation/systemd restart deferred. |
| E23 | No raw channel | Structurally established | M8.2-CP1-003 | M8.2-A-004, M8.2-A-008 | Future device schemas require review. |
| E24 | Allowlisted capabilities | Generic Core authority qualified; production config deferred | M8.2-CP1-004 | M8.2-A-007, M8.2-A-004 | No complete edge.toml/parser or candidate selectors. |
| E25 | Payments excluded | Structurally established | M8.2-CP1-003 | M8.2-A-004 | Generic v1 has no payment execution. |
| E26 | Simulation cannot activate accidentally | Fixture isolation established; production policy deferred | M8.2-CP1-005 | M8.2-A-004, M8.2-A-013 | No production daemon/config launch policy exists yet. |
| E27 | SELinux enforcing | Tier B evidence required | M8.2-CP7-003 | M8.2-A-004 | Not claimed from repository tests. |
| E28 | No wall-clock safety dependency | Qualified in M8.2 | M8.2-CP3-006 | M8.2-A-005, M8.2-A-006, M8.2-A-007 | UTC timestamps identify evidence only; no safety clock origin shared. |
| E29 | Untrusted hardware input | Deferred device-specific implementation; Tier C required | M8.2-CP1-003, M8.2-CP7-003 | M8.2-A-004 | Hostile wire DTOs qualified separately; no hardware traffic/descriptors yet. |
| E30 | USB identity is not attestation | Architectural limitation; later Tier B/C review | M8.2-CP7-003 | M8.2-A-004 | No discovery or attestation implementation/claim. |
