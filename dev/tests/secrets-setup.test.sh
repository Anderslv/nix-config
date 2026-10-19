#!/usr/bin/env bash
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
  [[ -n "${2:-}" ]] && printf '      %s\n' "$2"
}

# Runs a command with only the sandboxed environment.
sandboxed() {
  env -i \
    PATH="$PATH" \
    HOME="$CASE/home" \
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
  shift
  mkdir -p "$CASE/home" "$CASE/tmp" "$CASE/repo/nix"
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

kp_value() {
  printf 'pw\n' | sandboxed keepassxc-cli show -q -a Password "$CASE/t.kdbx" "$1" 2>/dev/null || true
}

secrets_dir() { echo "$CASE/home/.config/nix-secrets"; }

decrypt() {
  (cd "$(secrets_dir)" &&
    sandboxed env SOPS_AGE_KEY_FILE="$CASE/home/.config/sops/age/keys.txt" \
      sops decrypt --output-type json "$1" 2>/dev/null) || true
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
# The .env only has the age key, so the rest is skipped with S; syncing then
# finds the local key differs from the one now in KeePassXC.
run_setup 'pw\nS\n' --env "$CASE/k.env"
expect_status 1
expect_output "holds a different key than KeePassXC; not touching it."
if cmp -s "$CASE/local-key.before" "$CASE/home/.config/sops/age/keys.txt"; then
  pass "local key file left unchanged"
else
  failed "local key file left unchanged"
fi

echo
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
