#!/usr/bin/env bash
set -euo pipefail

# nix-secrets-setup
#
# KeePassXC is the only source of truth for this repo's secrets. This script
#
#   1. checks that every secret is defined in the vault,
#   2. helps define the missing ones (automatically, from a .env file, typed
#      in, or skipped for now) and reads each one back to confirm it,
#   3. derives the local files, outside the repo and never committed:
#
#        ~/.config/sops/age/keys.txt         age identity
#        ~/.config/nix-secrets/.sops.yaml    sops recipients
#        ~/.config/nix-secrets/host.yaml     username, hostname (darwin-switch)
#        ~/.config/nix-secrets/secrets.yaml  runtime secrets (sops-nix)
#
# It never replaces a defined value unless asked to with --rotate, stops on
# anything it can't read, and backs the vault up before changing it.
# See docs/secrets.md.

usage() {
  cat <<EOF
Usage: nix-secrets-setup [options] [vault.kdbx]

  --auto          set missing secrets automatically where possible
  --env FILE      set missing secrets from a .env file
  --skip-missing  only report missing secrets, then refresh the local files
  --rotate NAME   replace a defined secret (age-key, age-key-label, username,
                  hostname, or a name from nix/secret-names.txt)
  --finish-age-key-rotation
                  retire the previous age key once every machine has the new one

Without --auto, --env or --skip-missing it asks how to set what's missing.
With them it never prompts: what it can't set is skipped, and anything that
would need a confirmation is refused.

The vault path is remembered after the first run. Environment:
KEEPASSXC_DATABASE, KEEPASSXC_KEYFILE, NIX_SECRETS_GROUP (nix-config),
NIX_SECRETS_DIR (~/.config/nix-secrets), NIX_SECRETS_BACKUP_DIR.

.env keys: NIX_SECRETS_AGE_KEY, NIX_SECRETS_AGE_KEY_LABEL, NIX_SECRETS_USERNAME,
NIX_SECRETS_HOSTNAME, and SECRET_<NAME> per runtime secret (upper case, - as _).
EOF
}

# --- options ------------------------------------------------------------------

MODE=""           # auto | env | guided | skip; empty means "ask"
NONINTERACTIVE="" # set by --auto, --env and --skip-missing
ENV_FILE=""
ROTATE=""
FINISH_ROTATION=""
DB_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) MODE="auto" NONINTERACTIVE=1 ;;
    --env) MODE="env" NONINTERACTIVE=1 ENV_FILE="${2:?--env needs a file}" && shift ;;
    --skip-missing) MODE="skip" NONINTERACTIVE=1 ;;
    --rotate) ROTATE="${2:?--rotate needs a name}" && shift ;;
    --finish-age-key-rotation) FINISH_ROTATION=1 ;;
    -h | --help) usage && exit 0 ;;
    -*) usage >&2 && exit 1 ;;
    *) DB_PATH="$1" ;;
  esac
  shift
done

# --- where things live --------------------------------------------------------

GROUP="${NIX_SECRETS_GROUP:-nix-config}"
PREVIOUS_AGE_ENTRY="$GROUP/age-key-previous"
ATTACHMENT="keys.txt"

REPO="${NIX_CONFIG_DIR:-$(git rev-parse --show-toplevel)}"
SECRETS_DIR="${NIX_SECRETS_DIR:-$HOME/.config/nix-secrets}" # see home/modules/secrets.nix
AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
SOPS_CONFIG="$SECRETS_DIR/.sops.yaml"
STATE_DIR="$HOME/.local/state/nix-secrets"
BACKUP_DIR="${NIX_SECRETS_BACKUP_DIR:-$STATE_DIR/backups}"
BACKUPS_KEPT=5

# sops defaults to ~/Library/Application Support on macOS; use sops-nix's key.
export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

DB_PATH="${DB_PATH:-${KEEPASSXC_DATABASE:-}}"
if [[ -z "$DB_PATH" && -f "$STATE_DIR/vault" ]]; then
  DB_PATH="$(cat "$STATE_DIR/vault")"
fi
if [[ -z "$DB_PATH" ]]; then
  read -rp "Path to KeePassXC database (.kdbx): " DB_PATH
fi
DB_PATH="${DB_PATH/#\~/$HOME}"
if [[ ! -f "$DB_PATH" ]]; then
  echo "Error: database not found: $DB_PATH" >&2
  exit 1
fi

