#!/usr/bin/env bash
set -euo pipefail

# KeePassXC is the only source of truth for this repo's secrets. This script
# checks that every secret is defined there and helps define the missing
# ones: automatically, from a .env file, guided one at a time, or skipped for
# now. Each value is read back from KeePassXC to confirm it was stored.
#
# It then derives local files, outside the repo and never committed:
#
#   ~/.config/sops/age/keys.txt         age identity
#   ~/.config/nix-secrets/.sops.yaml    sops recipients
#   ~/.config/nix-secrets/host.yaml     username/hostname, read by darwin-switch
#   ~/.config/nix-secrets/secrets.yaml  runtime secrets, read by sops-nix
#
# Guardrails: a defined value is only ever replaced through --rotate; a value
# that can't be read stops the script instead of looking "missing"; the vault
# is backed up before the first write of a run; local files that would lose
# or change values are only replaced after confirmation.
#
# See docs/secrets.md.

usage() {
  cat >&2 <<EOF
Usage: $0 [options] [path-to-database.kdbx]

Options:
  --auto          Set missing secrets automatically where a value can be
                  derived; skip the rest.
  --env FILE      Set missing secrets from a .env file; skip the rest.
  --skip-missing  Only report missing secrets, then sync what is defined.
  --rotate NAME   Replace a defined secret: age-key, age-key-label, username,
                  hostname, or a name from nix/secret-names.txt. Combine with
                  --auto or --env to choose the new value without prompts.
  --finish-age-key-rotation
                  Once every machine has the new age key, move the previous
                  one to KeePassXC's recycle bin.
  -h, --help      Show this help.

--auto, --env and --skip-missing never prompt: secrets they can't set are
skipped, and anything that would need a confirmation is refused. Without
them, the script asks how to set missing secrets.

The database can also be given as \$KEEPASSXC_DATABASE. Optional:
\$KEEPASSXC_KEYFILE, \$NIX_SECRETS_GROUP (default: nix-config),
\$NIX_SECRETS_DIR (default: ~/.config/nix-secrets),
\$NIX_SECRETS_BACKUP_DIR (default: ~/.local/state/nix-secrets/backups).

.env keys: NIX_SECRETS_AGE_KEY (an AGE-SECRET-KEY-... line),
NIX_SECRETS_AGE_KEY_LABEL, NIX_SECRETS_USERNAME, NIX_SECRETS_HOSTNAME, and
SECRET_<NAME> for each name in nix/secret-names.txt (upper case, - as _).
EOF
}

MODE=""
ENV_FILE=""
NONINTERACTIVE=""
ROTATE=""
FINISH_ROTATION=""
DB_PATH="${KEEPASSXC_DATABASE:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) MODE="auto" NONINTERACTIVE=1 ;;
    --env)
      MODE="env" NONINTERACTIVE=1
      ENV_FILE="${2:?--env needs a file}"
      shift
      ;;
    --skip-missing) MODE="skip" NONINTERACTIVE=1 ;;
    --rotate)
      ROTATE="${2:?--rotate needs a name}"
      shift
      ;;
    --finish-age-key-rotation) FINISH_ROTATION=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage
      exit 1
      ;;
    *) DB_PATH="$1" ;;
  esac
  shift
done

if [[ -z "$DB_PATH" ]]; then
  read -rp "Path to KeePassXC database (.kdbx): " DB_PATH
fi
DB_PATH="${DB_PATH/#\~/$HOME}"
if [[ ! -f "$DB_PATH" ]]; then
  echo "Error: database not found: $DB_PATH" >&2
  exit 1
fi

GROUP="${NIX_SECRETS_GROUP:-nix-config}"
RUNTIME_GROUP="$GROUP/secrets"
AGE_ATTACHMENT="keys.txt"
PREVIOUS_AGE_ENTRY="$GROUP/age-key-previous"

REPO="${NIX_CONFIG_DIR:-$(git rev-parse --show-toplevel)}"
SECRET_NAMES_FILE="$REPO/nix/secret-names.txt"

