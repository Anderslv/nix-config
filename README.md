<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [Nix config](#nix-config)
  - [Quick start](#quick-start)
  - [Layout](#layout)
  - [Main outputs](#main-outputs)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

# Nix config

Personal Nix flake for NixOS systems, Home Manager profiles, dotfiles, and
custom helper scripts.

## Quick start

```bash
git clone https://github.com/jakob1379/nix-config.git
cd nix-config
./install.sh
nix develop
```

Use the Home Manager package groups (core, dev, emacs, scripts; no GUI) without
activating anything — also works on macOS (`aarch64-darwin`). Packages that are
unavailable on the current platform are skipped:

```bash
nix shell            # tools added to the current shell's PATH
nix develop .#env    # same tools in a dev shell
```

Useful commands:

```bash
nix fmt
nix flake show
```

## Layout

- `flake.nix` — flake entrypoint, outputs, checks, dev shell
- `home/` — Home Manager profiles, shared modules, per-system overrides
- `nixos/` — NixOS hosts, shared defaults, user modules
- `dotfiles/` — editor, shell, browser, terminal, and desktop configs
- `bin/` — custom helper commands wrapped into packages
- `scripts/` — supporting scripts for desktop, wallpaper, SSH, and shell
  workflows
- `lib/` — shared helpers used by flake outputs
- `overlays/` — package overlays
- `nix/` — repo checks and git hook configuration
- `archive/` — legacy/archived experiments

## Main outputs

- `homeConfigurations` — Home Manager profiles
- `nixosConfigurations` — NixOS host configs
- `packages` / `apps` — exported packages and runnable apps
- `packages.default` — Home Manager package groups as a plain environment
- `devShells.default` — development environment with hooks
- `devShells.env` — dev shell with `packages.default`
- `formatter` / `checks` — formatting and validation
