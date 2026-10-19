#!/usr/bin/env bash
# expect() evaluates its single-quoted conditions later, reading variables
# that look unused at first sight.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

# Tests for nix-secrets-setup (scripts/secrets/setup.sh).
#
#   nix run .#secrets-setup-tests      the packaged command
#   dev/tests/secrets-setup.test.sh    this checkout's script (needs
#                                      keepassxc-cli, age, sops, jq, git, and
#                                      bash 4+ on PATH for the script itself)
#
# The suite itself runs on bash 3.2 and 5, with GNU or BSD tools.
#
# Safety:
# - Everything happens in one fresh `mktemp -d` directory, which is left in
#   place and printed at the end. Nothing is ever deleted recursively.
# - The script and the tools it calls run with `env -i`: a fake HOME and
#   TMPDIR inside the scratch directory, no git config, and nothing else from
#   the caller's environment, so they can't reach a real vault, key or
#   ~/.config. HOME is never changed anywhere else.
# - Test vaults use the password "test-password-1", and the age keys are new.
# - Afterwards the suite checks that the real secrets locations in HOME and
#   this working tree are unchanged. It only compares file metadata (size,
#   times, inode, mode) and never reads their contents.
# - Values are never printed: checks name the entry, not what it holds.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SETUP="${SECRETS_SETUP:-$HERE/../../scripts/secrets/setup.sh}"

for tool in keepassxc-cli age age-keygen sops jq git; do
  if ! command -v "$tool" >/dev/null; then
    echo "Missing $tool; run via: nix run .#secrets-setup-tests" >&2
    exit 1
  fi
done
if ! bash -c '[[ ${BASH_VERSINFO[0]} -ge 4 ]]'; then
  echo "nix-secrets-setup needs bash 4+ on PATH; run via: nix run .#secrets-setup-tests" >&2
  exit 1
fi

# --- scratch directory ----------------------------------------------------------

BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
ROOT="$(mktemp -d "$BASE/secrets-setup-test.XXXXXX")"
if [[ ! -d "$ROOT" ]]; then
  echo "Could not create a scratch directory" >&2
  exit 1
fi
chmod 700 "$ROOT"

# --- the real environment, which must stay untouched -------------------------------

# file_meta <path>: size, mtime, ctime, inode and mode, without reading it.
file_meta() {
  stat -c '%s %Y %Z %i %a' "$1" 2>/dev/null || stat -f '%z %m %c %i %Lp' "$1" 2>/dev/null || echo missing
}

# snapshot <dir>...: every path under the directories (skipping .git) with
# its metadata.
snapshot() {
  local dir path
  for dir in "$@"; do
    if [[ ! -e "$dir" ]]; then
      echo "$dir (absent)"
      continue
    fi
    find "$dir" -path "$dir/.git" -prune -o -print 2>/dev/null | LC_ALL=C sort |
      while IFS= read -r path; do
        printf '%s %s\n' "$path" "$(file_meta "$path")"
      done
  done
}

# find_worktree <dir>: the nearest enclosing directory with a .git, if any.
find_worktree() {
  local dir="$1"
  while [[ -n "$dir" && "$dir" != / ]]; do
    if [[ -e "$dir/.git" ]]; then
      echo "$dir"
      return
    fi
    dir="$(dirname "$dir")"
  done
}

REAL_SECRETS_DIRS=(
  "${HOME:?HOME is not set}/.config/sops"
  "$HOME/.config/nix-secrets"
  "$HOME/.local/state/nix-secrets"
)
# The checkout this script is in; when packaged, the one it is run from.
WORKTREE="$(find_worktree "$(cd "$HERE/../.." && pwd -P)")"
[[ -n "$WORKTREE" ]] || WORKTREE="$(find_worktree "$(pwd -P)")"

snapshot "${REAL_SECRETS_DIRS[@]}" >"$ROOT/real-home.before"
[[ -z "$WORKTREE" ]] || snapshot "$WORKTREE" >"$ROOT/worktree.before"

# --- cases, machines and runs -----------------------------------------------------
#
# A case is a directory with a test vault, a repo, and one or more machines
# (fake home directories). $CASE/bin comes first on PATH, for shims.

CASE=""
MACHINE=home