# Must match home/modules/secrets.nix.
SECRETS_DIR="${NIX_SECRETS_DIR:-$HOME/.config/nix-secrets}"
AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
SOPS_CONFIG="$SECRETS_DIR/.sops.yaml"
BACKUP_DIR="${NIX_SECRETS_BACKUP_DIR:-$HOME/.local/state/nix-secrets/backups}"
BACKUPS_KEPT=5
# sops' default on macOS is ~/Library/Application Support; pin it to the
# file sops-nix reads.
export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

KEYFILE_ARGS=()
if [[ -n "${KEEPASSXC_KEYFILE:-}" ]]; then
  KEYFILE_ARGS=(-k "$KEEPASSXC_KEYFILE")
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
note() { printf '  \033[33m-\033[0m %s\n' "$*"; }

timestamp() { date +%Y%m%d-%H%M%S; }

# Every keepassxc-cli call gets the master password on stdin, so it is only
# asked for once.
kp() {
  local cmd="$1"
  shift
  printf '%s\n' "$KP_PASSWORD" | keepassxc-cli "$cmd" -q "${KEYFILE_ARGS[@]}" "$DB_PATH" "$@"
}

# kp_read <outfile> <command> [args...]
# Returns 0 when found and 3 when the entry or attachment doesn't exist. Any
# other failure stops the script: an unreadable value must never be mistaken
# for a missing one and then overwritten.
kp_read() {
  local outfile="$1"
  shift
  if kp "$@" >"$outfile" 2>"$TMP_DIR/kp.err"; then
    return 0
  fi
  if grep -qE '^Could not find (entry with path|attachment with name) ' "$TMP_DIR/kp.err"; then
    return 3
  fi
  fail "Could not read from KeePassXC ($1 ${*: -1}): $(head -n 1 "$TMP_DIR/kp.err")"
  fail "Stopping without changing anything."
  exit 1
}

entry_exists() {
  local rc=0
  kp_read "$TMP_DIR/entry" show "$1" || rc=$?
  [[ $rc -eq 0 ]]
}

confirm() {
  local answer
  read -rp "$1 [y/N] " answer
  [[ "$answer" == [yY]* ]]
}

unlock() {
  while true; do
    read -rsp "KeePassXC master password for $(basename "$DB_PATH"): " KP_PASSWORD
    echo
    if kp ls >/dev/null 2>&1; then
      ok "Database unlocked"
      return
    fi
    fail "Could not unlock the database, try again."
  done
}

ensure_group() {
  if ! kp ls "$1" >/dev/null 2>&1; then
    kp mkdir "$1" >/dev/null
  fi
}

# --- before the first write ----------------------------------------------------

WRITE_PREPARED=""

backup_vault() {
  local base dest backups
  base="$(basename "$DB_PATH" .kdbx)"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  dest="$BACKUP_DIR/$base.$(timestamp)-$$.kdbx"
  (umask 077 && cp "$DB_PATH" "$dest")
  if ! cmp -s "$DB_PATH" "$dest"; then
    fail "Could not back up the vault to $dest; stopping before any change."
    exit 1
  fi
  ok "Backed up the vault to $dest"

  # Timestamps sort chronologically; keep only the newest few.
  backups=("$BACKUP_DIR/$base".????????-??????-*.kdbx)
  if [[ ${#backups[@]} -gt $BACKUPS_KEPT ]]; then
    rm -f -- "${backups[@]:0:${#backups[@]}-BACKUPS_KEPT}"
  fi
}

# Runs once, right before the first change to the vault.
prepare_write() {
  [[ -n "$WRITE_PREPARED" ]] && return
  WRITE_PREPARED=1
  if command -v pgrep >/dev/null 2>&1 && pgrep -xi keepassxc >/dev/null 2>&1; then
    note "The KeePassXC app is running. Save and lock the database there first:"
    note "unsaved changes in the app could overwrite what this script writes."
    if [[ -z "$NONINTERACTIVE" ]]; then
      confirm "  Continue?" || {
        fail "Stopped before changing anything."
        exit 1
      }
    fi
  fi
  backup_vault
}

# --- secrets -------------------------------------------------------------------
#
# Each secret has an id. Values live in the Password field of their entry;
# the age key is an attachment.

SECRETS=(age-key age-key-label username hostname)
RUNTIME_NAMES=()
if [[ -f "$SECRET_NAMES_FILE" ]]; then
  while read -r name; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    RUNTIME_NAMES+=("$name")
    SECRETS+=("runtime:$name")
  done <"$SECRET_NAMES_FILE"
fi

entry_of() {
  case "$1" in
    runtime:*) echo "$RUNTIME_GROUP/${1#runtime:}" ;;
    *) echo "$GROUP/$1" ;;
  esac
}

describe() {
  case "$1" in
    age-key) echo "age private key that encrypts the local sops files" ;;
    age-key-label) echo "name of the age key in .sops.yaml" ;;
    username) echo "macOS user nix-darwin and Home Manager manage" ;;
    hostname) echo "host name; also the darwinConfigurations attribute" ;;
    runtime:*) echo "runtime secret for sops-nix" ;;
  esac
}