KEYFILE_ARGS=()
[[ -n "${KEEPASSXC_KEYFILE:-}" ]] && KEYFILE_ARGS=(-k "$KEEPASSXC_KEYFILE")

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- the secrets --------------------------------------------------------------
#
# Values live in the Password field of their entry; the age key is the
# keys.txt attachment of its entry.

CATALOGUE="
age-key        NIX_SECRETS_AGE_KEY        age private key that encrypts the local sops files
age-key-label  NIX_SECRETS_AGE_KEY_LABEL  name of the age key in .sops.yaml
username       NIX_SECRETS_USERNAME       macOS user nix-darwin and Home Manager manage
hostname       NIX_SECRETS_HOSTNAME       host name; also the darwinConfigurations attribute
"

SECRETS=()
RUNTIME_NAMES=()
declare -A ENV_KEY=() ABOUT=()

add_secret() {
  SECRETS+=("$1")
  ENV_KEY[$1]="$2"
  ABOUT[$1]="$3"
}

while read -r id key about; do
  [[ -n "$id" ]] && add_secret "$id" "$key" "$about"
done <<<"$CATALOGUE"

if [[ -f "$REPO/nix/secret-names.txt" ]]; then
  while read -r name; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    RUNTIME_NAMES+=("$name")
    key="${name//-/_}"
    add_secret "runtime:$name" "SECRET_${key^^}" "runtime secret for sops-nix"
  done <"$REPO/nix/secret-names.txt"
fi

entry_of() {
  case "$1" in
    runtime:*) echo "$GROUP/secrets/${1#runtime:}" ;;
    *) echo "$GROUP/$1" ;;
  esac
}

is_sensitive() { [[ "$1" == age-key || "$1" == runtime:* ]]; }

# --- output -------------------------------------------------------------------

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
note() { printf '  \033[33m-\033[0m %s\n' "$*"; }

confirm() {
  local answer
  read -rp "$1 [y/N] " answer
  [[ "$answer" == [yY]* ]]
}

# menu <prompt> <key:label>...: prints the options and sets CHOICE to one of
# their keys.
menu() {
  local prompt="$1" option
  shift
  for option in "$@"; do
    printf '  [%s] %s\n' "${option%%:*}" "${option#*:}"
  done
  while true; do
    read -rp "$prompt" CHOICE
    for option in "$@"; do
      [[ "$CHOICE" == "${option%%:*}" ]] && return
    done
  done
}

# --- the vault ----------------------------------------------------------------

# Every keepassxc-cli call gets the master password on stdin, so it is asked
# for only once.
kp() {
  local command="$1"
  shift
  printf '%s\n' "$KP_PASSWORD" | keepassxc-cli "$command" -q "${KEYFILE_ARGS[@]}" "$DB_PATH" "$@"
}

# kp_get <command> [args...]: sets OUTPUT. Fails when the entry or attachment
# doesn't exist; any other error stops the script, so an unreadable value is
# never mistaken for a missing one and overwritten.
kp_get() {
  if OUTPUT="$(kp "$@" 2>"$TMP_DIR/kp.err")"; then
    return 0
  fi
  if grep -qE '^Could not find (entry with path|attachment with name) ' "$TMP_DIR/kp.err"; then
    return 1
  fi
  fail "Could not read from KeePassXC ($1 ${*: -1}): $(head -n 1 "$TMP_DIR/kp.err")"
  fail "Stopping without changing anything."
  exit 1
}

entry_exists() { kp_get show "$1"; }

unlock() {
  while true; do
    read -rsp "KeePassXC master password for $(basename "$DB_PATH"): " KP_PASSWORD
    echo
    if kp ls >/dev/null 2>&1; then
      ok "Database unlocked"
      mkdir -p "$STATE_DIR"
      printf '%s\n' "$DB_PATH" >"$STATE_DIR/vault" # remembered for next time
      return
    fi
    fail "Could not unlock the database, try again."
  done
}

# read_state <id>: sets STATE (defined, missing, or conflict: an attachment
# that isn't an age key) and CURRENT (the stored value).
read_state() {
  CURRENT=""
  if [[ "$1" == age-key ]]; then
    if ! kp_get attachment-export --stdout "$(entry_of age-key)" "$ATTACHMENT"; then
      STATE=missing
      return
    fi
    CURRENT="$OUTPUT"
    if is_age_identity "$CURRENT"; then STATE=defined; else STATE=conflict; fi
    return
  fi
  kp_get show -a Password "$(entry_of "$1")" && CURRENT="$OUTPUT"
  if [[ -n "$CURRENT" ]]; then STATE=defined; else STATE=missing; fi
}

