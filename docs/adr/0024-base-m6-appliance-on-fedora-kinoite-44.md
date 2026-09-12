# ADR-0024: Base the M6 appliance on Fedora Kinoite 44 with persistent rpm-ostree layering

Status: Accepted

Date: 2026-09-12

## Context

Fedora Kinoite is the chosen register OS and Fedora 44 is the current stable
reference release. The project already produces Fedora-native host RPMs. A
future project-derived bootable OCI image is attractive, but the production
Atomic Desktop bootc delivery path is still evolving and is not required to
establish the Milestone 6 appliance lifecycle.

The authoritative database must persist independently of OS/application
deployment content, and a clean register must be provisionable without Nix or
a repository checkout.

## Decision

Use official Fedora Kinoite 44 x86_64 as the M6 reference base. Layer the local
`grocery-pos-core` and `grocery-pos-appliance` RPMs in one rpm-ostree
transaction. Keep deployment content under `/usr` and persistent application/
machine state under `/var`.

Distribute a technician appliance bundle containing those RPMs, the cashier
Flatpak, an explicit bootstrap program, a versioned manifest, and SHA-256
checksums. Bootstrap validates the exact OS/release/variant/architecture and
refuses an unrelated pending deployment. It reports—not hides—the required
reboot boundary and never reboots by default.

Do not build a custom ISO or bootc-derived appliance in M6. Keep host policy
packaged/declarative so a future migration to a project-derived bootable OCI
image does not require redesigning state or authority boundaries.

## Rationale

This keeps the base Fedora-maintained, uses Kinoite's transactional deployment
model, and allows project layered RPMs to persist across supported upgrades/
rebases. It also preserves the immutable `/usr` versus persistent `/var`
separation already established for POS Core.

## Consequences

- Initial bootstrap has an explicit rpm-ostree deployment and reboot step.
- Fedora repositories supply narrowly required host packages.
- SHA-256 proves integrity/consistency but not publisher authenticity.
- Deployment/rollback behavior needs Checkpoint 7 qualification on the exact
  Fedora 44 appliance.
- Future bootc migration remains possible without moving SQLite authority.

## Rejected or deferred alternatives

Traditional mutable Fedora KDE, a NixOS appliance, containerized POS Core,
custom OSTree composition/installer ISO for M6, Fedora 44 bootc production
dependency, Fedora 45/Rawhide targeting, automatic fleet updates, and forced
unattended reboots are rejected or deferred.