env_key_of() {
  local name
  case "$1" in
    age-key) echo "NIX_SECRETS_AGE_KEY" ;;
    age-key-label) echo "NIX_SECRETS_AGE_KEY_LABEL" ;;
    username) echo "NIX_SECRETS_USERNAME" ;;
    hostname) echo "NIX_SECRETS_HOSTNAME" ;;
    runtime:*)
      name="${1#runtime:}"
      name="${name//-/_}"
      echo "SECRET_${name^^}"
      ;;
  esac
}

is_sensitive() { [[ "$1" == age-key || "$1" == runtime:* ]]; }

default_hostname() {
  if command -v scutil >/dev/null 2>&1; then
    scutil --get LocalHostName 2>/dev/null && return
  fi
  hostname -s 2>/dev/null || true
}

# Prints the value an id would get automatically; fails if there is none.
auto_value() {
  case "$1" in
    age-key-label) echo "primary" ;;
    username) id -un ;;
    hostname) default_hostname ;;
    *) return 1 ;;
  esac
}

validate() {
  if [[ -z "$2" ]]; then
    fail "The value is empty."
    return 1
  fi
  if [[ "$1" == age-key-label && ! "$2" =~ ^[A-Za-z0-9_-]+$ ]]; then
    fail "The label may only contain letters, digits, - and _."
    return 1
  fi
}

# read_value <id>: sets VALUE; succeeds when it is non-empty.
read_value() {
  local rc=0
  VALUE=""
  kp_read "$TMP_DIR/value" show -a Password "$(entry_of "$1")" || rc=$?
  [[ $rc -eq 0 ]] && VALUE="$(cat "$TMP_DIR/value")"
  [[ -n "$VALUE" ]]
}

# read_age_key [entry]: copies the attachment to $TMP_DIR/kp-age.txt and sets
# AGE_STATE to defined, missing, or conflict (an attachment that isn't an age
# identity).
read_age_key() {
  local entry="${1:-$(entry_of age-key)}" rc=0
  kp_read "$TMP_DIR/kp-age.txt" attachment-export --stdout "$entry" "$AGE_ATTACHMENT" || rc=$?
  if [[ $rc -ne 0 ]]; then
    AGE_STATE=missing
  elif age-keygen -y "$TMP_DIR/kp-age.txt" >/dev/null 2>&1; then
    AGE_STATE=defined
  else
    AGE_STATE=conflict
  fi
}

# state_of <id>: sets STATE to defined, missing or conflict.
state_of() {
  if [[ "$1" == age-key ]]; then
    read_age_key
    STATE="$AGE_STATE"
  elif read_value "$1"; then
    STATE=defined
  else
    STATE=missing
  fi
}

# The one id --rotate may overwrite in this run.
OVERWRITE_ID=""

