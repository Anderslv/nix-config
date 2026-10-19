#!/usr/bin/env bash
# expect() evaluates its single-quoted condition later, which also uses
# variables shellcheck can't see being read.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

# Tests for scripts/secrets/setup.sh (nix-secrets-setup).
#
#   nix run .#secrets-setup-tests            # tests the packaged command
#   dev/tests/secrets-setup.test.sh          # tests the script in this checkout
#                                            # (needs keepassxc-cli, age, sops,
#                                            # jq, git on PATH)
#   ... --keep                               # keep the scratch dir for debugging
#
# Safety: every file is created under one fresh `mktemp -d` directory, and
# cleanup removes only that directory after checking its name. The script
# under test runs with `env -i`, a fake HOME/TMPDIR inside that directory, no
# global/system git config, and none of the caller's KEEPASSXC_*/SOPS_*
# variables, so it cannot reach a real vault, age key or ~/.config. Test
# databases are created here with the password "pw".

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SETUP="${SECRETS_SETUP:-$HERE/../../scripts/secrets/setup.sh}"
KEEP=""
[[ "${1:-}" == "--keep" ]] && KEEP=1

for tool in keepassxc-cli age age-keygen sops jq git; do
  command -v "$tool" >/dev/null || {
    echo "Missing $tool; run via: nix run .#secrets-setup-tests" >&2
    exit 1
  }
done

# setup.sh needs bash 4+ (macOS' /bin/bash is 3.2); nix run provides it.
if ! bash -c '[[ ${BASH_VERSINFO[0]} -ge 4 ]]'; then
  echo "The bash on PATH is too old; run via: nix run .#secrets-setup-tests" >&2
  exit 1
fi

# --- scratch directory ----------------------------------------------------------

BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
ROOT="$(mktemp -d "$BASE/secrets-setup-test.XXXXXX")"
if [[ -z "$ROOT" || ! -d "$ROOT" || "$ROOT" != "$BASE"/secrets-setup-test.* ]]; then
  echo "Could not create a scratch directory" >&2
  exit 1
fi
chmod 700 "$ROOT"

cleanup() {
  if [[ -n "$KEEP" ]]; then
    echo "Kept $ROOT"
    return
  fi
  case "$ROOT" in
    "$BASE"/secrets-setup-test.??????) rm -rf -- "$ROOT" ;;
    *) echo "Not removing unexpected path: $ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

# --- helpers --------------------------------------------------------------------

PASSED=0
FAILED=0
CASE=""

pass() {
  PASSED=$((PASSED + 1))
  printf '  \033[32m✓\033[0m %s\n' "$1"
}
failed() {
  FAILED=$((FAILED + 1))
  printf '  \033[31m✗\033[0m %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '      %s\n' "$2"; fi
}

# The fake machine commands run on; switch to simulate another machine.
MACHINE=home
machine_home() { echo "$CASE/$MACHINE"; }

# Runs a command with only the sandboxed environment. $CASE/bin comes first
# on PATH so a case can put shims there (e.g. a failing keepassxc-cli).
sandboxed() {
  env -i \
    PATH="$CASE/bin:$PATH" \
    HOME="$(machine_home)" \
    TMPDIR="$CASE/tmp" \
    LANG=C.UTF-8 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    NIX_CONFIG_DIR="$CASE/repo" \
    "$@"
}

# new_case <name> [runtime secret names...]
new_case() {
  CASE="$ROOT/$1"
  MACHINE=home
  shift
  mkdir -p "$CASE/home" "$CASE/tmp" "$CASE/bin" "$CASE/repo/nix"
  sandboxed git -C "$CASE/repo" init -q
  printf '%s\n' "# runtime secrets" "$@" >"$CASE/repo/nix/secret-names.txt"
  printf 'pw\npw\n' | sandboxed keepassxc-cli db-create -q -p "$CASE/t.kdbx" >/dev/null 2>&1
  echo
  echo "== $(basename "$CASE")"
}

# run_setup <stdin answers> [options...]; runs against the case's database
# and sets STATUS and OUT.
run_setup() {
  local answers="$1"
  shift
  set +e
  printf '%b' "$answers" | sandboxed "$SETUP" "$@" "$CASE/t.kdbx" >"$CASE/out.raw" 2>&1
  STATUS=$?
  set -e
  sed 's/\x1b\[[0-9;]*m//g' "$CASE/out.raw" >"$CASE/out.txt"
  OUT="$CASE/out.txt"
}

# kp_cli <command> [args...]: keepassxc-cli on the case's database.
kp_cli() {
  local cmd="$1"
  shift
  printf 'pw\n' | sandboxed keepassxc-cli "$cmd" -q "$CASE/t.kdbx" "$@"
}

