# Milestone 6 Reference Hardware Qualification

Record model-level qualification information only. Do not commit serial
numbers, MAC addresses, private IP addresses, machine IDs, credentials, or
store/customer data.

## Reference configuration

| Item | Recorded value |
| --- | --- |
| Qualification date/operator | Not run |
| Mini-PC manufacturer/model | Not selected |
| CPU / RAM | Not selected |
| NVMe/storage model and capacity | Not selected |
| Filesystem and mount options | Not recorded |
| Firmware version (if relevant) | Not recorded |
| Cashier display model/connection | Not selected |
| Customer display model/connection | Not selected |
| Touch controller model | Not selected |
| UPS model / OS signaling | Not selected / not tested |
| Ethernet behavior | Not tested |
| Fedora OSTree deployment commit | Not run |
| Grocery POS artifact hashes | Not run |

## Mandatory Tier C observations

Record `passed`, `failed`, `blocked`, or `not_run`, the execution timestamp, and
a concise evidence reference for each item:

- cashier display is landscape, primary, and contains the single fullscreen
  terminal window;
- second display is portrait and extended, never mirrored;
- no second cashier application or cashier business state is launched on the
  customer-facing display;
- touchscreen input maps only to the cashier display;
- KScreen layout persists across reboot;
- normal unplug/replug retains or has a clear safe recovery path for cashier
  presentation;
- `Ctrl+Alt+F3` (or another available VT) reaches the separate technician login;
- idle beyond configured timers does not suspend, hibernate, or lock;
- the selected storage/filesystem is identified for the Tier D durability
  evidence.

Firmware recommendations such as restore-on-AC-power and USB wake are recorded
during qualification, not hard-coded by Grocery POS. Customer-display business
content remains outside Milestone 6.