# store_value <id> <value>; reads it back and reports whether it matches.
store_value() {
  local id="$1" value="$2" entry cmd=add
  entry="$(entry_of "$id")"
  validate "$id" "$value" || return 1

  state_of "$id"
  if [[ "$STATE" != missing && "$OVERWRITE_ID" != "$id" ]]; then
    fail "$entry already has a value; not overwriting it (use --rotate $id)."
    return 1
  fi
  if [[ "$STATE" == defined && "$VALUE" == "$value" ]]; then
    note "$entry already has this value; nothing to change."
    return 0
  fi

  prepare_write
  ensure_group "$GROUP"
  [[ "$id" == runtime:* ]] && ensure_group "$RUNTIME_GROUP"
  # edit -p only replaces the Password; other fields are kept, and
  # KeePassXC keeps the old value in the entry's history.
  entry_exists "$entry" && cmd=edit
  printf '%s\n%s\n' "$KP_PASSWORD" "$value" |
    keepassxc-cli "$cmd" -q -p "${KEYFILE_ARGS[@]}" "$DB_PATH" "$entry" >/dev/null

  if read_value "$id" && [[ "$VALUE" == "$value" ]]; then
    if is_sensitive "$id"; then
      ok "$entry stored and verified"
    else
      ok "$entry = $value, stored and verified"
    fi
    return 0
  fi
  fail "$entry did not read back the value that was stored."
  return 1
}

# store_age_key <file with an age identity>
store_age_key() {
  local source="$1" entry
  entry="$(entry_of age-key)"
  if ! age-keygen -y "$source" >/dev/null 2>&1; then
    fail "Not a valid age identity."
    return 1
  fi

  read_age_key
  if [[ "$AGE_STATE" != missing && "$OVERWRITE_ID" != age-key ]]; then
    fail "$entry already has a $AGE_ATTACHMENT attachment; not overwriting it."
    return 1
  fi
  if [[ "$AGE_STATE" == defined ]] && cmp -s "$TMP_DIR/kp-age.txt" "$source"; then
    note "$entry already holds this key; nothing to change."
    return 0
  fi

  prepare_write
  ensure_group "$GROUP"
  if [[ "$AGE_STATE" == missing ]]; then
    entry_exists "$entry" || kp add "$entry" >/dev/null
    kp attachment-import "$entry" "$AGE_ATTACHMENT" "$source" >/dev/null
  else
    keep_previous_age_key
    kp attachment-import -f "$entry" "$AGE_ATTACHMENT" "$source" >/dev/null
  fi

  read_age_key
  if [[ "$AGE_STATE" == defined ]] && cmp -s "$TMP_DIR/kp-age.txt" "$source"; then
    ok "$entry stored and verified (public key $(age-keygen -y "$source"))"
    return 0
  fi
  fail "The attachment read back from $entry does not match."
  return 1
}

# During rotation, other machines still have the old key; keep it in its own
# entry so they can recognise it (see install_age_key).
keep_previous_age_key() {
  cp "$TMP_DIR/kp-age.txt" "$TMP_DIR/previous.txt"
  kp add "$PREVIOUS_AGE_ENTRY" >/dev/null
  kp attachment-import "$PREVIOUS_AGE_ENTRY" "$AGE_ATTACHMENT" "$TMP_DIR/previous.txt" >/dev/null
  read_age_key "$PREVIOUS_AGE_ENTRY"
  if [[ "$AGE_STATE" != defined ]] || ! cmp -s "$TMP_DIR/kp-age.txt" "$TMP_DIR/previous.txt"; then
    fail "Could not keep the current key in $PREVIOUS_AGE_ENTRY; stopping."
    exit 1
  fi
  ok "Kept the current key in $PREVIOUS_AGE_ENTRY"
}

generate_age_key() {
  rm -f "$TMP_DIR/new-key.txt"
  (umask 077 && age-keygen -o "$TMP_DIR/new-key.txt" 2>/dev/null)
  echo "$TMP_DIR/new-key.txt"
}

# --- ways of setting a secret ---------------------------------------------------

set_auto() {
  local id="$1" value
  if [[ "$id" == age-key ]]; then
    # Reuse a key this machine already has, unless that is the key being
    # rotated away from.
    if [[ -f "$AGE_KEY_FILE" && "$OVERWRITE_ID" != age-key ]]; then
      store_age_key "$AGE_KEY_FILE"
    else
      store_age_key "$(generate_age_key)"
    fi
    return
  fi
  if ! value="$(auto_value "$id")" || [[ -z "$value" ]]; then
    note "No automatic value for $(entry_of "$id")."
    return 1
  fi
  store_value "$id" "$value"
}