is_age_identity() { age-keygen -y <(printf '%s\n' "$1") >/dev/null 2>&1; }
public_key() { age-keygen -y <(printf '%s\n' "$1"); }

# Runs once, right before the first change to the vault.
WRITE_PREPARED=""
before_first_write() {
  [[ -n "$WRITE_PREPARED" ]] && return
  WRITE_PREPARED=1

  if command -v pgrep >/dev/null && pgrep -xi keepassxc >/dev/null 2>&1; then
    note "The KeePassXC app is running. Save and lock the database there first:"
    note "unsaved changes in the app could overwrite what this script writes."
    if [[ -z "$NONINTERACTIVE" ]] && ! confirm "  Continue?"; then
      fail "Stopped before changing anything."
      exit 1
    fi
  fi
  backup_vault
}

backup_vault() {
  local base backup backups
  base="$(basename "$DB_PATH" .kdbx)"
  backup="$BACKUP_DIR/$base.$(date +%Y%m%d-%H%M%S)-$$.kdbx"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  (umask 077 && cp "$DB_PATH" "$backup")
  if ! cmp -s "$DB_PATH" "$backup"; then
    fail "Could not back up the vault to $backup; stopping before any change."
    exit 1
  fi
  ok "Backed up the vault to $backup"

  # Names sort by time; keep the newest few.
  backups=("$BACKUP_DIR/$base".????????-??????-*.kdbx)
  if [[ ${#backups[@]} -gt $BACKUPS_KEPT ]]; then
    rm -f -- "${backups[@]:0:${#backups[@]}-BACKUPS_KEPT}"
  fi
}

ensure_groups() {
  local path="" part parts
  IFS=/ read -ra parts <<<"${1%/*}"
  for part in "${parts[@]}"; do
    path="${path:+$path/}$part"
    kp ls "$path" >/dev/null 2>&1 || kp mkdir "$path" >/dev/null
  done
}

# --- storing a value ----------------------------------------------------------

ROTATING="" # the one id --rotate may overwrite

# store <id> <value>: writes the value to the vault and reads it back.
store() {
  local id="$1" value="$2" entry
  entry="$(entry_of "$id")"
  valid "$id" "$value" || return 1

  read_state "$id"
  if [[ "$STATE" != missing && "$ROTATING" != "$id" ]]; then
    if [[ "$id" == age-key ]]; then
      fail "$entry already has a $ATTACHMENT attachment; not overwriting it."
    else
      fail "$entry already has a value; not overwriting it (use --rotate $id)."
    fi
    return 1
  fi
  if [[ "$STATE" == defined && "$CURRENT" == "$value" ]]; then
    note "$entry already holds this value; nothing to change."
    return 0
  fi

  before_first_write
  ensure_groups "$entry"
  if [[ "$id" == age-key ]]; then
    write_age_key "$entry" "$value"
  else
    write_password "$entry" "$value"
  fi

  read_state "$id"
  if [[ "$CURRENT" != "$value" ]]; then
    fail "$entry did not read back the value that was stored."
    return 1
  fi
  if [[ "$id" == age-key ]]; then
    ok "$entry stored and verified (public key $(public_key "$value"))"
  elif is_sensitive "$id"; then
    ok "$entry stored and verified"
  else
    ok "$entry = $value, stored and verified"
  fi
}

# Only the Password changes: other fields are kept, and KeePassXC keeps the
# old value in the entry's history.
write_password() {
  local command=add
  entry_exists "$1" && command=edit
  printf '%s\n%s\n' "$KP_PASSWORD" "$2" |
    keepassxc-cli "$command" -q -p "${KEYFILE_ARGS[@]}" "$DB_PATH" "$1" >/dev/null
}

write_age_key() {
  local entry="$1" file="$TMP_DIR/age-key.txt"
  (umask 077 && printf '%s\n' "$2" >"$file")
  if [[ "$STATE" == missing ]]; then
    entry_exists "$entry" || kp add "$entry" >/dev/null
    kp attachment-import "$entry" "$ATTACHMENT" "$file" >/dev/null
  else
    keep_previous_age_key "$CURRENT"
    kp attachment-import -f "$entry" "$ATTACHMENT" "$file" >/dev/null
  fi
}

# During an age key rotation the other machines still have the old key; keep
# it so they can recognise it (see install_age_key).
keep_previous_age_key() {
  local file="$TMP_DIR/previous.txt"
  (umask 077 && printf '%s\n' "$1" >"$file")
  kp add "$PREVIOUS_AGE_ENTRY" >/dev/null
  kp attachment-import "$PREVIOUS_AGE_ENTRY" "$ATTACHMENT" "$file" >/dev/null
  if ! kp_get attachment-export --stdout "$PREVIOUS_AGE_ENTRY" "$ATTACHMENT" || [[ "$OUTPUT" != "$1" ]]; then
    fail "Could not keep the current key in $PREVIOUS_AGE_ENTRY; stopping."
    exit 1
  fi
  ok "Kept the current key in $PREVIOUS_AGE_ENTRY"
}

valid() {
  if [[ -z "$2" ]]; then
    fail "The value is empty."
  elif [[ "$1" == age-key-label && ! "$2" =~ ^[A-Za-z0-9_-]+$ ]]; then
    fail "The label may only contain letters, digits, - and _."
  elif [[ "$1" == age-key ]] && ! is_age_identity "$2"; then
    fail "Not a valid age identity."
  else
    return 0
  fi
  return 1
}

# --- where a new value comes from ---------------------------------------------
#
# Each value_from_* sets NEW for an id, or fails; set_with stores the result.

set_with() { "value_from_$2" "$1" && store "$1" "$NEW"; }

new_age_key() { age-keygen 2>/dev/null; }

# What "automatically" means for an id; empty when there's nothing.
auto_hint() {
  case "$1" in
    age-key)
      if [[ -f "$AGE_KEY_FILE" && "$ROTATING" != age-key ]]; then
        echo "reuse $AGE_KEY_FILE"
      else
        echo "generate a new key"
      fi
      ;;
    age-key-label) echo primary ;;
    username) id -un ;;
    hostname) scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || true ;;
  esac
}

