# Flutter Linux VM Notes

The development VM is an aarch64 Fedora Kinoite guest running in VMware Fusion on Apple Silicon. The project runs Flutter from the `dev` Distrobox through the Nix development shell.

## Known issue

Running the Linux Flutter app directly with:

```bash
flutter run -d linux
```

may fail with:

```none
No provider of eglGetPlatformDisplayEXT found.
```

## Workaround

Use `nixGL` when launching the Flutter POS terminal app:

```bash
nix run --impure github:nix-community/nixGL#nixGLIntel -- flutter run -d linux
```

The project `justfile` wraps this as:

```bash
just run-pos
```

## Notes

The `nixGLIntel` wrapper name is not specific to Intel CPUs in this development context. It is the wrapper that currently resolves the OpenGL/EGL runtime issue in the Fedora Kinoite VMware/Distrobox/Nix environment.

The plain launcher is still available as:

```bash
just run-pos-plain
```
