# Secrets

**No secret is ever committed to this repo, encrypted or not.** KeePassXC is
the only source of truth; everything else is derived from it, on the machine,
outside the repo.

## Quick start

```bash
nix run .#nix-secrets-setup -- ~/path/to/vault.kdbx   # check the vault, fill in what's missing
nix run .#darwin-switch                               # first activation of the Mac
```

From then on, `nix-secrets-setup` (it remembers the vault) and `darwin-switch`.

## How it fits together

```text
KeePassXC vault ──nix-secrets-setup──▶ ~/.config/sops/age/keys.txt
                                      ~/.config/nix-secrets/.sops.yaml
                                      ~/.config/nix-secrets/host.yaml ────▶ darwin-switch
                                      ~/.config/nix-secrets/secrets.yaml ─▶ sops-nix
```

| KeePassXC entry             | Holds                                               |
| --------------------------- | --------------------------------------------------- |
| `nix-config/age-key`        | age private key (attachment `keys.txt`)             |
| `nix-config/age-key-label`  | name of that key in `.sops.yaml`                    |
| `nix-config/username`       | the Mac's user                                      |
| `nix-config/hostname`       | the Mac's host name (the darwinConfigurations name) |
| `nix-config/secrets/<name>` | runtime secrets named in `nix/secret-names.txt`     |

Values are in each entry's Password field. `nix/secret-names.txt` holds names
only; each becomes `sops.secrets.<name>` in Home Manager.

Why the repo stays clean:

- **Nothing to leak.** Anything pushed can be archived forever, and if its
  encryption is ever broken (X25519 by a future quantum computer, say), every
  copy opens. The vault is symmetric (AES-256/ChaCha20 with Argon2) and never
  has to be public.
- **Nix never reads the local files.** sops-nix gets `secrets.yaml` as a
  string path, so it is decrypted at activation and never copied to the Nix
  store. `darwin-switch` passes the username and hostname as environment
  variables (`--impure`); under pure evaluation `darwinConfigurations` is
  simply empty.
- **Mistakes are blocked.** `.gitignore` and the `forbid-secret-files`
  pre-commit hook reject `.env*`, `*.kdbx`, `*.sops.*`, `.sops.yaml`,
  `keys.txt`, `*.agekey` and `/secrets/`.

## Setting up a machine

`nix-secrets-setup` unlocks the vault once, shows what's defined, and asks how
to set anything missing:

- **automatically** where a value can be derived: this machine's age key (or
  a new one), the label `primary`, the current user, this machine's hostname;
- **from a .env file**;
- **guided**, choosing per secret: automatically, from .env, typed in, skip
  it, or skip all remaining;
- **skip all** for now.

Every value is read back from KeePassXC to confirm it. Rerun any time: it only
asks about what's missing, then refreshes the local files.

For scripts, `--auto`, `--env FILE` and `--skip-missing` do the same without
prompts: what they can't set is skipped, and anything that would need a
confirmation is refused. `--help` lists everything.

A `.env` file is parsed, never run, and refused if git tracks it:

```dotenv
NIX_SECRETS_AGE_KEY=AGE-SECRET-KEY-1...
NIX_SECRETS_AGE_KEY_LABEL=primary
NIX_SECRETS_USERNAME=me
NIX_SECRETS_HOSTNAME=my-mac
SECRET_GITHUB_TOKEN=...   # "github-token" in nix/secret-names.txt
```

Delete it once the values are in KeePassXC.

## Adding a runtime secret

1. Add its name to `nix/secret-names.txt`.
2. Run `nix-secrets-setup`; it asks for the value.
3. Use it in Home Manager:

   ```nix
   home.sessionVariables.GITHUB_TOKEN_FILE = config.sops.secrets.github-token.path;
   ```

## Guardrails

- **Defined values are never replaced**, except with `--rotate`.
- **Unreadable is not missing**: only KeePassXC's "not found" counts as
  missing; any other read error stops the script before it changes anything.
- **Other fields survive**: only the Password is written, and KeePassXC keeps
  the old value in the entry's history.
- **A `keys.txt` attachment that isn't an age key** is reported and left
  alone.
- **The vault is backed up** before the first change of a run, to
  `~/.local/state/nix-secrets/backups/` (newest 5 kept).
- **The KeePassXC app** is detected before writing: interactive runs ask
  first (save and lock the database in the app), scripted runs warn.
- **Local files** that would lose or change a value you didn't rotate are
  only replaced after you confirm (scripted runs refuse); the previous file
  is kept as `*.prev.yaml`. A local age key that doesn't match the vault is
  never replaced.

## Rotation

`nix-secrets-setup --rotate NAME` replaces one secret: `age-key`,
`age-key-label`, `username`, `hostname`, or a runtime secret's name. The new
value comes from the same choices as setup, or from `--auto` / `--env FILE`.
Nothing is in git, so there is never anything to re-encrypt or scrub.

**age key** (machine lost, key leaked, or yearly):

1. `nix-secrets-setup --rotate age-key` on one machine. The old key moves to
   `nix-config/age-key-previous` and to `keys.txt.rotated-<date>` locally;
   the local files are re-encrypted with the new key.
2. `nix-secrets-setup` on every other machine. A local key matching
   `age-key-previous` is recognised and replaced; any other is still refused.
3. `nix-secrets-setup --finish-age-key-rotation` once all machines are done.
   It moves `age-key-previous` to the recycle bin and lists old local keys to
   delete.

**Runtime secret**: issue the new credential at the provider,
`--rotate <name>`, rerun `nix-secrets-setup` and switch on every machine,
check it works, then revoke the old credential.

**Master password**: change it in the KeePassXC app (and consider a key file
or YubiKey). If the old one may be known, also rotate every secret: backups
and synced copies are still encrypted with it.

**Username / hostname**: `--rotate username` or `--rotate hostname`, then
`darwin-switch`.

| When                                    | Rotate                                  |
| --------------------------------------- | --------------------------------------- |
| A machine is lost or compromised        | the age key, then all runtime secrets   |
| One token leaked                        | that token                              |
| The vault leaked, strong password       | master password and key file            |
| The vault leaked, password may be known | everything                              |
| Routinely                               | the age key yearly; tokens per provider |

## Tests

```bash
nix run .#secrets-setup-tests
```

`dev/tests/secrets-setup.test.sh` covers every path (setting, guardrails,
rotation across several simulated machines) against throwaway vaults and age
keys, in one `mktemp -d` scratch directory. The script runs under `env -i`
with a fake `HOME` and `TMPDIR` there. The scratch directory is kept and
printed at the end: nothing is deleted recursively. Values are never
printed. Afterwards the suite checks, from file metadata only, that
`~/.config/sops`, `~/.config/nix-secrets`, `~/.local/state/nix-secrets` and
the working tree are unchanged. The suite runs on bash 3.2 and 5.

## Threat model

- The age key sits next to the files it decrypts, so the local encryption
  mostly keeps values out of casual reads and backups. Protect the machine
  (FileVault, screen lock).
- A leaked vault can be brute-forced offline forever: use a long random master
  password plus a key file or YubiKey.
- The username and hostname end up in the built system in `/nix/store`, which
  any local user can read. Real secrets never pass through Nix evaluation.