value_from_auto() {
  case "$1" in
    age-key)
      # This machine's key, unless that is the key being rotated away from.
      if [[ -f "$AGE_KEY_FILE" && "$ROTATING" != age-key ]]; then
        NEW="$(cat "$AGE_KEY_FILE")"
      else
        NEW="$(new_age_key)"
      fi
      ;;
    runtime:*)
      note "No automatic value for $(entry_of "$1")."
      return 1
      ;;
    *) NEW="$(auto_hint "$1")" ;;
  esac
}

declare -A ENV_VALUES=()
ENV_LOADED=""

# Parsed, never sourced: values are taken literally.
load_env_file() {
  local file="${1/#\~/$HOME}" line key value
  if [[ ! -f "$file" ]]; then
    fail "No such file: $file"
    return 1
  fi
  if git -C "$(dirname "$file")" ls-files --error-unmatch "$file" >/dev/null 2>&1; then
    fail "$file is tracked by git; refusing to read secrets from it."
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "${line#export }" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    ENV_VALUES[$key]="$value"
  done <"$file"
  ENV_LOADED="$file"
  ok "Loaded $file"
}

ask_env_file() {
  local file
  read -rp "  Path to .env file: " file
  load_env_file "$file"
}

value_from_env() {
  local key="${ENV_KEY[$1]}"
  [[ -n "$ENV_LOADED" ]] || ask_env_file || return 1
  if [[ -z "${ENV_VALUES[$key]:-}" ]]; then
    note "$key is not in $ENV_LOADED."
    return 1
  fi
  NEW="${ENV_VALUES[$key]}"
}

value_from_typed() {
  local again file default
  if [[ "$1" == age-key ]]; then
    menu "  Choice: " "g:generate a new key" "i:import a key file"
    if [[ "$CHOICE" == g ]]; then
      NEW="$(new_age_key)"
      return
    fi
    read -rp "  Path to age key file: " file
    NEW="$(cat "${file/#\~/$HOME}" 2>/dev/null)" || {
      fail "Can't read $file."
      return 1
    }
  elif is_sensitive "$1"; then
    read -rsp "  Value (hidden): " NEW && echo
    read -rsp "  Again to confirm: " again && echo
    if [[ "$NEW" != "$again" ]]; then
      fail "The two entries differ."
      return 1
    fi
  else
    default="$(auto_hint "$1")"
    read -rp "  Value${default:+ [$default]}: " NEW
    NEW="${NEW:-$default}"
    valid "$1" "$NEW" && confirm "  Store '$NEW' in $(entry_of "$1")?"
  fi
}

