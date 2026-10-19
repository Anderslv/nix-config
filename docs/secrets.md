# Secrets (KeePassXC → local sops files)

**No secret is ever committed to this repo, encrypted or not.** KeePassXC is
the only source of truth, and the vault is managed outside the repo.
`nix-secrets-setup` checks the vault and derives local files from it, outside
the repo. Home Manager ([sops-nix](https://github.com/Mic92/sops-nix)) and
`darwin-switch` read those files at runtime.

Why not commit encrypted files? Anything pushed can be archived by anyone
indefinitely. If the encryption is ever broken (e.g. age's X25519 by a future
quantum computer), every past ciphertext opens. KeePassXC's KDBX4 is symmetric
(AES-256/ChaCha20 with Argon2), and the vault never has to be public.

## What lives where

KeePassXC entries in the group `nix-config` (override with
`NIX_SECRETS_GROUP`); values are in each entry's Password field:

| KeePassXC entry               | Holds                                              | Derived local file                             |
| ----------------------------- | -------------------------------------------------- | ---------------------------------------------- |
| `nix-config/age-key`          | age private key, attachment `keys.txt`             | `~/.config/sops/age/keys.txt`                  |
| `nix-config/age-key-label`    | name of the key in `.sops.yaml`                    | `~/.config/nix-secrets/.sops.yaml`             |
| `nix-config/username`         | macOS user that nix-darwin/HM manage               | `~/.config/nix-secrets/host.yaml` (encrypted)  |
| `nix-config/hostname`         | host name, also the darwinConfigurations attribute | `~/.config/nix-secrets/host.yaml` (encrypted)  |
| `nix-config/secrets/<name>`   | runtime secrets listed in `nix/secret-names.txt`   | `~/.config/nix-secrets/secrets.yaml` (encrypted) |

`nix/secret-names.txt` holds only names. Each name becomes
`sops.secrets.<name>` in Home Manager.

How the pieces avoid the repo:

- Nix never reads the local files. `sops.defaultSopsFile` is a string
  (`"/Users/…/.config/nix-secrets/secrets.yaml"`), not a path, so it is never
  copied to the Nix store. sops-nix decrypts it at activation.
- The Mac's username and hostname are needed while the flake is evaluated, so
  `darwin-switch` decrypts `host.yaml` and passes them as environment
  variables (`--impure`). Under pure evaluation (CI, `nix flake check`),
  `darwinConfigurations` is empty.
- `.gitignore` covers `.env*`, `*.kdbx`, `*.sops.*`, `.sops.yaml`,
  `keys.txt`, `*.agekey` and `/secrets/`, and the `forbid-secret-files`
  pre-commit hook rejects them even when force-added.

## Setting up a machine

```bash
nix run .#nix-secrets-setup -- /path/to/database.kdbx   # before Home Manager is active
nix-secrets-setup /path/to/database.kdbx                # afterwards
```

It unlocks the vault once and lists which secrets are defined. If any are
missing, it asks how to set them:

- **[a] automatically** where a value can be derived: a new age key (or this
  machine's existing one), the label `primary`, the current user, and this
  machine's hostname. Anything without an automatic value is asked for.
- **[e] from a .env file**, asking for whatever the file doesn't have.
- **[g] guided**: for each secret choose automatic, .env, enter it now, skip
  this one, or skip all remaining.
- **[s] skip all for now.**

Each stored value is read back from KeePassXC to confirm it, and manual
entries are confirmed (hidden secrets are typed twice). Skipped secrets are
listed at the end; rerun the command to set them. Rerunning when everything
is defined only refreshes the local files.

`--auto`, `--env FILE` and `--skip-missing` do the same without any prompts:
secrets they can't set are skipped, and anything that would need a
confirmation is refused. Use `--help` for all options.

### Guardrails

- **A defined value is never replaced** except through `--rotate`. The age
  key attachment is never force-imported outside a rotation either.
- **Unreadable is not missing.** Only KeePassXC's "not found" counts as
  missing; any other read error stops the script before it changes anything.
- **Other fields are kept.** Values are written to the Password field only,
  and KeePassXC keeps the previous value in the entry's history.
- **An attachment that isn't an age key** in `nix-config/age-key` is
  reported and left alone; resolve it by hand.
- **The vault is backed up** before the first write of a run, to
  `~/.local/state/nix-secrets/backups/` (mode 700, newest 5 kept). Runs that
  change nothing make no backup.
- **The KeePassXC app** is detected before writing: interactive runs ask to
  continue (save and lock the database in the app first), non-interactive
  runs warn.
- **Local files**: if a value in `host.yaml`/`secrets.yaml` would be removed
  or changed and you didn't ask for that (`--rotate`), the key names (never
  values) are listed and the script asks first; non-interactive runs refuse.
  The previous file is kept as `*.prev.yaml`. A file the installed key can't
  decrypt is never replaced, and neither is a local age key that doesn't
  match KeePassXC.

### .env format

`KEY=value` lines (optional `export`, quotes, `#` comments). Values are
parsed literally, never executed. A `.env` tracked by git is refused. Delete
the file once its values are in KeePassXC.

```dotenv
NIX_SECRETS_AGE_KEY=AGE-SECRET-KEY-1...
NIX_SECRETS_AGE_KEY_LABEL=primary
NIX_SECRETS_USERNAME=me
NIX_SECRETS_HOSTNAME=my-mac
SECRET_GITHUB_TOKEN=...   # for "github-token" in nix/secret-names.txt
```

## Applying the Mac's configuration

```bash
darwin-switch          # sudo darwin-rebuild switch --impure --flake .#<hostname>
darwin-switch build    # build only
nix run .#darwin-switch   # first activation, before darwin-switch is on PATH
```

## Adding a runtime secret

1. Add its name to `nix/secret-names.txt`.
2. Run `nix-secrets-setup`; it asks for the missing value.
3. Use it in a Home Manager module:

   ```nix
   { config, ... }:
   {
     home.sessionVariables.GITHUB_TOKEN_FILE = config.sops.secrets.github-token.path;
   }
   ```

## Rotation

`nix-secrets-setup --rotate NAME` replaces one defined secret. `NAME` is
`age-key`, `age-key-label`, `username`, `hostname` or a name from
`nix/secret-names.txt`. It asks for the new value like the setup does
(automatically, from a .env file, typed in, or cancel), or takes it from
`--auto`/`--env FILE` without prompts. The old value stays in the entry's
history, the vault is backed up first, and the local files are regenerated.

Rotation is simpler than usual because nothing is in git: there are no old
ciphertexts to re-encrypt and no history to clean up.

### age key

When: a machine is lost or compromised, the key file leaked, or once a year.

1. `nix-secrets-setup --rotate age-key` on one machine. The current key is
   kept in `nix-config/age-key-previous`, a new one goes into
   `nix-config/age-key`, the local key moves to `keys.txt.rotated-<date>`,
   and the local files are re-encrypted with the new key.
2. On every other machine, run `nix-secrets-setup`. A local key that matches
   `age-key-previous` is recognised, set aside the same way and replaced; any
   other mismatching key is still refused. Then `darwin-switch` /
   `home-manager switch`.
3. When all machines are done: `nix-secrets-setup --finish-age-key-rotation`
   moves `age-key-previous` to KeePassXC's recycle bin and lists the old local
   key files to delete. A new age key rotation is refused until then.

A lost or compromised machine had every runtime secret in its
`secrets.yaml`, so rotate those too (next section).

### Runtime secrets (tokens, passwords)

1. Issue the new credential at the provider; keep the old one valid for now.
2. `nix-secrets-setup --rotate <name>` and enter the new value.
3. Run `nix-secrets-setup` on every machine and switch; sops-nix updates the
   decrypted file on activation.
4. Check the new value works, then revoke the old one at the provider.

### KeePassXC master password / key file

Change it in the KeePassXC app; consider adding a key file or YubiKey
challenge-response. If the old password may be known, that alone isn't
enough: backups, synced copies and cloud version history are still encrypted
with it. Rotate every secret inside (sections above) and delete old copies
you control, including `~/.local/state/nix-secrets/backups/`.

### Username / hostname

`--rotate username` / `--rotate hostname`, then `darwin-switch` (it builds
the configuration named after the new hostname). Values that were public
before (e.g. in old git history) should be assumed known; rename the host
(`scutil --set LocalHostName …`) if that matters.

### Which to rotate

| Event                                    | Rotate                                          |
| ---------------------------------------- | ----------------------------------------------- |
| Machine lost or compromised              | age key, then all runtime secrets               |
| One token leaked                         | that token                                      |
| `.kdbx` leaked, strong master password   | master password + key file; secrets if long-lived |
| `.kdbx` leaked, password may be known    | everything                                      |
| Routine                                  | age key yearly; tokens per provider policy      |

## Tests

```bash
nix run .#secrets-setup-tests
```

`dev/tests/secrets-setup.test.sh` exercises every path (automatic, .env,
guided, skip, validation, guardrails, rotation across several simulated
machines) against throwaway vaults. Everything
happens in one `mktemp -d` directory with a fake `HOME` and a scrubbed
environment. Nothing outside it is read or written, and only that directory
is removed afterwards.

## Threat model notes

- The age private key is in plaintext at `~/.config/sops/age/keys.txt`, next
  to the files it decrypts, so the local encryption mainly keeps casual reads
  and backups from exposing values. Protect the machine (FileVault, screen
  lock).
- A leaked `.kdbx` can be brute-forced offline forever. Use a long random
  master password plus a key file or YubiKey challenge-response.
- The username and hostname end up in the built system in `/nix/store`, which
  is world-readable locally. Real secrets never pass through Nix evaluation;
  they are only decrypted at runtime.