kp_value() { kp_cli show -a Password "$1" 2>/dev/null || true; }

kp_exists() { kp_cli show "$1" >/dev/null 2>&1; }

secrets_dir() { echo "$(machine_home)/.config/nix-secrets"; }
key_file() { echo "$(machine_home)/.config/sops/age/keys.txt"; }
backup_dir() { echo "$(machine_home)/.local/state/nix-secrets/backups"; }

# decrypt <file in secrets dir, or a path> [age key file]
decrypt() {
  local file="$1"
  [[ "$file" == /* ]] || file="$(secrets_dir)/$file"
  sandboxed env SOPS_AGE_KEY_FILE="${2:-$(key_file)}" \
    sops decrypt --output-type json "$file" 2>/dev/null || true
}

expect() {
  if eval "$2"; then pass "$1"; else failed "$1" "${3:-}"; fi
}

file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || echo missing; }

expect_status() {
  if [[ "$STATUS" == "$1" ]]; then pass "exit status $1"; else failed "exit status $1" "got $STATUS; see $OUT"; fi
}
expect_output() {
  if grep -qF -- "$1" "$OUT"; then pass "output mentions: $1"; else failed "output mentions: $1" "see $OUT"; fi
}
expect_no_output() {
  if ! grep -qF -- "$1" "$OUT"; then pass "output does not mention: $1"; else failed "output does not mention: $1"; fi
}
expect_kp() {
  local got
  got="$(kp_value "$1")"
  if [[ "$got" == "$2" ]]; then pass "$1 = ${3:-$2}"; else failed "$1 = ${3:-$2}" "got '$got'"; fi
}
expect_json() {
  local got
  got="$(decrypt "$1" | jq -r "$2")"
  if [[ "$got" == "$3" ]]; then pass "$1 $2 = $3"; else failed "$1 $2 = $3" "got '$got'"; fi
}
expect_mode() {
  local got
  got="$(file_mode "$1")"
  if [[ "$got" == "$2" ]]; then pass "$(basename "$1") has mode $2"; else failed "$(basename "$1") has mode $2" "got $got"; fi
}
expect_missing() {
  if [[ ! -e "$1" ]]; then pass "$2"; else failed "$2" "$1 exists"; fi
}

# --- cases ----------------------------------------------------------------------

new_case auto-manual-skip github-token openai-key
# Wrong password first, then auto for all; github-token has no automatic
# value, so: manual with a mismatched confirmation, manual again, then skip
# openai-key.
run_setup 'wrong\npw\na\nm\nabc\nabd\nm\ntok-123\ntok-123\ns\n'
expect_status 0
expect_output "Could not unlock the database, try again."
expect_kp nix-config/age-key-label primary
expect_kp nix-config/username "$(sandboxed id -un)"
expect_kp nix-config/secrets/github-token tok-123 "tok-123 (after a mismatched confirmation)"
expect_kp nix-config/secrets/openai-key "" "(nothing, skipped)"
expect_output "The two entries differ."
expect_output "Skipped for now"
expect_json secrets.yaml '."github-token"' tok-123
expect_json secrets.yaml 'has("openai-key")' false
expect_json host.yaml .username "$(sandboxed id -un)"
expect_mode "$(secrets_dir)" 700
expect_mode "$(secrets_dir)/secrets.yaml" 600
expect_mode "$CASE/home/.config/sops/age/keys.txt" 600
if grep -q 'tok-123' "$(secrets_dir)/secrets.yaml"; then failed "secrets.yaml is encrypted"; else pass "secrets.yaml is encrypted"; fi

# Same vault: the skipped secret is set from a .env file on the next run.
printf 'SECRET_OPENAI_KEY="sk-xyz"\n' >"$CASE/my.env"
run_setup "pw\ng\ne\n$CASE/my.env\n"
expect_status 0
expect_kp nix-config/secrets/openai-key sk-xyz
expect_json secrets.yaml '."openai-key"' sk-xyz
expect_output "host.yaml is up to date"
expect_output "All secrets are defined."
expect_output "consider deleting that file"

# Nothing missing: a third run asks nothing and changes nothing.
run_setup 'pw\n'
expect_status 0
expect_output "secrets.yaml is up to date"
expect_no_output "How do you want to set them?"

new_case env-file github-token
age-keygen -o "$CASE/key.txt" 2>/dev/null
CANARY="$CASE/env-injection-canary"
{
  echo "# comment"
  echo "export NIX_SECRETS_AGE_KEY=$(grep AGE-SECRET-KEY "$CASE/key.txt")"
  echo "NIX_SECRETS_AGE_KEY_LABEL='mylabel'"
  echo "NIX_SECRETS_USERNAME=alice"
  echo 'NIX_SECRETS_HOSTNAME="mini-1"'
  # Must be stored literally; if the parser ever ran it, the canary appears.
  # shellcheck disable=SC2016 # the $(...) must stay literal
  printf 'SECRET_GITHUB_TOKEN=ghp_$(touch %s)`touch %s`abc\n' "$CANARY" "$CANARY"
} >"$CASE/all.env"
run_setup 'pw\n' --env "$CASE/all.env"
expect_status 0
expect_kp nix-config/age-key-label mylabel
expect_kp nix-config/username alice
expect_kp nix-config/hostname mini-1
expect_kp nix-config/secrets/github-token "ghp_\$(touch $CANARY)\`touch $CANARY\`abc" "the literal \$(...) text"
expect_missing "$CANARY" ".env values are never executed"
if grep -q "&mylabel $(age-keygen -y "$CASE/key.txt")" "$(secrets_dir)/.sops.yaml"; then
  pass ".sops.yaml uses the label and key from .env"
else
  failed ".sops.yaml uses the label and key from .env"
fi
expect_json host.yaml .hostname mini-1

new_case skip-one-then-all github-token
# Guided: age key automatically, skip the label, skip all remaining.
run_setup 'pw\ng\na\ns\nS\n'
expect_status 0
expect_output "nix-config/age-key stored and verified"
expect_kp nix-config/age-key-label "" "(nothing, skipped)"
expect_kp nix-config/username "" "(nothing, skipped)"
expect_output "nix-config/secrets/github-token"
expect_output "username/hostname not both defined; skipping host.yaml"

new_case invalid-label
run_setup 'pw\ng\na\nm\nmy label\nm\nok-label\ny\nS\n'
expect_status 0
expect_output "The label may only contain letters, digits, - and _."
expect_kp nix-config/age-key-label ok-label

new_case skip-missing
run_setup 'pw\n' --skip-missing
expect_status 0
expect_output "No age key in KeePassXC; skipping all local files."
expect_missing "$(secrets_dir)" "no local files without an age key"

new_case tracked-env-refused
echo 'NIX_SECRETS_USERNAME=x' >"$CASE/repo/.env"
sandboxed git -C "$CASE/repo" add -f .env
run_setup 'pw\n' --env "$CASE/repo/.env"
expect_status 1
expect_output "is tracked by git; refusing to read secrets from it."
expect_kp nix-config/username "" "(nothing stored)"

new_case local-key-mismatch
mkdir -p "$CASE/home/.config/sops/age"
age-keygen -o "$CASE/home/.config/sops/age/keys.txt" 2>/dev/null
cp "$CASE/home/.config/sops/age/keys.txt" "$CASE/local-key.before"
age-keygen -o "$CASE/other.txt" 2>/dev/null
printf 'NIX_SECRETS_AGE_KEY=%s\n' "$(grep AGE-SECRET-KEY "$CASE/other.txt")" >"$CASE/k.env"
# The .env only has the age key (--env skips the rest); syncing then finds
# the local key differs from the one now in KeePassXC.
run_setup 'pw\n' --env "$CASE/k.env"
expect_status 1
expect_output "holds a different key than KeePassXC; not touching it."
if cmp -s "$CASE/local-key.before" "$CASE/home/.config/sops/age/keys.txt"; then
  pass "local key file left unchanged"
else
  failed "local key file left unchanged"
fi

# --- guardrails -----------------------------------------------------------------

new_case keeps-other-fields
# An entry left over with its value in UserName and an empty Password is
# treated as missing; filling in the Password keeps the UserName.
kp_cli mkdir nix-config >/dev/null
kp_cli add -u old-style nix-config/username >/dev/null
run_setup 'pw\n' --auto
expect_status 0
expect_kp nix-config/username "$(sandboxed id -un)"
expect "UserName field kept" '[[ "$(kp_cli show -a UserName nix-config/username)" == old-style ]]'
cp "$CASE/t.kdbx" "$CASE/t.before"
backups_before="$(find "$(backup_dir)" -name '*.kdbx' | wc -l)"
run_setup 'pw\n' --auto
expect_status 0
expect "a run with nothing to set leaves the vault untouched" 'cmp -s "$CASE/t.kdbx" "$CASE/t.before"'
expect "and makes no backup" '[[ "$(find "$(backup_dir)" -name "*.kdbx" | wc -l)" == "$backups_before" ]]'

new_case read-error-stops
run_setup 'pw\n' --auto
cp "$CASE/t.kdbx" "$CASE/t.before"
real_cli="$(command -v keepassxc-cli)"
# A keepassxc-cli that can't read one entry for a reason other than "not found".
cat >"$CASE/bin/keepassxc-cli" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == show && " \$* " == *" nix-config/username "* ]]; then
  cat >/dev/null
  echo "Error while reading the database: simulated failure" >&2
  exit 1
fi
exec "$real_cli" "\$@"
EOF
chmod +x "$CASE/bin/keepassxc-cli"
run_setup 'pw\n' --auto
rm "$CASE/bin/keepassxc-cli"
expect_status 1
expect_output "Could not read from KeePassXC"
expect_output "Stopping without changing anything."
expect "the vault is unchanged" 'cmp -s "$CASE/t.kdbx" "$CASE/t.before"'

new_case age-attachment-conflict
kp_cli mkdir nix-config >/dev/null
kp_cli add nix-config/age-key >/dev/null
echo "not an age key" >"$CASE/other-attachment"
kp_cli attachment-import nix-config/age-key keys.txt "$CASE/other-attachment" >/dev/null
run_setup 'pw\n' --auto
expect_status 1
expect_output "has a keys.txt attachment that isn't an age key; not touching it"
expect_output "Resolve these in KeePassXC by hand"
expect "the attachment is unchanged" \
  'kp_cli attachment-export --stdout nix-config/age-key keys.txt | cmp -s - "$CASE/other-attachment"'

new_case local-file-guard github-token
printf 'SECRET_GITHUB_TOKEN=one\n' >"$CASE/one.env"
run_setup 'pw\n' --auto
run_setup 'pw\n' --env "$CASE/one.env"
expect_json secrets.yaml '."github-token"' one
# Change the value behind the script's back.
printf 'pw\ntwo\n' | sandboxed keepassxc-cli edit -q -p "$CASE/t.kdbx" nix-config/secrets/github-token
run_setup 'pw\n' --skip-missing
expect_status 1
expect_output "differs from KeePassXC for:"
expect_output "github-token (changed)"
expect_output "Not replacing"
expect_json secrets.yaml '."github-token"' one
run_setup 'pw\nn\n'
expect_status 0
expect_output "Kept $(secrets_dir)/secrets.yaml unchanged."
expect_json secrets.yaml '."github-token"' one
run_setup 'pw\ny\n'
expect_status 0
expect_json secrets.yaml '."github-token"' two
expect_json secrets.prev.yaml '."github-token"' one
expect_mode "$(secrets_dir)/secrets.prev.yaml" 600
# Dropping a name from the manifest would remove its value: also refused.
printf '# runtime secrets\n' >"$CASE/repo/nix/secret-names.txt"
run_setup 'pw\n' --skip-missing
expect_status 1
expect_output "github-token (removed)"

new_case vault-backups
mkdir -p "$(backup_dir)"
for i in 1 2 3 4 5 6; do
  echo "old $i" >"$(backup_dir)/t.2000010$i-000000-1.kdbx"
done
cp "$CASE/t.kdbx" "$CASE/t.before"
run_setup 'pw\n' --auto
expect_status 0
expect_output "Backed up the vault to"
expect "five backups are kept" '[[ "$(find "$(backup_dir)" -name "t.*.kdbx" | wc -l)" == 5 ]]'
expect "the oldest ones are pruned" '[[ ! -e "$(backup_dir)/t.20000101-000000-1.kdbx" && ! -e "$(backup_dir)/t.20000102-000000-1.kdbx" ]]'
newest="$(find "$(backup_dir)" -name 't.*.kdbx' | sort | tail -n 1)"
expect "the newest backup is the vault from before this run" 'cmp -s "$newest" "$CASE/t.before"'
expect_mode "$newest" 600
expect_mode "$(backup_dir)" 700

new_case app-running-warning github-token
printf '#!/usr/bin/env bash\nexit 0\n' >"$CASE/bin/pgrep"
chmod +x "$CASE/bin/pgrep"
cp "$CASE/t.kdbx" "$CASE/t.before"
run_setup 'pw\na\nn\n'
expect_status 1
expect_output "The KeePassXC app is running."
expect_output "Stopped before changing anything."
expect "the vault is unchanged" 'cmp -s "$CASE/t.kdbx" "$CASE/t.before"'
run_setup 'pw\n' --auto
expect_status 0
expect_output "The KeePassXC app is running."
expect_kp nix-config/age-key-label primary "primary (non-interactive runs warn and continue)"

# --- rotation -------------------------------------------------------------------

new_case rotate-runtime-secret github-token
printf 'SECRET_GITHUB_TOKEN=one\n' >"$CASE/one.env"
printf 'SECRET_GITHUB_TOKEN=two\n' >"$CASE/two.env"
run_setup 'pw\n' --auto
run_setup 'pw\n' --env "$CASE/one.env"
run_setup 'pw\nc\n' --rotate github-token
expect_status 0
expect_output "Rotation cancelled; nothing changed."
expect_kp nix-config/secrets/github-token one
run_setup 'pw\n' --rotate github-token --env "$CASE/two.env"
expect_status 0
expect_output "The old value stays in the entry's history"
expect_kp nix-config/secrets/github-token two
expect "the old value is in the entry history" \
  'kp_cli export -f xml | grep -q ">one</Value>"'
expect_json secrets.yaml '."github-token"' two
expect_json secrets.prev.yaml '."github-token"' one
run_setup 'pw\n' --rotate not-a-secret
expect_status 1
expect_output "Unknown secret 'not-a-secret'"

new_case rotate-undefined github-token
run_setup 'pw\n' --rotate github-token --auto
expect_status 1
expect_output "is not defined yet; run without --rotate to set it."

new_case rotate-username
run_setup 'pw\n' --auto
printf 'NIX_SECRETS_USERNAME=new-user\n' >"$CASE/user.env"
run_setup 'pw\n' --rotate username --env "$CASE/user.env"
expect_status 0
expect_output "Current value: $(sandboxed id -un)"
expect_kp nix-config/username new-user
expect_json host.yaml .username new-user

new_case rotate-age-key github-token
printf 'SECRET_GITHUB_TOKEN=tok\n' >"$CASE/tok.env"
run_setup 'pw\n' --auto
run_setup 'pw\n' --env "$CASE/tok.env"
old_public="$(age-keygen -y "$(key_file)")"
# Machine b set up before the rotation, with the old key; machine c has an
# unrelated key.
MACHINE=b
run_setup 'pw\n' --skip-missing
expect_status 0
MACHINE=c
mkdir -p "$(dirname "$(key_file)")"
age-keygen -o "$(key_file)" 2>/dev/null
cp "$(key_file)" "$CASE/c-key.before"
MACHINE=home

run_setup 'pw\n' --rotate age-key --auto
expect_status 0
expect_output "Kept the current key in nix-config/age-key-previous"
expect_output "The age key was rotated; kept the old one at"
new_public="$(age-keygen -y "$(key_file)")"
expect "a new key is installed" '[[ "$new_public" != "$old_public" ]]'
expect "KeePassXC holds the new key" \
  '[[ "$(kp_cli attachment-export --stdout nix-config/age-key keys.txt | age-keygen -y)" == "$new_public" ]]'
expect "age-key-previous holds the old key" \
  '[[ "$(kp_cli attachment-export --stdout nix-config/age-key-previous keys.txt | age-keygen -y)" == "$old_public" ]]'
rotated=("$(key_file)".rotated-*)
expect "the old local key is kept" '[[ "$(age-keygen -y "${rotated[0]}")" == "$old_public" ]]'
expect_mode "${rotated[0]}" 600
expect_json secrets.yaml '."github-token"' tok
expect_json host.yaml .username "$(sandboxed id -un)"

MACHINE=b
run_setup 'pw\n' --skip-missing
expect_status 0
expect_output "The age key was rotated; kept the old one at"
expect "machine b now has the new key" '[[ "$(age-keygen -y "$(key_file)")" == "$new_public" ]]'
expect_json secrets.yaml '."github-token"' tok

MACHINE=c
run_setup 'pw\n' --skip-missing
expect_status 1
expect_output "holds a different key than KeePassXC; not touching it."
expect "machine c's unrelated key is untouched" 'cmp -s "$(key_file)" "$CASE/c-key.before"'
MACHINE=home

run_setup 'pw\n' --rotate age-key --auto
expect_status 1
expect_output "still holds the key from an earlier rotation"

run_setup 'pw\nn\n' --finish-age-key-rotation
expect_status 0
expect "age-key-previous is kept when declined" 'kp_exists nix-config/age-key-previous'
run_setup 'pw\ny\n' --finish-age-key-rotation
expect_status 0
expect_output "Moved nix-config/age-key-previous to the recycle bin"
expect_output "Old local key kept at"
expect "age-key-previous is gone" '! kp_exists nix-config/age-key-previous'
expect "it is in the recycle bin" 'kp_cli ls -R -f | grep -q "^Recycle Bin/age-key-previous$"'

echo
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