# --- checking and filling in the vault ----------------------------------------

MISSING=()
SKIPPED=()
CONFLICTS=()
SKIP_REST=""

check_vault() {
  local id
  for id in "${SECRETS[@]}"; do
    read_state "$id"
    case "$STATE" in
      defined) ok "$(entry_of "$id")" ;;
      missing)
        fail "$(entry_of "$id") is missing"
        MISSING+=("$id")
        ;;
      conflict)
        fail "$(entry_of "$id") has a $ATTACHMENT attachment that isn't an age key; not touching it"
        CONFLICTS+=("$id")
        ;;
    esac
  done
}

fill_missing() {
  local id
  [[ ${#MISSING[@]} -gt 0 ]] || return 0
  [[ -n "$MODE" ]] || choose_mode
  for id in "${MISSING[@]}"; do
    fill "$id"
  done
}

choose_mode() {
  echo
  echo "${#MISSING[@]} secret(s) missing. How do you want to set them?"
  while [[ -z "$MODE" ]]; do
    menu "Choice: " \
      "a:automatically where possible, asking for the rest" \
      "e:from a .env file, asking for the rest" \
      "g:guided, choosing for each secret" \
      "s:skip all for now"
    case "$CHOICE" in
      a) MODE="auto" ;;
      e) ask_env_file && MODE="env" ;;
      g) MODE="guided" ;;
      s) MODE="skip" ;;
    esac
  done
}

fill() {
  local id="$1"
  if [[ "$MODE" == skip || -n "$SKIP_REST" ]]; then
    SKIPPED+=("$id")
    return
  fi
  echo
  case "$MODE" in
    auto) echo "Setting $(entry_of "$id") automatically" && set_with "$id" auto && return ;;
    env) echo "Setting $(entry_of "$id") from $ENV_LOADED" && set_with "$id" env && return ;;
  esac
  if [[ -n "$NONINTERACTIVE" ]]; then
    SKIPPED+=("$id")
  else
    ask_how "$id"
  fi
}

# Asks how to set one secret until it is stored or skipped.
ask_how() {
  local id="$1" hint options
  hint="$(auto_hint "$id")"
  echo "Missing: $(entry_of "$id") (${ABOUT[$id]})"
  while true; do
    options=()
    [[ -n "$hint" ]] && options+=("a:automatically ($hint)")
    options+=(
      "e:from a .env file${ENV_LOADED:+ ($ENV_LOADED)}"
      "m:enter it now"
      "s:skip this one for now"
      "S:skip all remaining for now"
    )
    menu "  Choice: " "${options[@]}"
    case "$CHOICE" in
      a) set_with "$id" auto && return ;;
      e) set_with "$id" env && return ;;
      m) set_with "$id" typed && return ;;
      s) SKIPPED+=("$id") && return ;;
      S) SKIPPED+=("$id") && SKIP_REST=1 && return ;;
    esac
    echo "  Not set; choose again."
  done
}

# --- rotation -----------------------------------------------------------------

declare -A EXPECTED_CHANGES=() # "file:key" of local values allowed to change

rotate() {
  local id="" candidate entry
  for candidate in "$1" "runtime:$1"; do
    if [[ -n "${ENV_KEY[$candidate]:-}" ]]; then
      id="$candidate"
      break
    fi
  done
  if [[ -z "$id" ]]; then
    fail "Unknown secret '$1'. Choose age-key, age-key-label, username, hostname or a name from nix/secret-names.txt."
    exit 1
  fi
  entry="$(entry_of "$id")"

  read_state "$id"
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
  echo "Rotating $entry (${ABOUT[$id]})"
  is_sensitive "$id" || note "Current value: $CURRENT"
  note "The old value stays in the entry's history in KeePassXC."
  ROTATING="$id"

  if [[ "$MODE" == auto || "$MODE" == env ]]; then
    set_with "$id" "$MODE" || exit 1
  else
    while true; do
      menu "  Choice: " "a:automatically ($(auto_hint "$id"))" "e:from a .env file" "m:enter it now" "c:cancel"
      case "$CHOICE" in
        a) set_with "$id" auto && break ;;
        e) set_with "$id" env && break ;;
        m) set_with "$id" typed && break ;;
        c) note "Rotation cancelled; nothing changed." && exit 0 ;;
      esac
      echo "  Not rotated; choose again."
    done
  fi

  ROTATING=""
  case "$id" in
    username | hostname) EXPECTED_CHANGES["host.yaml:$id"]=1 ;;
    runtime:*) EXPECTED_CHANGES["secrets.yaml:${id#runtime:}"]=1 ;;
  esac
}

