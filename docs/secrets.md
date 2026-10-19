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

The same choices work non-interactively: `--auto`, `--env FILE`,
`--skip-missing`. Use `--help` for all options.

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

## Rotating the age key

The local sops files are always regenerated from KeePassXC, so rotation is:
replace the `keys.txt` attachment of `nix-config/age-key` (or delete the entry
and let the setup create a new one), move `~/.config/sops/age/keys.txt` aside,
and rerun `nix-secrets-setup` on each machine.

## Tests

```bash
nix run .#secrets-setup-tests
```

`dev/tests/secrets-setup.test.sh` exercises every path (automatic, .env,
guided, skip, validation, refusals) against throwaway vaults. Everything
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
