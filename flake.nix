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

            # Nix development
            nixd

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

            # Flutter / Dart UI
            flutter
            clang
            cmake
            ninja
            gtk3
            glib
            libepoxy
            pcre2
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
      }
      // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
        let
          posCoreRpm = pkgs.stdenvNoCC.mkDerivation {
            pname = "grocery-pos-core-rpm";
            version = "0.0.0-dev";
            src = ./.;

            nativeBuildInputs = with pkgs; [
              coreutils
              findutils
              gzip
              gnutar
              rpm
            ];

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild
              bash packaging/fedora/build-rpm.sh "$PWD" "$PWD/rpm-output"
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              install -m 0644 "$PWD"/rpm-output/*.rpm "$out/"
              runHook postInstall
            '';

            meta = {
              description = "Internal Fedora RPM for Grocery POS Core";
              platforms = pkgs.lib.platforms.linux;
            };
          };

          posCorePackageCheck = pkgs.runCommand
            "grocery-pos-core-package-check"
            {
              nativeBuildInputs = with pkgs; [
                coreutils
                cpio
                curl
                findutils
                gawk
                gnugrep
                jq
                racket
                rpm
              ];
            }
            ''
              export HOME="$TMPDIR/home"
              export PLTUSERHOME="$TMPDIR/plt-user"
              mkdir -p "$HOME" "$PLTUSERHOME"
              bash ${./packaging/tests/check-pos-core-package.sh} \
                ${posCoreRpm} ${./.}
              touch "$out"
            '';
        in
        {
          packages.pos-core-rpm = posCoreRpm;
          checks.pos-core-package = posCorePackageCheck;
        }));
}