finish_age_key_rotation() {
  local old
  if ! entry_exists "$PREVIOUS_AGE_ENTRY"; then
    note "No previous age key in KeePassXC; nothing to finish."
    return
  fi
  echo
  echo "Every machine should have run nix-secrets-setup with the new age key."
  if [[ -z "$NONINTERACTIVE" ]] && ! confirm "Move $PREVIOUS_AGE_ENTRY to KeePassXC's recycle bin?"; then
    note "Kept $PREVIOUS_AGE_ENTRY."
    return
  fi
  before_first_write
  kp rm "$PREVIOUS_AGE_ENTRY" >/dev/null
  if entry_exists "$PREVIOUS_AGE_ENTRY"; then
    fail "Could not remove $PREVIOUS_AGE_ENTRY."
    exit 1
  fi
  ok "Moved $PREVIOUS_AGE_ENTRY to the recycle bin"
  for old in "$AGE_KEY_FILE".rotated-*; do
    [[ -e "$old" ]] && note "Old local key kept at $old; delete it once you're sure."
  done
}

# --- local files --------------------------------------------------------------

AGE_KEY_REPLACED=""

sync_local_files() {
  local label username hostname name json="{}"
  echo
  echo "Deriving local files in $SECRETS_DIR"

  read_state age-key
  if [[ "$STATE" != defined ]]; then
    note "No age key in KeePassXC; skipping all local files."
    return
  fi
  mkdir -p "$SECRETS_DIR"
  if git -C "$SECRETS_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "$SECRETS_DIR is inside a git repository; refusing to write secrets there."
    exit 1
  fi
  chmod 700 "$SECRETS_DIR"
  install_age_key "$CURRENT"

  read_state age-key-label && label="${CURRENT:-primary}"
  write_sops_config "$label"

  read_state username && username="$CURRENT"
  read_state hostname && hostname="$CURRENT"
  if [[ -n "$username" && -n "$hostname" ]]; then
    write_sops_file host.yaml "$(jq -n --arg u "$username" --arg h "$hostname" '{username: $u, hostname: $h}')"
  else
    note "username/hostname not both defined; skipping host.yaml"
  fi

  for name in "${RUNTIME_NAMES[@]}"; do
    read_state "runtime:$name"
    [[ -n "$CURRENT" ]] && json="$(jq --arg k "$name" --arg v "$CURRENT" '.[$k] = $v' <<<"$json")"
  done
  write_sops_file secrets.yaml "$json"
}

# install_age_key <identity from the vault>
install_age_key() {
  local local_key rotated
  if [[ -f "$AGE_KEY_FILE" ]]; then
    local_key="$(cat "$AGE_KEY_FILE")"
    if [[ "$(public_key "$local_key")" == "$(public_key "$1")" ]]; then
      ok "$AGE_KEY_FILE matches KeePassXC"
      return
    fi
    # Only the key being rotated away from is replaced; any other is left alone.
    if ! kp_get attachment-export --stdout "$PREVIOUS_AGE_ENTRY" "$ATTACHMENT" ||
      [[ "$(public_key "$OUTPUT")" != "$(public_key "$local_key")" ]]; then
      fail "$AGE_KEY_FILE holds a different key than KeePassXC; not touching it."
      fail "Move it aside and rerun to install the key from KeePassXC."
      exit 1
    fi
    rotated="$AGE_KEY_FILE.rotated-$(date +%Y%m%d-%H%M%S)"
    mv "$AGE_KEY_FILE" "$rotated"
    note "The age key was rotated; kept the old one at $rotated"
    AGE_KEY_REPLACED=1
  fi
  mkdir -p "$(dirname "$AGE_KEY_FILE")"
  chmod 700 "$(dirname "$AGE_KEY_FILE")"
  (umask 077 && printf '%s\n' "$1" >"$AGE_KEY_FILE")
  ok "Installed $AGE_KEY_FILE"
}