declare -A ENV_VALUES=()
ENV_LOADED=""

load_env_file() {
  local file="$1" line key value
  file="${file/#\~/$HOME}"
  if [[ ! -f "$file" ]]; then
    fail "No such file: $file"
    return 1
  fi
  if git -C "$(dirname "$file")" ls-files --error-unmatch "$file" >/dev/null 2>&1; then
    fail "$file is tracked by git; refusing to read secrets from it."
    return 1
  fi
  # Parsed, never sourced: values are taken literally.
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#export }"
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    ENV_VALUES["$key"]="$value"
  done <"$file"
  ENV_LOADED="$file"
  ok "Loaded $file"
}

set_from_env() {
  local id="$1" key file
  key="$(env_key_of "$id")"
  if [[ -z "$ENV_LOADED" ]]; then
    read -rp "  Path to .env file: " file
    load_env_file "$file" || return 1
  fi
  if [[ -z "${ENV_VALUES[$key]:-}" ]]; then
    note "$key is not in $ENV_LOADED."
    return 1
  fi
  if [[ "$id" == age-key ]]; then
    (umask 077 && printf '%s\n' "${ENV_VALUES[$key]}" >"$TMP_DIR/env-key.txt")
    store_age_key "$TMP_DIR/env-key.txt"
  else
    store_value "$id" "${ENV_VALUES[$key]}"
  fi
}

set_manually() {
  local id="$1" value again choice path default
  if [[ "$id" == age-key ]]; then
    read -rp "  [g]enerate a new key or [i]mport a key file? " choice
    case "$choice" in
      g*) store_age_key "$(generate_age_key)" ;;
      i*)
        read -rp "  Path to age key file: " path
        store_age_key "${path/#\~/$HOME}"
        ;;
      *) return 1 ;;
    esac
    return
  fi

  if is_sensitive "$id"; then
    read -rsp "  Value (hidden): " value
    echo
    read -rsp "  Again to confirm: " again
    echo
    if [[ "$value" != "$again" ]]; then
      fail "The two entries differ."
      return 1
    fi
  else
    default="$(auto_value "$id" 2>/dev/null || true)"
    read -rp "  Value${default:+ [$default]}: " value
    value="${value:-$default}"
    validate "$id" "$value" || return 1
    confirm "  Store '$value' in $(entry_of "$id")?" || return 1
  fi
  store_value "$id" "$value"
}

auto_hint() {
  if [[ "$1" == age-key ]]; then
    if [[ -f "$AGE_KEY_FILE" && "$OVERWRITE_ID" != age-key ]]; then
      echo "reuse $AGE_KEY_FILE"
    else
      echo "generate a new key"
    fi
  else
    auto_value "$1" 2>/dev/null || true
  fi
}

SKIPPED=()
SKIP_REST=""
CONFLICTS=()

# Asks how to set one secret until it is stored or skipped.
guided() {
  local id="$1" auto choice
  auto="$(auto_hint "$id")"
  echo
  echo "Missing: $(entry_of "$id") ($(describe "$id"))"
  while true; do
    [[ -n "$auto" ]] && echo "  [a] automatically ($auto)"
    echo "  [e] from a .env file${ENV_LOADED:+ ($ENV_LOADED)}"
    echo "  [m] enter it now"
    echo "  [s] skip this one for now"
    echo "  [S] skip all remaining for now"
    read -rp "  Choice: " choice
    case "$choice" in
      a) [[ -n "$auto" ]] && set_auto "$id" && return ;;
      e) set_from_env "$id" && return ;;
      m) set_manually "$id" && return ;;
      s)
        SKIPPED+=("$id")
        return
        ;;
      S)
        SKIPPED+=("$id")
        SKIP_REST=1
        return
        ;;
    esac
    echo "  Not set; choose again."
  done
}

handle_missing() {
  local id="$1"
  if [[ -n "$SKIP_REST" || "$MODE" == skip ]]; then
    SKIPPED+=("$id")
    return
  fi
  echo
  case "$MODE" in
    auto)
      echo "Setting $(entry_of "$id") automatically"
      set_auto "$id" && return
      ;;
    env)
      echo "Setting $(entry_of "$id") from $ENV_LOADED"
      set_from_env "$id" && return
      ;;
  esac
  if [[ -n "$NONINTERACTIVE" ]]; then
    SKIPPED+=("$id")
    return
  fi
  guided "$id"
}

