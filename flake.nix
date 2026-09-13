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

        # Path-based flake evaluation deliberately includes untracked files so
        # an unstaged checkpoint can be tested. Keep ignored developer state
        # out of deployable derivation inputs without hiding new source files.
        deployableSourceFilter = path: type:
          let
            name = builtins.baseNameOf (toString path);
            generatedDirectory =
              type == "directory"
              && builtins.elem name [
                ".dart_tool"
                ".direnv"
                ".local"
                "build"
                "coverage"
                "node_modules"
                "target"
              ];
            resultLink = name == "result" || pkgs.lib.hasPrefix "result-" name;
          in
          !(generatedDirectory || resultLink);

        projectSource = pkgs.lib.cleanSourceWith {
          name = "grocery-pos-platform-source";
          src = ./.;
          filter = deployableSourceFilter;
        };

        terminalSource = pkgs.lib.cleanSourceWith {
          name = "grocery-pos-terminal-source";
          src = ./flutter/apps/pos_terminal;
          filter = deployableSourceFilter;
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
            src = projectSource;

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
                ${posCoreRpm} ${projectSource}
              touch "$out"
            '';

          rpmBuildIsolationCheck = pkgs.runCommand
            "grocery-pos-rpm-build-isolation-check"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                gnugrep
              ];
            }
            ''
              bash ${./packaging/tests/rpm-build-isolation-test.sh} \
                ${projectSource}
              touch "$out"
            '';

          posTerminalApplication = pkgs.flutter.buildFlutterApplication {
            pname = "pos-terminal";
            version = "0.0.0-dev";
            src = terminalSource;
            pubspecLock = pkgs.lib.importJSON ./packaging/flatpak/pubspec.lock.json;
            # The pinned Dart dependency hook parses pubspec.yaml through
            # PyYAML. Add it explicitly so the source build also works when an
            # x86_64 derivation executes through binfmt on our aarch64 dev host.
            nativeBuildInputs = [ pkgs.python3Packages.pyyaml ];

            meta = {
              description = "Grocery POS cashier terminal presentation client";
              platforms = [ "x86_64-linux" ];
            };
          };

          posTerminalFlatpak = pkgs.stdenvNoCC.mkDerivation {
            pname = "grocery-pos-terminal-flatpak";
            version = "0.0.0-dev";
            src = ./packaging/flatpak;

            nativeBuildInputs = with pkgs; [
              coreutils
              findutils
              flatpak
              gnugrep
              librsvg
              ostree
              patchelf
            ];

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild
              bash build-terminal-flatpak.sh \
                "$PWD" ${posTerminalApplication} \
                "$PWD/grocery-pos-terminal.flatpak"
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              install -m 0644 grocery-pos-terminal.flatpak "$out/"
              runHook postInstall
            '';

            meta = {
              description = "System Flatpak bundle for Grocery POS Terminal";
              platforms = [ "x86_64-linux" ];
            };
          };

          posApplianceRpm = pkgs.stdenvNoCC.mkDerivation {
            pname = "grocery-pos-appliance-rpm";
            version = "0.0.0-dev";
            src = projectSource;

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
              bash packaging/fedora/build-appliance-rpm.sh \
                "$PWD" "$PWD/rpm-output"
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              install -m 0644 "$PWD"/rpm-output/*.rpm "$out/"
              runHook postInstall
            '';

            meta = {
              description = "Internal Fedora RPM for Grocery POS appliance lifecycle";
              platforms = pkgs.lib.platforms.linux;
            };
          };

          applianceBundle = pkgs.stdenvNoCC.mkDerivation {
            pname = "grocery-pos-appliance-bundle";
            version = "0.0.0-dev";
            src = projectSource;

            nativeBuildInputs = with pkgs; [
              coreutils
              gnused
              gnutar
              zstd
            ];

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild
              bash packaging/appliance/build-appliance-bundle.sh \
                "$PWD" ${posCoreRpm}/*.rpm ${posApplianceRpm}/*.rpm \
                ${posTerminalFlatpak}/*.flatpak \
                "$PWD/grocery-pos-appliance-0.0.0-x86_64.tar.zst"
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              install -m 0644 grocery-pos-appliance-0.0.0-x86_64.tar.zst "$out/"
              runHook postInstall
            '';

            meta = {
              description = "Technician bundle for Fedora Kinoite Grocery POS bootstrap";
              platforms = [ "x86_64-linux" ];
            };
          };

          posAppliancePackageCheck = pkgs.runCommand
            "grocery-pos-appliance-package-check"
            {
              nativeBuildInputs = with pkgs; [
                coreutils
                cpio
                findutils
                gawk
                gcc
                gnugrep
                racket
                rpm
              ];
            }
            ''
              bash ${./packaging/tests/check-pos-appliance-package.sh} \
                ${posApplianceRpm} ${posCoreRpm} ${projectSource}
              bash ${./packaging/tests/bootstrap-kinoite-test.sh} ${projectSource}
              touch "$out"
            '';

          posTerminalFlatpakCheck = pkgs.runCommand
            "grocery-pos-terminal-flatpak-check"
            {
              nativeBuildInputs = with pkgs; [
                coreutils
                findutils
                flatpak
                gnugrep
                jq
                ostree
                patchelf
                yq
              ];
            }
            ''
              export HOME="$TMPDIR/home"
              export XDG_DATA_HOME="$TMPDIR/data"
              export XDG_CACHE_HOME="$TMPDIR/cache"
              export XDG_RUNTIME_DIR="$TMPDIR/run"
              mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
              chmod 0700 "$XDG_RUNTIME_DIR"
              bash ${./packaging/tests/check-terminal-flatpak.sh} \
                ${posTerminalFlatpak} ${projectSource}
              touch "$out"
            '';

          applianceBundleCheck = pkgs.runCommand
            "grocery-pos-appliance-bundle-check"
            {
              nativeBuildInputs = with pkgs; [
                coreutils
                findutils
                gnugrep
                gnutar
                jq
                zstd
              ];
            }
            ''
              bash ${./packaging/tests/check-appliance-bundle.sh} \
                ${applianceBundle} ${projectSource}
              touch "$out"
            '';
        in
        {
          packages.pos-core-rpm = posCoreRpm;
          packages.pos-appliance-rpm = posApplianceRpm;
          checks.pos-core-package = posCorePackageCheck;
          checks.pos-appliance-package = posAppliancePackageCheck;
          checks.rpm-build-isolation = rpmBuildIsolationCheck;
        }
        // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
          packages.pos-terminal-flatpak = posTerminalFlatpak;
          packages.appliance-bundle = applianceBundle;
          checks.rpm-build-isolation = rpmBuildIsolationCheck;
          checks.pos-terminal-flatpak = posTerminalFlatpakCheck;
          checks.appliance-bundle = applianceBundleCheck;
        }));
}
