# Secrets (sops + age + KeePassXC)

Secrets (API tokens, personal credentials, etc.) are encrypted at rest with
[sops](https://github.com/getsops/sops) using [age](https://age-encryption.org/)
as the cipher, and wired into Home Manager via
[sops-nix](https://github.com/Mic92/sops-nix). The age *private* key never
lives in this repo; it's stored as an attachment in KeePassXC and copied
onto each machine once, by hand.

This works identically on macOS, NixOS, and any other Linux box, because the
wiring lives in the shared Home Manager module (`home/modules/secrets.nix`),
not in a NixOS-only one — every machine in `home/default.nix` picks it up
the same way.

## Why this combination

- **sops** keeps secrets as git-friendly, per-key-encrypted YAML — diffable
  structure, encrypted values, reviewable in a PR.
- **age** is a small, modern cipher with first-class sops and sops-nix
  support and none of GPG's keyring/trust-model baggage.
- **KeePassXC** is already the password vault for this setup (see
  `scripts/ssh/keepassxc-prompt.sh`); storing the age identity there reuses
  a vault that's already synced and backed up across machines, instead of
  inventing a second secret-distribution channel.

## One-time setup (do this once, on a trusted machine)

1. Generate a personal age key pair:

   ```bash
   age-keygen -o age-key.txt
   ```

   This prints `Public key: age1...` — copy it.

2. Store the private key in KeePassXC:
   - Create (or reuse) an entry titled `sops-age-key` in your KeePassXC
     database.
   - Attach `age-key.txt` to that entry as `keys.txt`.
   - Securely delete the plaintext file afterward, e.g. `shred -u age-key.txt`.

3. Put the public key in `.sops.yaml` at the repo root, replacing the
   placeholder under `keys:`.

4. Create the secrets file and add your first secret:

   ```bash
   sops secrets/secrets.yaml
   ```

   sops reads `.sops.yaml`, encrypts to the recipients listed there, and
   opens `$EDITOR` on the plaintext. Commit the resulting encrypted file —
   it's safe to store in git.

## Bootstrapping a new machine

On every machine that needs to decrypt secrets:

```bash
sops-age-bootstrap /path/to/database.kdbx
```

`sops-age-bootstrap` is one of this flake's Home Manager packages (run
`home-manager switch` first if it's not on `PATH` yet). It prompts for the
KeePassXC master password, exports the `keys.txt` attachment from the
`sops-age-key` entry, and writes it to `~/.config/sops/age/keys.txt`
(mode `0600`) — the path `sops.age.keyFile` points at.

After that, `home-manager switch` can decrypt any secret declared in a
`home/` module.

## Using a secret in a Home Manager module

```nix
{ config, ... }:
{
  sops.secrets."my-token" = { };

  home.sessionVariables.MY_TOKEN_FILE = config.sops.secrets."my-token".path;
}
```

`config.sops.secrets."my-token".path` resolves to a runtime-only path
(outside the Nix store, so it's never world-readable and never copied to
other machines via substituters) that holds the decrypted value.

## Adding or rotating a machine's access

Add the new identity as another `age:` entry under `keys:` and
`key_groups:` in `.sops.yaml` — either another personal key, or a per-host
key derived from that machine's SSH host key via `ssh-to-age`, if a NixOS
host later needs system-level secrets rather than per-user ones — then
re-encrypt existing files so they include the new recipient:

```bash
sops updatekeys secrets/secrets.yaml
```

## Threat model notes

- The age private key touches disk in plaintext at
  `~/.config/sops/age/keys.txt` on every machine that decrypts secrets.
  That's the same trust boundary as any sops-nix setup; protect it the way
  you'd protect an SSH private key (full-disk encryption, screen lock,
  etc.).
- Losing the KeePassXC database without a backup means losing the ability
  to bootstrap *new* machines, but already-bootstrapped machines keep
  working — the key only needs to be read from KeePassXC once per machine.
- A single shared personal key is the simplest model and what this draft
  ships. If a secret should only ever be readable on specific machines,
  split recipients per machine (see above) instead of using one key
  everywhere.
