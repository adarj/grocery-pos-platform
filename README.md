# Grocery POS Platform

A local-first retail point-of-sale platform for small-to-medium grocery stores.

This project is an early-stage implementation of a grocery POS system consisting of:

- a cashier-facing touchscreen terminal,
- a customer-facing portrait display,
- a local POS backend,
- a local durable transaction store,
- optional hardware/device agents,
- a manager/technician application layer,
- and a cloud control plane for management, reporting, updates, support, and synchronization.

The project is currently in the scaffolding and walking-skeleton phase. It is not yet a production-ready POS system.

## Project Goals

The platform is designed around the following goals:

- fast and reliable grocery checkout;
- local-first operation during internet or cloud outages;
- durable transaction, payment, receipt, and drawer state;
- support for cashier touchscreen and customer-facing display workflows;
- interoperability with existing grocery inventory systems;
- clean manager, technician, and support workflows;
- strong test-driven development practices;
- reproducible development and deployment tooling;
- infrastructure-as-code and GitOps-based change management;
- future support for remote management, support bundles, and controlled update channels.

## Planned Architecture

```text
Fedora Kinoite POS Terminal
  ├── Flutter Cashier UI
  ├── Flutter Customer Display
  ├── Racket POS Core
  ├── SQLite Local Store
  ├── Rust System/Device Agents
  ├── Supabase Sync Agent
  └── KDE/Kinoite Appliance Layer

Cloud Platform
  ├── Supabase
  │   ├── Postgres
  │   ├── Auth
  │   ├── RLS policies
  │   ├── register health snapshots
  │   ├── remote command coordination
  │   └── reporting/control-plane data
  │
  └── DigitalOcean
      ├── support services
      ├── update artifact distribution
      ├── support bundle storage
      └── auxiliary platform services
