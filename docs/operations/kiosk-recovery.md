# Kiosk Recovery and Local Technician Access

## Technician boundary

The kiosk account has no administrator password or sudo access. Use an
installation/provisioning-time human administrator account. Virtual-terminal
switching is deliberately retained: from the cashier display use an available
VT such as `Ctrl+Alt+F3`, log in as the technician administrator, then use sudo.
There is no hidden Flutter key chord or default technician credential.

## Inspect before changing state

Useful commands are:

```text
sudo grocery-pos-appliance status
sudo systemctl status grocery-pos-core
curl http://127.0.0.1:7340/health
curl http://127.0.0.1:7340/ready
sudo grocery-pos-support collect /explicit/output/CASE.tar.gz
```

The support collector is observational and privacy-minimized. For explicit
SQLite maintenance or recovery, follow the
[database maintenance](database-maintenance.md),
[support diagnostics](support-diagnostics.md), and
[offline restore](database-restore.md) runbooks.

## Temporary presentation maintenance

To stop the graphical kiosk lifecycle without stopping POS Core or changing
the database:

```text
sudo grocery-pos-appliance kiosk-stop
```

This records a root-only marker under `/run`, stops Plasma Login Manager, and
prevents immediate kiosk relogin while maintenance is active. To restore the
normal presentation lifecycle:

```text
sudo grocery-pos-appliance kiosk-start
```

The marker is transient; reboot returns to the provisioned kiosk lifecycle.
These operations do not enable/disable POS Core, open/close shifts, alter
transactions, select backups, or change service enablement.

Use ordinary `systemctl reboot` or `systemctl poweroff` for a deliberate clean
machine transition. Do not use SIGKILL, delete `pos.db`/WAL sidecars, copy a
live SQLite file, disable SELinux, put the kiosk user in `wheel`, or improvise
an automatic backup fallback. If readiness or restore verification fails,
leave evidence intact and escalate.

