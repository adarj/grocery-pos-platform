# Grocery POS Platform

A local-first grocery POS platform for small-to-medium grocery stores.

## Current Status

Early development scaffold. The first milestone is a walking skeleton connecting a Flutter POS shell to a local Racket backend.

## Planned Stack

- POS OS: Fedora Kinoite
- Cashier/customer UI: Flutter
- Local backend: Racket
- Local database: SQLite
- System/device agents: Rust
- Cloud control plane: Supabase
- Auxiliary cloud infrastructure: DigitalOcean
- Development environment: Distrobox + Nix + direnv + just

## Development

```bash
direnv allow
just doctor
just --list
