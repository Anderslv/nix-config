# Secrets (sops + age + KeePassXC)

Secrets are encrypted at rest with [sops](https://github.com/getsops/sops)
using [age](https://age-encryption.org/), and wired into Home Manager via
[sops-nix](https://github.com/Mic92/sops-nix). KeePassXC is the source of
truth: everything below is defined there, and the files on disk are derived
from it by `nix-secrets-setup`.

The wiring lives in the shared Home Manager module (`home/modules/secrets.nix`),
so it works the same on macOS, NixOS and other Linux machines.

## What lives where

All entries are in the KeePassXC group `nix-config` (override with
`NIX_SECRETS_GROUP`). Values are stored in each entry's UserName field.

| KeePassXC entry            | Holds                                      | Derived file (never contains plaintext in git)          |
| -------------------------- | ------------------------------------------ | ------------------------------------------------------- |
| `nix-config/age-key`       | age private key, attachment `keys.txt`     | `~/.config/sops/age/keys.txt` (local only, mode `0600`) |
| `nix-config/age-key-label` | name of the key in `.sops.yaml`            | `.sops.yaml` (generated, git-ignored)                   |
| `nix-config/username`      | macOS user that nix-darwin/HM manage       | `secrets/host.yaml` (sops-encrypted, committed)         |
| `nix-config/hostname`      | host name, also the darwinConfigurations attribute | `secrets/host.yaml` (sops-encrypted, committed) |

The repo itself never names the Mac's user or host: `darwin/default.nix`
reads them from `NIX_CONFIG_USERNAME`/`NIX_CONFIG_HOSTNAME`, which
`darwin-switch` decrypts from `secrets/host.yaml`. Without them (pure
evaluation, CI) `darwinConfigurations` is simply empty.

## Setting up a machine

Run the setup script with your database. On a machine without this flake
activated yet, run it straight from the flake:

```bash
nix run .#nix-secrets-setup -- /path/to/database.kdbx
# or, once Home Manager is active:
nix-secrets-setup /path/to/database.kdbx
```

It unlocks the database once, then:

1. Checks each entry in the table above. For every missing one it asks for
   the value (with a suggested default), asks you to confirm it, stores it,
   and reads it back to verify before moving on to the next. For the age key
   you can generate a new one, import a key file, or use an existing
   `~/.config/sops/age/keys.txt`.
2. Installs the age key to `~/.config/sops/age/keys.txt` if it isn't there.
   An existing file with a different key is left alone and reported.
3. Regenerates `.sops.yaml` from the key label and public key. It refuses to
   write the file unless git ignores it.
4. Encrypts username and hostname into `secrets/host.yaml` if it is missing
   or out of date, then decrypts it again to check.

Rerunning it is safe: it only asks for what's missing. After changing a value
in KeePassXC, rerun it and commit the updated `secrets/host.yaml`.

## Applying the Mac's configuration

```bash
darwin-switch          # sudo darwin-rebuild switch --impure --flake .#<hostname>
darwin-switch build    # build without activating
```

For the very first activation, before `darwin-switch` is on `PATH`:

```bash
nix run .#darwin-switch
```

## Using a secret in a Home Manager module

Add values to `secrets/secrets.yaml` with `sops secrets/secrets.yaml`, then:

```nix
{ config, ... }:
{
  sops.secrets."my-token" = { };

  home.sessionVariables.MY_TOKEN_FILE = config.sops.secrets."my-token".path;
}
```

`config.sops.secrets."my-token".path` resolves to a runtime-only path outside
the Nix store holding the decrypted value.

## Adding or rotating a machine's access

Every machine shares the one age key from KeePassXC, so a new machine only
needs `nix-secrets-setup`. To rotate the key, while the old key is still in
`~/.config/sops/age/keys.txt`: add the new public key to `.sops.yaml`, run
`sops updatekeys secrets/*.yaml`, then replace the `keys.txt` attachment in
KeePassXC and the local key file, and rerun `nix-secrets-setup`.

## Threat model notes

- The age private key sits in plaintext at `~/.config/sops/age/keys.txt` on
  every machine that decrypts secrets. Protect it like an SSH private key.
- `secrets/host.yaml` reveals which fields exist (`username`, `hostname`),
  not their values.
- Losing the KeePassXC database without a backup means losing the ability to
  set up new machines; already set up machines keep working.