# --- rotation ----------------------------------------------------------------------

# Values in the local sops files that are expected to change in this run, as
# "file:key".
declare -A EXPECTED_CHANGES=()
AGE_KEY_REPLACED=""

rotate() {
  local id="" name entry choice
  case "$ROTATE" in
    age-key | age-key-label | username | hostname) id="$ROTATE" ;;
    *)
      for name in "${RUNTIME_NAMES[@]}"; do
        [[ "$name" == "$ROTATE" ]] && id="runtime:$name"
      done
      ;;
  esac
  if [[ -z "$id" ]]; then
    fail "Unknown secret '$ROTATE'. Choose age-key, age-key-label, username, hostname or a name from nix/secret-names.txt."
    exit 1
  fi
  entry="$(entry_of "$id")"

  state_of "$id"
  if [[ "$STATE" != defined ]]; then
    fail "$entry is not defined yet; run without --rotate to set it."
    exit 1
  fi
  if [[ "$id" == age-key ]] && entry_exists "$PREVIOUS_AGE_ENTRY"; then
    fail "$PREVIOUS_AGE_ENTRY still holds the key from an earlier rotation."
    fail "Finish that one first: update every machine, then run with --finish-age-key-rotation."
    exit 1
  fi

  echo
  echo "Rotating $entry ($(describe "$id"))"
  if ! is_sensitive "$id"; then
    note "Current value: $VALUE"
  fi
  note "The old value stays in the entry's history in KeePassXC."
  OVERWRITE_ID="$id"

  case "$MODE" in
    auto) set_auto "$id" || exit 1 ;;
    env) set_from_env "$id" || exit 1 ;;
    *)
      while true; do
        echo "  [a] automatically ($(auto_hint "$id"))"
        echo "  [e] from a .env file"
        echo "  [m] enter it now"
        echo "  [c] cancel"
        read -rp "  Choice: " choice
        case "$choice" in
          a) set_auto "$id" && break ;;
          e) set_from_env "$id" && break ;;
          m) set_manually "$id" && break ;;
          c)
            note "Rotation cancelled; nothing changed."
            exit 0
            ;;
        esac
        echo "  Not rotated; choose again."
      done
      ;;
  esac
  OVERWRITE_ID=""

  case "$id" in
    username | hostname) EXPECTED_CHANGES["host.yaml:$id"]=1 ;;
    runtime:*) EXPECTED_CHANGES["secrets.yaml:${id#runtime:}"]=1 ;;
  esac
}

finish_rotation() {
  local rotated
  if ! entry_exists "$PREVIOUS_AGE_ENTRY"; then
    note "No previous age key in KeePassXC; nothing to finish."
    return
  fi
  echo
  echo "Every machine should have run nix-secrets-setup with the new age key."
  if [[ -z "$NONINTERACTIVE" ]]; then
    confirm "Move $PREVIOUS_AGE_ENTRY to KeePassXC's recycle bin?" || {
      note "Kept $PREVIOUS_AGE_ENTRY."
      return
    }
  fi
  prepare_write
  kp rm "$PREVIOUS_AGE_ENTRY" >/dev/null
  if entry_exists "$PREVIOUS_AGE_ENTRY"; then
    fail "Could not remove $PREVIOUS_AGE_ENTRY."
    exit 1
  fi
  ok "Moved $PREVIOUS_AGE_ENTRY to the recycle bin"
  for rotated in "$AGE_KEY_FILE".rotated-*; do
    [[ -e "$rotated" ]] && note "Old local key kept at $rotated; delete it once you're sure."
  done
}

# --- local files ------------------------------------------------------------------