# new_case <name> [runtime secret names...]
new_case() {
  CASE="$ROOT/$1"
  MACHINE=home
  shift
  mkdir -p "$CASE/home" "$CASE/tmp" "$CASE/bin" "$CASE/repo/nix"
  sandboxed git -C "$CASE/repo" init -q
  printf '%s\n' "# runtime secrets" "$@" >"$CASE/repo/nix/secret-names.txt"
  printf 'test-password-1\ntest-password-1\n' |
    sandboxed keepassxc-cli db-create -q -p "$CASE/t.kdbx" >/dev/null 2>&1
  printf '\n== %s\n' "$(basename "$CASE")"
}

machine_home() { echo "$CASE/$MACHINE"; }
secrets_dir() { echo "$(machine_home)/.config/nix-secrets"; }
key_file() { echo "$(machine_home)/.config/sops/age/keys.txt"; }
backup_dir() { echo "$(machine_home)/.local/state/nix-secrets/backups"; }

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

ESC="$(printf '\033')"

# run_setup <answers> [options...]: runs the script on the case's vault with
# the answers on stdin, and sets STATUS and OUT. NO_DB=1 leaves the vault
# path out, so the remembered one is used.
run_setup() {
  local answers="$1" db=("$CASE/t.kdbx")
  shift
  [[ -n "${NO_DB:-}" ]] && db=()
  set +e
  printf '%b' "$answers" | sandboxed "$SETUP" "$@" ${db[@]+"${db[@]}"} >"$CASE/out.raw" 2>&1
  STATUS=$?
  set -e
  sed "s/$ESC\\[[0-9;]*m//g" "$CASE/out.raw" >"$CASE/out.txt"
  OUT="$CASE/out.txt"
}

# kp_cli <command> [args...]: keepassxc-cli on the case's vault.
kp_cli() {
  local command="$1"
  shift
  printf 'test-password-1\n' | sandboxed keepassxc-cli "$command" -q "$CASE/t.kdbx" "$@"
}
kp_value() { kp_cli show -a Password "$1" 2>/dev/null || true; }
kp_exists() { kp_cli show "$1" >/dev/null 2>&1; }