write_sops_config() {
  cat >"$SOPS_CONFIG" <<EOF
# Generated by nix-secrets-setup from KeePassXC ($GROUP).
keys:
  - &$1 $(age-keygen -y "$AGE_KEY_FILE")
creation_rules:
  - path_regex: \.ya?ml$
    key_groups:
      - age:
          - *$1
EOF
  ok "Wrote $SOPS_CONFIG"
}

# write_sops_file <name> <json>: rewrites the file only when it changed, and
# asks before removing or changing values nobody asked to change.
write_sops_file() {
  local name="$1" file="$SECRETS_DIR/$1" want current surprises
  want="$(jq -S . <<<"$2")"

  if [[ -f "$file" ]]; then
    if current="$(sops decrypt --output-type json "$file" 2>/dev/null)"; then
      current="$(jq -S . <<<"$current")"
      if [[ "$current" == "$want" ]]; then
        ok "$file is up to date"
        return
      fi
      surprises="$(unexpected_changes "$name" "$current" "$want")"
      if [[ -n "$surprises" ]] && ! may_replace "$file" "$surprises"; then
        return
      fi
    elif [[ -z "$AGE_KEY_REPLACED" ]]; then
      fail "Can't decrypt $file with $AGE_KEY_FILE; not replacing it."
      fail "Move it aside if it is stale, then rerun."
      exit 1
    fi
    cp -p "$file" "${file%.yaml}.prev.yaml" # .yaml, so sops can still read it
  fi

  (cd "$SECRETS_DIR" &&
    sops --config "$SOPS_CONFIG" encrypt --filename-override "$name" \
      --input-type json --output-type yaml <<<"$want" >"$TMP_DIR/$name")
  mv "$TMP_DIR/$name" "$file"
  chmod 600 "$file"

  if [[ "$(sops decrypt --output-type json "$file" | jq -S .)" != "$want" ]]; then
    fail "$file did not decrypt back to the KeePassXC values."
    exit 1
  fi
  ok "Wrote $file and verified it decrypts${AGE_KEY_REPLACED:+ with the new key}"
}

# Keys whose value would be removed or changed, other than expected ones.
unexpected_changes() {
  local name="$1" current="$2" want="$3" change
  jq -r --argjson want "$want" '
    to_entries[] | . as $e
    | if ($want | has($e.key)) | not then "\($e.key) (removed)"
      elif $want[$e.key] != $e.value then "\($e.key) (changed)"
      else empty end' <<<"$current" |
    while read -r change; do
      [[ -n "${EXPECTED_CHANGES["$name:${change% (*}"]:-}" ]] || echo "$change"
    done
}

# may_replace <file> <changes>: lists the changes (key names only) and asks.
may_replace() {
  local change
  note "$1 differs from KeePassXC for:"
  while read -r change; do note "  $change"; done <<<"$2"
  if [[ -n "$NONINTERACTIVE" ]]; then
    fail "Not replacing $1 without confirmation; rerun without --auto/--env/--skip-missing."
    exit 1
  fi
  confirm "  Replace $1 with the values in KeePassXC?" && return
  note "Kept $1 unchanged."
  return 1
}

# --- summary ------------------------------------------------------------------

summarize() {
  local id
  echo
  if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "Skipped for now (rerun nix-secrets-setup to set them):"
    for id in "${SKIPPED[@]}"; do note "$(entry_of "$id")"; done
  elif [[ ${#CONFLICTS[@]} -eq 0 ]]; then
    echo "All secrets are defined."
  fi
  if [[ -n "$ENV_LOADED" ]]; then
    echo "The values from $ENV_LOADED are now in KeePassXC; consider deleting that file."
  fi
  if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
    echo "Resolve these in KeePassXC by hand, then rerun:"
    for id in "${CONFLICTS[@]}"; do note "$(entry_of "$id")"; done
    exit 1
  fi
  if [[ "$(uname -s)" == Darwin ]]; then
    echo "Next: darwin-switch"
  else
    echo "Next: home-manager switch"
  fi
}

# --- main ---------------------------------------------------------------------

echo "Checking KeePassXC secrets in $DB_PATH (group: $GROUP)"
unlock
if [[ "$MODE" == env ]]; then
  load_env_file "$ENV_FILE" || exit 1
fi

if [[ -n "$FINISH_ROTATION" ]]; then
  finish_age_key_rotation
  exit 0
fi
[[ -z "$ROTATE" ]] || rotate "$ROTATE"

check_vault
fill_missing
sync_local_files
summarize
