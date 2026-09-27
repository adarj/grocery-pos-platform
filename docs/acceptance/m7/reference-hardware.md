# Tier C — physical reference-register security UX

Status: **not run**. Select and identify the actual display/touch/kiosk hardware, firmware, Fedora deployment, Flatpak artifact, UTC date, operator, and evidence before claiming any result. Widget tests are not Tier C evidence.

1. M7-C-001: verify terminal starts locked; PIN entry is obscured; touchscreen login works.
2. M7-C-002: observe five-minute presentation inactivity lock. Alice → lock → Bob must not reveal Alice's protected navigation state; the protected Navigator subtree is disposed. Approval dialog must clearly distinguish Void Entire Sale from login, mask approver PIN, and leave cashier session unchanged. Self-approval remains denied by Core.
3. M7-C-003: change PIN with an open sale; response returns to locked screen. Reauthenticate with new PIN and resume the same operator-owned sale/recovery. A lost response must lock and never auto-retry the PIN POST.
4. M7-C-004: verify cashier/customer display assignment, extended rather than mirrored layout, touch mapping, display reconnect/reboot lock, technician VT, and no kiosk administrative workflow without OS administrator credentials.

Record each observation as `passed`, `failed`, `blocked`, or `not_run` with timestamp and evidence. No hardware execution has yet been supplied.