# decrypt <name in the secrets dir, or a path> [age key file]
decrypt() {
  local file="$1"
  [[ "$file" == /* ]] || file="$(secrets_dir)/$file"
  sandboxed env SOPS_AGE_KEY_FILE="${2:-$(key_file)}" \
    sops decrypt --output-type json "$file" 2>/dev/null || true
}

# count_backups [pattern]
count_backups() { find "$(backup_dir)" -name "${1:-*.kdbx}" 2>/dev/null | wc -l | tr -d ' ' || true; }

# --- assertions -------------------------------------------------------------------

PASSED=0
FAILED=0

pass() {
  PASSED=$((PASSED + 1))
  printf '  \033[32m✓\033[0m %s\n' "$1"
}
failed() {
  FAILED=$((FAILED + 1))
  printf '  \033[31m✗\033[0m %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '      %s\n' "$2"; fi
}

# expect <description> <condition>: the condition is evaluated as a command.
expect() {
  if eval "$2"; then pass "$1"; else failed "$1" "${3:-}"; fi
}
expect_status() {
  local want="$1"
  expect "exit status $want" '[[ "$STATUS" == "$want" ]]' "got $STATUS; see $OUT"
}
expect_output() {
  local text="$1"
  expect "output mentions: $text" 'grep -qF -- "$text" "$OUT"' "see $OUT"
}
expect_no_output() {
  local text="$1"
  expect "output does not mention: $text" '! grep -qF -- "$text" "$OUT"' "see $OUT"
}
# describe_value <got>: what a value looks like, without showing it.
describe_value() { if [[ -z "$1" ]]; then echo "got nothing"; else echo "got a different value"; fi; }
# expect_kp <entry> <value> [what the value is]
expect_kp() {
  local want="$2" got
  got="$(kp_value "$1")"
  expect "$1 holds ${3:-the expected value}" '[[ "$got" == "$want" ]]' "$(describe_value "$got")"
}
# expect_json <file> <jq filter> <value> [what the value is]
expect_json() {
  local want="$3" got
  got="$(decrypt "$1" | jq -r "$2")"
  expect "$1 $2 is ${4:-the expected value}" '[[ "$got" == "$want" ]]' "$(describe_value "$got")"
}
expect_mode() {
  local want="$2" got
  got="$(file_meta "$1")"
  got="${got##* }"
  expect "$(basename "$1") has mode $want" '[[ "$got" == "$want" ]]' "got $got"
}
expect_missing() {
  local path="$1"
  expect "$2" '[[ ! -e "$path" ]]' "$path exists"
}

# --- setting secrets --------------------------------------------------------------

new_case auto-manual-skip github-token openai-key
# A wrong password, then "automatically" for everything. github-token has no
# automatic value: typed in (first with a mismatched confirmation), and
# openai-key is skipped.
run_setup 'wrong-test-password\ntest-password-1\na\nm\ntest-mismatch-1\ntest-mismatch-2\nm\ntest-token-1\ntest-token-1\ns\n'
expect_status 0
expect_output "Could not unlock the database, try again."
expect_kp nix-config/age-key-label primary "the default label"
expect_kp nix-config/username "$(sandboxed id -un)" "the login name"
expect_output "The two entries differ."
expect_kp nix-config/secrets/github-token test-token-1 "the typed value"
expect_kp nix-config/secrets/openai-key "" "nothing (skipped)"
expect_output "Skipped for now"
expect_output "Next: "
expect_json secrets.yaml '."github-token"' test-token-1 "the typed value"
expect_json secrets.yaml 'has("openai-key")' false
expect_json host.yaml .username "$(sandboxed id -un)" "the login name"
expect_mode "$(secrets_dir)" 700
expect_mode "$(secrets_dir)/secrets.yaml" 600
expect_mode "$(key_file)" 600
expect "secrets.yaml is encrypted" '! grep -q test-token-1 "$(secrets_dir)/secrets.yaml"'

# The skipped secret, from a .env file on the next run.
printf 'SECRET_OPENAI_KEY="test-openai-key-1"\n' >"$CASE/my.env"
run_setup "test-password-1\ng\ne\n$CASE/my.env\n"
expect_status 0
expect_kp nix-config/secrets/openai-key test-openai-key-1 "the value from .env"
expect_json secrets.yaml '."openai-key"' test-openai-key-1 "the value from .env"
expect_output "host.yaml is up to date"
expect_output "All secrets are defined."
expect_output "consider deleting that file"

# Nothing missing: no questions, no changes, and the vault path is remembered.
NO_DB=1 run_setup 'test-password-1\n'
expect_status 0
expect_output "Checking KeePassXC secrets in $CASE/t.kdbx"
expect_output "secrets.yaml is up to date"
expect_no_output "How do you want to set them?"

new_case env-file github-token
sandboxed age-keygen -o "$CASE/key.txt" 2>/dev/null
CANARY="$CASE/env-injection-canary"
{
  echo "# comment"
  echo "export NIX_SECRETS_AGE_KEY=$(grep AGE-SECRET-KEY "$CASE/key.txt")"
  echo "NIX_SECRETS_AGE_KEY_LABEL='mylabel'"
  echo "NIX_SECRETS_USERNAME=alice"
  echo 'NIX_SECRETS_HOSTNAME="mini-1"'
  # Must be stored literally: if it were ever run, the canary would appear.
  printf 'SECRET_GITHUB_TOKEN=test-token-$(touch %s)`touch %s`-1\n' "$CANARY" "$CANARY"
} >"$CASE/all.env"
run_setup 'test-password-1\n' --env "$CASE/all.env"
expect_status 0
expect_kp nix-config/age-key-label mylabel "the label from .env"
expect_kp nix-config/username alice "the username from .env"
expect_kp nix-config/hostname mini-1 "the hostname from .env"
expect_kp nix-config/secrets/github-token "test-token-\$(touch $CANARY)\`touch $CANARY\`-1" "the literal \$(...) text"
expect_missing "$CANARY" ".env values are never executed"
expect ".sops.yaml uses the label and key from .env" \
  'grep -q "&mylabel $(sandboxed age-keygen -y "$CASE/key.txt")" "$(secrets_dir)/.sops.yaml"'
expect_json host.yaml .hostname mini-1 "the hostname from .env"

new_case skip-one-then-all github-token
# Guided: the age key automatically, skip the label, then skip all the rest.
run_setup 'test-password-1\ng\na\ns\nS\n'
expect_status 0
expect_output "nix-config/age-key stored and verified"
expect_kp nix-config/age-key-label "" "nothing (skipped)"
expect_kp nix-config/username "" "nothing (skipped)"
expect_output "nix-config/secrets/github-token"
expect_output "username/hostname not both defined; skipping host.yaml"

new_case invalid-label
run_setup 'test-password-1\ng\na\nm\nmy label\nm\nok-label\ny\nS\n'
expect_status 0
expect_output "The label may only contain letters, digits, - and _."
expect_kp nix-config/age-key-label ok-label "the valid label"

new_case skip-missing
run_setup 'test-password-1\n' --skip-missing
expect_status 0
expect_output "No age key in KeePassXC; skipping all local files."
expect_missing "$(secrets_dir)" "no local files without an age key"

# --- guardrails -------------------------------------------------------------------

new_case tracked-env-refused
echo 'NIX_SECRETS_USERNAME=x' >"$CASE/repo/.env"
sandboxed git -C "$CASE/repo" add -f .env
run_setup 'test-password-1\n' --env "$CASE/repo/.env"
expect_status 1
expect_output "is tracked by git; refusing to read secrets from it."
expect_kp nix-config/username "" "nothing (not stored)"

new_case local-key-mismatch
# The .env holds a different age key than this machine's; the local key wins.
mkdir -p "$(dirname "$(key_file)")"
sandboxed age-keygen -o "$(key_file)" 2>/dev/null
cp "$(key_file)" "$CASE/local-key.before"
sandboxed age-keygen -o "$CASE/other.txt" 2>/dev/null
printf 'NIX_SECRETS_AGE_KEY=%s\n' "$(grep AGE-SECRET-KEY "$CASE/other.txt")" >"$CASE/k.env"
run_setup 'test-password-1\n' --env "$CASE/k.env"
expect_status 1
expect_output "holds a different key than KeePassXC; not touching it."
expect "the local key is unchanged" 'cmp -s "$CASE/local-key.before" "$(key_file)"'

new_case keeps-other-fields
# An entry with its value in UserName and an empty Password counts as
# missing; filling in the Password keeps the UserName.
kp_cli mkdir nix-config >/dev/null
kp_cli add -u old-style nix-config/username >/dev/null
run_setup 'test-password-1\n' --auto
expect_status 0
expect_kp nix-config/username "$(sandboxed id -un)" "the login name"
expect "the UserName field is kept" '[[ "$(kp_cli show -a UserName nix-config/username)" == old-style ]]'
cp "$CASE/t.kdbx" "$CASE/t.before"
backups_before="$(count_backups)"
run_setup 'test-password-1\n' --auto
expect_status 0
expect "a run with nothing to set leaves the vault alone" 'cmp -s "$CASE/t.kdbx" "$CASE/t.before"'
expect "and makes no backup" '[[ "$(count_backups)" == "$backups_before" ]]'

new_case read-error-stops
run_setup 'test-password-1\n' --auto
cp "$CASE/t.kdbx" "$CASE/t.before"
# A keepassxc-cli that fails to read one entry for a reason other than
# "not found".
cat >"$CASE/bin/keepassxc-cli" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == show && " \$* " == *" nix-config/username "* ]]; then
  cat >/dev/null
  echo "Error while reading the database: simulated failure" >&2
  exit 1
fi
exec "$(command -v keepassxc-cli)" "\$@"
EOF
chmod +x "$CASE/bin/keepassxc-cli"
run_setup 'test-password-1\n' --auto
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
run_setup 'test-password-1\n' --auto
expect_status 1
expect_output "has a keys.txt attachment that isn't an age key; not touching it"
expect_output "Resolve these in KeePassXC by hand"
expect "the attachment is unchanged" \
  'kp_cli attachment-export --stdout nix-config/age-key keys.txt | cmp -s - "$CASE/other-attachment"'

new_case local-file-guard github-token
printf 'SECRET_GITHUB_TOKEN=test-token-one\n' >"$CASE/one.env"
run_setup 'test-password-1\n' --auto
run_setup 'test-password-1\n' --env "$CASE/one.env"
expect_json secrets.yaml '."github-token"' test-token-one "the first value"
# The value changes behind the script's back.
printf 'test-password-1\ntest-token-two\n' |
  sandboxed keepassxc-cli edit -q -p "$CASE/t.kdbx" nix-config/secrets/github-token || true
run_setup 'test-password-1\n' --skip-missing
expect_status 1
expect_output "differs from KeePassXC for:"
expect_output "github-token (changed)"
expect_output "Not replacing"
expect_json secrets.yaml '."github-token"' test-token-one "still the first value"
run_setup 'test-password-1\nn\n'
expect_status 0
expect_output "Kept $(secrets_dir)/secrets.yaml unchanged."
expect_json secrets.yaml '."github-token"' test-token-one "still the first value"
run_setup 'test-password-1\ny\n'
expect_status 0
expect_json secrets.yaml '."github-token"' test-token-two "the second value"
expect_json secrets.prev.yaml '."github-token"' test-token-one "the first value"
expect_mode "$(secrets_dir)/secrets.prev.yaml" 600
# Dropping a name from nix/secret-names.txt would remove its value: refused too.
printf '# runtime secrets\n' >"$CASE/repo/nix/secret-names.txt"
run_setup 'test-password-1\n' --skip-missing
expect_status 1
expect_output "github-token (removed)"

new_case vault-backups
mkdir -p "$(backup_dir)"
for i in 1 2 3 4 5 6; do
  echo "old $i" >"$(backup_dir)/t.2000010$i-000000-1.kdbx"
done
cp "$CASE/t.kdbx" "$CASE/t.before"
run_setup 'test-password-1\n' --auto
expect_status 0
expect_output "Backed up the vault to"
expect "five backups are kept" '[[ "$(count_backups "t.*.kdbx")" == 5 ]]'
expect "the oldest are pruned" \
  '[[ ! -e "$(backup_dir)/t.20000101-000000-1.kdbx" && ! -e "$(backup_dir)/t.20000102-000000-1.kdbx" ]]'
newest="$(find "$(backup_dir)" -name 't.*.kdbx' 2>/dev/null | sort | tail -n 1 || true)"
expect "the newest backup is the vault from before this run" 'cmp -s "$newest" "$CASE/t.before"'
expect_mode "$newest" 600
expect_mode "$(backup_dir)" 700

new_case app-running-warning github-token
printf '#!/usr/bin/env bash\nexit 0\n' >"$CASE/bin/pgrep" # "KeePassXC is running"
chmod +x "$CASE/bin/pgrep"
cp "$CASE/t.kdbx" "$CASE/t.before"
run_setup 'test-password-1\na\nn\n'
expect_status 1
expect_output "The KeePassXC app is running."
expect_output "Stopped before changing anything."
expect "the vault is unchanged" 'cmp -s "$CASE/t.kdbx" "$CASE/t.before"'
run_setup 'test-password-1\n' --auto
expect_status 0
expect_output "The KeePassXC app is running."
expect_kp nix-config/age-key-label primary "the default label (non-interactive runs warn and continue)"

# --- rotation ---------------------------------------------------------------------

new_case rotate-runtime-secret github-token
printf 'SECRET_GITHUB_TOKEN=test-token-one\n' >"$CASE/one.env"
printf 'SECRET_GITHUB_TOKEN=test-token-two\n' >"$CASE/two.env"
run_setup 'test-password-1\n' --auto
run_setup 'test-password-1\n' --env "$CASE/one.env"
run_setup 'test-password-1\nc\n' --rotate github-token
expect_status 0
expect_output "Rotation cancelled; nothing changed."
expect_kp nix-config/secrets/github-token test-token-one "still the first value"
run_setup 'test-password-1\n' --rotate github-token --env "$CASE/two.env"
expect_status 0
expect_output "The old value stays in the entry's history"
expect_kp nix-config/secrets/github-token test-token-two "the second value"
expect "the old value is in the entry's history" 'kp_cli export -f xml | grep -q ">test-token-one</Value>"'
expect_json secrets.yaml '."github-token"' test-token-two "the second value"
expect_json secrets.prev.yaml '."github-token"' test-token-one "the first value"
run_setup 'test-password-1\n' --rotate not-a-secret
expect_status 1
expect_output "Unknown secret 'not-a-secret'"

new_case rotate-undefined github-token
run_setup 'test-password-1\n' --rotate github-token --auto
expect_status 1
expect_output "is not defined yet; run without --rotate to set it."

new_case rotate-username
run_setup 'test-password-1\n' --auto
printf 'NIX_SECRETS_USERNAME=new-user\n' >"$CASE/user.env"
run_setup 'test-password-1\n' --rotate username --env "$CASE/user.env"
expect_status 0
expect_output "Current value: $(sandboxed id -un)"
expect_kp nix-config/username new-user "the new username"
expect_json host.yaml .username new-user "the new username"

new_case rotate-age-key github-token
printf 'SECRET_GITHUB_TOKEN=test-token-1\n' >"$CASE/tok.env"
run_setup 'test-password-1\n' --auto
run_setup 'test-password-1\n' --env "$CASE/tok.env"
old_public="$(sandboxed age-keygen -y "$(key_file)" 2>/dev/null || true)"
# Machine b was set up before the rotation; machine c has an unrelated key.
MACHINE=b
run_setup 'test-password-1\n' --skip-missing
expect_status 0
MACHINE=c
mkdir -p "$(dirname "$(key_file)")"
sandboxed age-keygen -o "$(key_file)" 2>/dev/null
cp "$(key_file)" "$CASE/c-key.before"
MACHINE=home

run_setup 'test-password-1\n' --rotate age-key --auto
expect_status 0
expect_output "Kept the current key in nix-config/age-key-previous"
expect_output "The age key was rotated; kept the old one at"
new_public="$(sandboxed age-keygen -y "$(key_file)" 2>/dev/null || true)"
expect "a new key is installed" '[[ -n "$new_public" && "$new_public" != "$old_public" ]]'
expect "KeePassXC holds the new key" \
  '[[ "$(kp_cli attachment-export --stdout nix-config/age-key keys.txt | sandboxed age-keygen -y)" == "$new_public" ]]'
expect "age-key-previous holds the old key" \
  '[[ "$(kp_cli attachment-export --stdout nix-config/age-key-previous keys.txt | sandboxed age-keygen -y)" == "$old_public" ]]'
rotated=("$(key_file)".rotated-*)
expect "the old local key is kept" '[[ "$(sandboxed age-keygen -y "${rotated[0]}")" == "$old_public" ]]'
expect_mode "${rotated[0]}" 600
expect_json secrets.yaml '."github-token"' test-token-1 "the value from .env"
expect_json host.yaml .username "$(sandboxed id -un)" "the login name"

MACHINE=b
run_setup 'test-password-1\n' --skip-missing
expect_status 0
expect_output "The age key was rotated; kept the old one at"
expect "machine b now has the new key" '[[ "$(sandboxed age-keygen -y "$(key_file)")" == "$new_public" ]]'
expect_json secrets.yaml '."github-token"' test-token-1 "the value from .env"

MACHINE=c
run_setup 'test-password-1\n' --skip-missing
expect_status 1
expect_output "holds a different key than KeePassXC; not touching it."
expect "machine c's unrelated key is untouched" 'cmp -s "$(key_file)" "$CASE/c-key.before"'
MACHINE=home

run_setup 'test-password-1\n' --rotate age-key --auto
expect_status 1
expect_output "still holds the key from an earlier rotation"

run_setup 'test-password-1\nn\n' --finish-age-key-rotation
expect_status 0
expect "age-key-previous is kept when declined" 'kp_exists nix-config/age-key-previous'
run_setup 'test-password-1\ny\n' --finish-age-key-rotation
expect_status 0
expect_output "Moved nix-config/age-key-previous to the recycle bin"
expect_output "Old local key kept at"
expect "age-key-previous is gone" '! kp_exists nix-config/age-key-previous'
expect "it is in the recycle bin" 'kp_cli ls -R -f | grep -q "^Recycle Bin/age-key-previous$"'

# --- the real environment ---------------------------------------------------------

printf '\n== real environment\n'
snapshot "${REAL_SECRETS_DIRS[@]}" >"$ROOT/real-home.after"
expect "nothing changed under ${REAL_SECRETS_DIRS[*]}" \
  'cmp -s "$ROOT/real-home.before" "$ROOT/real-home.after"' \
  "compare $ROOT/real-home.before and .after"
if [[ -n "$WORKTREE" ]]; then
  snapshot "$WORKTREE" >"$ROOT/worktree.after"
  expect "nothing changed in the working tree $WORKTREE" \
    'cmp -s "$ROOT/worktree.before" "$ROOT/worktree.after"' \
    "compare $ROOT/worktree.before and .after"
else
  echo "  (not run from a git working tree; nothing to compare)"
fi

# --- result -----------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
echo "Test files kept in $ROOT"
[[ "$FAILED" -eq 0 ]]