install_age_key() {
  local public_kp public_local
  read_age_key
  public_kp="$(age-keygen -y "$TMP_DIR/kp-age.txt")"

  if [[ -f "$AGE_KEY_FILE" ]]; then
    public_local="$(age-keygen -y "$AGE_KEY_FILE")"
    if [[ "$public_local" == "$public_kp" ]]; then
      ok "$AGE_KEY_FILE matches KeePassXC"
      return
    fi
    # Only a key that KeePassXC marks as the one being rotated away from is
    # replaced; any other key is left alone.
    read_age_key "$PREVIOUS_AGE_ENTRY"
    if [[ "$AGE_STATE" != defined || "$(age-keygen -y "$TMP_DIR/kp-age.txt")" != "$public_local" ]]; then
      fail "$AGE_KEY_FILE holds a different key than KeePassXC; not touching it."
      fail "Move it aside and rerun to install the key from KeePassXC."
      exit 1
    fi
    local rotated
    rotated="$AGE_KEY_FILE.rotated-$(timestamp)"
    mv "$AGE_KEY_FILE" "$rotated"
    chmod 600 "$rotated"
    note "The age key was rotated; kept the old one at $rotated"
    AGE_KEY_REPLACED=1
  fi

  read_age_key
  mkdir -p "$(dirname "$AGE_KEY_FILE")"
  chmod 700 "$(dirname "$AGE_KEY_FILE")"
  (umask 077 && cp "$TMP_DIR/kp-age.txt" "$AGE_KEY_FILE")
  chmod 600 "$AGE_KEY_FILE"
  ok "Installed $AGE_KEY_FILE"
}

write_sops_config() {
  local label="$1"
  cat >"$SOPS_CONFIG" <<EOF
# Generated by nix-secrets-setup from KeePassXC ($GROUP).
keys:
  - &$label $(age-keygen -y "$AGE_KEY_FILE")
creation_rules:
  - path_regex: \.ya?ml$
    key_groups:
      - age:
          - *$label
EOF
  ok "Wrote $SOPS_CONFIG"
}

