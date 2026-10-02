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

        # crypto-lib is not part of the Racket 9.1 distribution shipped by
        # either pinned nixpkgs or Fedora 44. Pin its complete Racket-library
        # dependency graph here; native Argon2 remains supplied by libargon2.
        cryptoSource = pkgs.fetchFromGitHub {
          owner = "rmculpepper";
          repo = "crypto";
          rev = "713eaaf45a5e6c55bd3e97a32b2a90f61ef13c4f";
          hash = "sha256-6Y4WZ494vNxY3/WOq7Dmi7SpfYqMsqVvG8SyqXUTU7g=";
        };
        asn1Source = pkgs.fetchFromGitHub {
          owner = "rmculpepper";
          repo = "asn1";
          rev = "3cd32b61a68b40ec03bed98cd0c4d4d4f72cacf2";
          hash = "sha256-aNYtnW/usIbqebWXIsWZKylfo83oXUGGJCbLhoaXoJ8=";
        };
        hashViewSource = pkgs.fetchFromGitHub {
          owner = "rmculpepper";
          repo = "racket-hash-view";
          rev = "7a9b31d1715c40c205a065d666fcc74d840a8a5e";
          hash = "sha256-pKp/sVd/xNOIbZsRwg1yRi5Xr+7V5DJqr3QxsM6MLhI=";
        };
        base64Source = pkgs.fetchFromGitHub {
          owner = "rmculpepper";
          repo = "racket-base64";
          rev = "f783f42743b158173c5775b90b5cadcc41f700b3";
          hash = "sha256-SKoi5GD3bHL0ktxEtC7wpzu6epjIEnc7zMtJ2rGe5zU=";
        };
        binaryioSource = pkgs.fetchFromGitHub {
          owner = "rmculpepper";
          repo = "binaryio";
          rev = "e949401e3acd7aa51ffe044cb75288128ce64c61";
          hash = "sha256-wxEqfbAcnZNhB2YXiMTadpilHWcaGBfXtDjYYQ/VtbQ=";
        };
        gmpSource = pkgs.fetchFromGitHub {
          owner = "rmculpepper";
          repo = "racket-gmp";
          rev = "768c33615a1c2414ccaf1a1e4ea1064bd5dd46af";
          hash = "sha256-Z09YdkD6nzwF51CjF7405cf4ZGR/OGAnYJrVvbXidEU=";
        };
        scrambleSource = pkgs.fetchFromGitHub {
          owner = "rmculpepper";
          repo = "racket-scramble";
          rev = "a2d1dfd8d249c63059bed2958e71dbb6e9098319";
          hash = "sha256-GbniMHYktaaXLbc/CHNRxQvzisc2u5NAsUH2E4ZLYeY=";
        };

        # http-easy-lib 0.11.1: only its non-distribution dependencies are
        # copied as collections. net-cookies/unix-socket are in pinned Racket.
        httpEasySource = pkgs.fetchFromGitHub {
          owner = "Bogdanp"; repo = "racket-http-easy";
          rev = "d099f4025f93b5938b7a66db821aa4888e2a2afc";
          hash = "sha256-5fYrV79nQDnvDXIpPO3EUPVwRZFIUOdi4i0wXnjTkKw=";
        };
        resourcePoolSource = pkgs.fetchFromGitHub {
          owner = "Bogdanp"; repo = "racket-resource-pool";
          rev = "323ca977ab55f526582f322f148cf684b79896c3";
          hash = "sha256-EwkoTDzhle0WtdyCfaJGo5F7xWFN2c+LHXJhjZ9A6RI=";
        };
        actorSource = pkgs.fetchFromGitHub {
          owner = "Bogdanp"; repo = "racket-actor";
          rev = "0d46e1f039bbc22372171a077884f28ccd283c93";
          hash = "sha256-b0Q++FnbQQCHqDS3JIGqGm/M08KG+VxHv8+mSBdq9vA=";
        };
        racketEdgeCollections = pkgs.stdenvNoCC.mkDerivation {
          pname = "grocery-pos-racket-edge-collections";
          version = "2026-09-29";
          dontUnpack = true;
          nativeBuildInputs = [ pkgs.patch ];
          installPhase = ''
            mkdir -p "$out/share/racket/collects"/{net,data,actor}
            cp -R ${httpEasySource}/http-easy-lib/. "$out/share/racket/collects/net/"
            cp -R ${resourcePoolSource}/resource-pool-lib/. "$out/share/racket/collects/data/"
            cp -R ${actorSource}/actor-lib/. "$out/share/racket/collects/actor/"
            chmod -R u+w "$out/share/racket/collects"
            # Pinned Racket's HTTP decoder allocates the declared chunk length
            # before the bounded caller sees bytes. Keep mature parsing, with
            # bounded framing/storage, private to http-easy (no global override).
            cp ${pkgs.racket}/share/racket/collects/net/http-client.rkt \
              "$out/share/racket/collects/net/http-easy/private/bounded-http-client.rkt"
            chmod u+w "$out/share/racket/collects/net/http-easy/private/bounded-http-client.rkt"
            cd "$out/share/racket/collects/net/http-easy/private"
            patch -p1 < ${./nix/racket-http-client-bounds.patch}
            # Edge disallows compression; avoid background decompression before
            # the client can reject a hostile Content-Encoding header.
            substituteInPlace bounded-http-client.rkt \
              --replace-fail "[decodes '(gzip deflate)]" '[decodes null]'
            substituteInPlace session.rkt pool.rkt proxy.rkt \
              --replace-fail net/http-client '"bounded-http-client.rkt"'
            # Upstream 0.11.1 initializes a retry counter with max-attempts,
            # permitting one extra attempt. Make the advertised count TOTAL.
            substituteInPlace session.rkt \
              --replace-fail '#:attempts max-attempts' '#:attempts (sub1 max-attempts)'
            # Library diagnostics must not echo hostile response/framing text.
            substituteInPlace session.rkt \
              --replace-fail '(exn-message e)' '"HTTP transport error"' \
              --replace-fail '(response-status-line resp)' '"HTTP response received"'
            substituteInPlace pool.rkt \
              --replace-fail '(exn-message conn-or-exn)' '"HTTP connection error"'
          '';
        };

        racketCryptoCollections = pkgs.stdenvNoCC.mkDerivation {
          pname = "grocery-pos-racket-crypto-collections";
          version = "2.0-713eaaf";
          dontUnpack = true;
          installPhase = ''
            runHook preInstall
            collections="$out/share/racket/collects"
            mkdir -p "$collections"
            cp -a ${cryptoSource}/crypto-lib "$collections/crypto"
            cp -a ${asn1Source}/asn1-lib "$collections/asn1"
            cp -a ${hashViewSource}/hash-view-lib "$collections/hash-view"
            cp -a ${base64Source}/base64-lib "$collections/base64"
            cp -a ${binaryioSource}/binaryio-lib "$collections/binaryio"
            cp -a ${gmpSource}/gmp-lib "$collections/gmp"
            cp -a ${scrambleSource}/scramble-lib "$collections/scramble"
            runHook postInstall
          '';
        };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "grocery-pos-dev";

          # Separate tool and target-library hooks. Without strict roles this
          # multi-compiler shell duplicates flags until GCC cannot spawn collect2.
          strictDeps = true;

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
          ];

          buildInputs = with pkgs; [
            # Libraries linked/loaded by Racket and the Flutter Linux runner.
            libargon2
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
            export PLTCOLLECTS="${racketEdgeCollections}/share/racket/collects:${racketCryptoCollections}/share/racket/collects:''${PLTCOLLECTS:-}"
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.libargon2 ]}:''${LD_LIBRARY_PATH:-}"

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
              bash packaging/fedora/build-rpm.sh \
                "$PWD" "$PWD/rpm-output" \
                ${racketCryptoCollections}/share/racket/collects
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
                libargon2
                racket
                rpm
              ];
            }
            ''
              export HOME="$TMPDIR/home"
              export PLTUSERHOME="$TMPDIR/plt-user"
              export PLTCOLLECTS="${racketCryptoCollections}/share/racket/collects:"
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.libargon2 ]}"
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

          racketCryptoCheck = pkgs.runCommand
            "grocery-pos-racket-crypto-check"
            {
              nativeBuildInputs = with pkgs; [ libargon2 racket ];
            }
            ''
              export PLTCOLLECTS="${racketCryptoCollections}/share/racket/collects:"
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.libargon2 ]}"
              racket -e \
                '(require crypto crypto/argon2)
                 (define implementation (get-kdf (quote argon2id) argon2-factory))
                 (unless implementation (error (quote crypto-check) "Argon2id unavailable"))
                 (define verifier
                   (pwhash implementation #"80421637"
                           (quote ((m 19456) (t 2) (p 1)))))
                 (unless (and (string-prefix? verifier "$argon2id$")
                              (pwhash-verify implementation #"80421637" verifier))
                   (error (quote crypto-check) "Argon2id round trip failed"))'
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
                libargon2
                racket
                rpm
              ];
            }
            ''
              export HOME="$TMPDIR/home"
              export PLTUSERHOME="$TMPDIR/plt-user"
              export PLTCOLLECTS="${racketCryptoCollections}/share/racket/collects:"
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.libargon2 ]}"
              mkdir -p "$HOME" "$PLTUSERHOME"
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
          packages = {
            pos-core-rpm = posCoreRpm;
            pos-appliance-rpm = posApplianceRpm;
          } // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
            pos-terminal-flatpak = posTerminalFlatpak;
            appliance-bundle = applianceBundle;
          };

          checks = {
            pos-core-package = posCorePackageCheck;
            pos-appliance-package = posAppliancePackageCheck;
            racket-crypto = racketCryptoCheck;
            rpm-build-isolation = rpmBuildIsolationCheck;
          } // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
            pos-terminal-flatpak = posTerminalFlatpakCheck;
            appliance-bundle = applianceBundleCheck;
          };
        }));
}
