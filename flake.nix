{
  description = "Grocery POS platform development environment";

  inputs = {
    # Use unstable for current developer tooling. We can pin to a release branch later.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Convenience helper for generating outputs across supported systems.
    flake-utils.url = "github:numtide/flake-utils";

    # Convenient pinned Rust toolchains.
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [
          rust-overlay.overlays.default
        ];

        pkgs = import nixpkgs {
          inherit system overlays;
          config.allowUnfree = true;
        };

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [
            "rust-src"
            "rust-analyzer"
            "clippy"
            "rustfmt"
          ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "grocery-pos-dev";

          packages = with pkgs; [
            # Core command-line tools
            git
            just
            direnv
            nix-direnv
            jq
            yq
            ripgrep
            fd
            bat
            eza
            tree
            curl
            wget
            unzip
            zip
            zstd
            openssl
            pkg-config

            # Racket backend
            racket

            # Rust edge agents
            rustToolchain
            cargo-nextest
            cargo-watch
            cargo-audit
            cargo-deny

            # SQLite / local persistence tooling
            sqlite
            sqlfluff

            # Infrastructure-as-code
            opentofu
            terraform-docs
            tflint

            # Supabase local/cloud tooling
            supabase-cli

            # JS/TS tooling for Supabase functions, docs tooling, helper scripts, etc.
            nodejs_22
            pnpm
          ];

          shellHook = ''
            export GROCERY_POS_DEV=1
            export PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
            export SQLITE_DB_PATH="$PROJECT_ROOT/.local/sqlite/pos-dev.db"
            export RACKET_API_HOST="127.0.0.1"
            export RACKET_API_PORT="7340"

            mkdir -p \
              "$PROJECT_ROOT/.local/sqlite" \
              "$PROJECT_ROOT/.local/logs" \
              "$PROJECT_ROOT/.local/receipts" \
              "$PROJECT_ROOT/.local/support-bundles"

            echo "Entered Grocery POS dev shell"
            echo "Project root: $PROJECT_ROOT"
            echo "Run: just --list"
          '';
        };
      });
}