# Lists keys whose value in the current file would be removed or changed by
# writing the wanted content, except those expected to change.
unexpected_changes() {
  local name="$1" current="$2" want="$3" key
  {
    jq -r --argjson w "$want" 'to_entries[] | . as $e | select(($w | has($e.key)) | not) | "\($e.key) (removed)"' <<<"$current"
    jq -r --argjson w "$want" 'to_entries[] | . as $e | select(($w | has($e.key)) and $w[$e.key] != $e.value) | "\($e.key) (changed)"' <<<"$current"
  } | while read -r key; do
    [[ -n "${EXPECTED_CHANGES["$name:${key% (*}"]:-}" ]] || echo "$key"
  done
}

# write_sops_file <name> <json>; rewrites the file only when it changed, and
# asks before dropping or changing values nobody asked to change.
write_sops_file() {
  local name="$1" file="$SECRETS_DIR/$1" want current unexpected
  want="$(jq -S . <<<"$2")"

  if [[ -f "$file" ]]; then
    if current="$(sops decrypt --output-type json "$file" 2>/dev/null)"; then
      current="$(jq -S . <<<"$current")"
      if [[ "$current" == "$want" ]]; then
        ok "$file is up to date"
        return
      fi
      unexpected="$(unexpected_changes "$name" "$current" "$want")"
      if [[ -n "$unexpected" ]]; then
        note "$file differs from KeePassXC for:"
        while read -r line; do note "  $line"; done <<<"$unexpected"
        if [[ -n "$NONINTERACTIVE" ]]; then
          fail "Not replacing $file without confirmation; rerun without --auto/--env/--skip-missing."
          exit 1
        fi
        confirm "  Replace $file with the values in KeePassXC?" || {
          note "Kept $file unchanged."
          return
        }
      fi
    elif [[ -z "$AGE_KEY_REPLACED" ]]; then
      fail "Can't decrypt $file with $AGE_KEY_FILE; not replacing it."
      fail "Move it aside if it is stale, then rerun."
      exit 1
    fi
    # Previous version, kept with a .yaml extension so sops can still read it.
    cp -p "$file" "${file%.yaml}.prev.yaml"
  fi

  (cd "$SECRETS_DIR" &&
    sops --config "$SOPS_CONFIG" encrypt --filename-override "$name" \
      --input-type json --output-type yaml <<<"$want" >"$TMP_DIR/$name")
  mv "$TMP_DIR/$name" "$file"
  chmod 600 "$file"
  current="$(sops decrypt --output-type json "$file" | jq -S .)"
  if [[ "$current" == "$want" ]]; then
    ok "Wrote $file and verified it decrypts${AGE_KEY_REPLACED:+ with the new key}"
  else
    fail "$file did not decrypt back to the KeePassXC values."
    exit 1
  fi
}

sync_local_files() {
  local json name username hostname label

  echo
  echo "Deriving local files in $SECRETS_DIR"
  read_age_key
  if [[ "$AGE_STATE" != defined ]]; then
    note "No age key in KeePassXC; skipping all local files."
    return
  fi
  mkdir -p "$SECRETS_DIR"
  if git -C "$SECRETS_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "$SECRETS_DIR is inside a git repository; refusing to write secrets there."
    exit 1
  fi
  chmod 700 "$SECRETS_DIR"
  install_age_key

  label=primary
  read_value age-key-label && label="$VALUE"
  write_sops_config "$label"

  username=""
  hostname=""
  read_value username && username="$VALUE"
  read_value hostname && hostname="$VALUE"
  if [[ -n "$username" && -n "$hostname" ]]; then
    json="$(jq -n --arg u "$username" --arg h "$hostname" '{username: $u, hostname: $h}')"
    write_sops_file host.yaml "$json"
  else
    note "username/hostname not both defined; skipping host.yaml"
  fi

  json="{}"
  for name in "${RUNTIME_NAMES[@]}"; do
    read_value "runtime:$name" || continue
    json="$(jq --arg k "$name" --arg v "$VALUE" '.[$k] = $v' <<<"$json")"
  done
  write_sops_file secrets.yaml "$json"
}

# --- main ---------------------------------------------------------------------------

echo "Checking KeePassXC secrets in $DB_PATH (group: $GROUP)"
unlock
if [[ "$MODE" == env ]]; then
  load_env_file "$ENV_FILE"
fi

if [[ -n "$FINISH_ROTATION" ]]; then
  finish_rotation
  exit 0
fi
if [[ -n "$ROTATE" ]]; then
  rotate
fi

MISSING=()
for id in "${SECRETS[@]}"; do
  state_of "$id"
  case "$STATE" in
    defined) ok "$(entry_of "$id")" ;;
    missing)
      fail "$(entry_of "$id") is missing"
      MISSING+=("$id")
      ;;
    conflict)
      fail "$(entry_of "$id") has a $AGE_ATTACHMENT attachment that isn't an age key; not touching it"
      CONFLICTS+=("$id")
      ;;
  esac
done

if [[ ${#MISSING[@]} -gt 0 && -z "$MODE" ]]; then
  echo
  echo "${#MISSING[@]} secret(s) missing. How do you want to set them?"
  echo "  [a] automatically where possible, asking for the rest"
  echo "  [e] from a .env file, asking for the rest"
  echo "  [g] guided, choosing for each secret"
  echo "  [s] skip all for now"
  while [[ -z "$MODE" ]]; do
    read -rp "Choice: " choice
    case "$choice" in
      a) MODE="auto" ;;
      e)
        read -rp "Path to .env file: " ENV_FILE
        load_env_file "$ENV_FILE" && MODE="env"
        ;;
      g) MODE="guided" ;;
      s) MODE="skip" ;;
    esac
  done
fi

for id in "${MISSING[@]}"; do
  handle_missing "$id"
done

sync_local_files

echo
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "Skipped for now (rerun nix-secrets-setup to set them):"
  for id in "${SKIPPED[@]}"; do
    note "$(entry_of "$id")"
  done
elif [[ ${#CONFLICTS[@]} -eq 0 ]]; then
  echo "All secrets are defined."
fi
if [[ -n "$ENV_LOADED" ]]; then
  echo "The values from $ENV_LOADED are now in KeePassXC; consider deleting that file."
fi
if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
  echo "Resolve these in KeePassXC by hand, then rerun:"
  for id in "${CONFLICTS[@]}"; do
    note "$(entry_of "$id")"
  done
  exit 1
fi
