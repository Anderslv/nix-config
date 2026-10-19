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
# See docs/secrets.md.

usage() {
  cat >&2 <<EOF
Usage: $0 [options] [path-to-database.kdbx]

Options:
  --auto          Set missing secrets automatically where a value can be
                  derived; ask for the rest.
  --env FILE      Set missing secrets from a .env file; ask for the rest.
  --skip-missing  Only report missing secrets, then sync what is defined.
  -h, --help      Show this help.

The database can also be given as \$KEEPASSXC_DATABASE. Optional:
\$KEEPASSXC_KEYFILE, \$NIX_SECRETS_GROUP (default: nix-config),
\$NIX_SECRETS_DIR (default: ~/.config/nix-secrets).

.env keys: NIX_SECRETS_AGE_KEY (an AGE-SECRET-KEY-... line),
NIX_SECRETS_AGE_KEY_LABEL, NIX_SECRETS_USERNAME, NIX_SECRETS_HOSTNAME, and
SECRET_<NAME> for each name in nix/secret-names.txt (upper case, - as _).
EOF
}

MODE=""
ENV_FILE=""
DB_PATH="${KEEPASSXC_DATABASE:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) MODE="auto" ;;
    --env)
      MODE="env"
      ENV_FILE="${2:?--env needs a file}"
      shift
      ;;
    --skip-missing) MODE="skip" ;;
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

REPO="${NIX_CONFIG_DIR:-$(git rev-parse --show-toplevel)}"
SECRET_NAMES_FILE="$REPO/nix/secret-names.txt"

# Must match home/modules/secrets.nix.
SECRETS_DIR="${NIX_SECRETS_DIR:-$HOME/.config/nix-secrets}"
AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
SOPS_CONFIG="$SECRETS_DIR/.sops.yaml"
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

# Every keepassxc-cli call gets the master password on stdin, so it is only
# asked for once.
kp() {
  local cmd="$1"
  shift
  printf '%s\n' "$KP_PASSWORD" | keepassxc-cli "$cmd" -q "${KEYFILE_ARGS[@]}" "$DB_PATH" "$@"
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

# --- secrets -----------------------------------------------------------------
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

get_value() { kp show -a Password "$(entry_of "$1")" 2>/dev/null || true; }

get_age_key() { kp attachment-export --stdout "$(entry_of age-key)" "$AGE_ATTACHMENT" 2>/dev/null || true; }

is_defined() {
  if [[ "$1" == age-key ]]; then
    get_age_key | grep -q '^AGE-SECRET-KEY-'
  else
    [[ -n "$(get_value "$1")" ]]
  fi
}

# store_value <id> <value>; reads it back and reports whether it matches.
store_value() {
  local id="$1" value="$2" entry stored cmd=add
  entry="$(entry_of "$id")"
  validate "$id" "$value" || return 1
  ensure_group "$GROUP"
  [[ "$id" == runtime:* ]] && ensure_group "$RUNTIME_GROUP"

  kp show "$entry" >/dev/null 2>&1 && cmd=edit
  printf '%s\n%s\n' "$KP_PASSWORD" "$value" |
    keepassxc-cli "$cmd" -q -p "${KEYFILE_ARGS[@]}" "$DB_PATH" "$entry" >/dev/null

  stored="$(get_value "$id")"
  if [[ "$stored" == "$value" ]]; then
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
  ensure_group "$GROUP"
  kp show "$entry" >/dev/null 2>&1 || kp add "$entry" >/dev/null
  kp attachment-import -f "$entry" "$AGE_ATTACHMENT" "$source" >/dev/null
  if get_age_key | cmp -s - "$source"; then
    ok "$entry stored and verified (public key $(age-keygen -y "$source"))"
    return 0
  fi
  fail "The attachment read back from $entry does not match."
  return 1
}

generate_age_key() {
  rm -f "$TMP_DIR/keys.txt"
  (umask 077 && age-keygen -o "$TMP_DIR/keys.txt" 2>/dev/null)
  echo "$TMP_DIR/keys.txt"
}

# --- ways of setting a secret -------------------------------------------------

set_auto() {
  local id="$1" value
  if [[ "$id" == age-key ]]; then
    # Reuse a key this machine already has, otherwise make a new one.
    if [[ -f "$AGE_KEY_FILE" ]]; then
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

SKIPPED=()
SKIP_REST=""

# Asks how to set one secret until it is stored or skipped.
guided() {
  local id="$1" auto="" choice
  if [[ "$id" == age-key ]]; then
    auto="generate a new key"
    [[ -f "$AGE_KEY_FILE" ]] && auto="reuse $AGE_KEY_FILE"
  else
    auto="$(auto_value "$id" 2>/dev/null || true)"
  fi

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
  guided "$id"
}

# --- local files --------------------------------------------------------------

install_age_key() {
  local public_kp
  public_kp="$(get_age_key | age-keygen -y)"
  if [[ -f "$AGE_KEY_FILE" ]]; then
    if [[ "$(age-keygen -y "$AGE_KEY_FILE")" != "$public_kp" ]]; then
      fail "$AGE_KEY_FILE holds a different key than KeePassXC; not touching it."
      fail "Move it aside and rerun to install the key from KeePassXC."
      exit 1
    fi
    ok "$AGE_KEY_FILE matches KeePassXC"
    return
  fi
  mkdir -p "$(dirname "$AGE_KEY_FILE")"
  chmod 700 "$(dirname "$AGE_KEY_FILE")"
  (umask 077 && get_age_key >"$AGE_KEY_FILE")
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

# write_sops_file <name> <json>; rewrites the file only when it changed.
write_sops_file() {
  local file="$SECRETS_DIR/$1" want current
  want="$(jq -S . <<<"$2")"
  current="$(sops decrypt --output-type json "$file" 2>/dev/null | jq -S . 2>/dev/null || true)"
  if [[ -f "$file" && "$current" == "$want" ]]; then
    ok "$file is up to date"
    return
  fi
  (cd "$SECRETS_DIR" &&
    sops --config "$SOPS_CONFIG" encrypt --filename-override "$1" \
      --input-type json --output-type yaml <<<"$2" >"$TMP_DIR/$1")
  mv "$TMP_DIR/$1" "$file"
  chmod 600 "$file"
  current="$(sops decrypt --output-type json "$file" | jq -S .)"
  if [[ "$current" == "$want" ]]; then
    ok "Wrote $file and verified it decrypts"
  else
    fail "$file did not decrypt back to the KeePassXC values."
    exit 1
  fi
}

sync_local_files() {
  local label username hostname json name value

  echo
  echo "Deriving local files in $SECRETS_DIR"
  if ! is_defined age-key; then
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

  label="$(get_value age-key-label)"
  write_sops_config "${label:-primary}"

  username="$(get_value username)"
  hostname="$(get_value hostname)"
  if [[ -n "$username" && -n "$hostname" ]]; then
    json="$(jq -n --arg u "$username" --arg h "$hostname" '{username: $u, hostname: $h}')"
    write_sops_file host.yaml "$json"
  else
    note "username/hostname not both defined; skipping host.yaml"
  fi

  json="{}"
  for name in "${RUNTIME_NAMES[@]}"; do
    value="$(get_value "runtime:$name")"
    [[ -n "$value" ]] || continue
    json="$(jq --arg k "$name" --arg v "$value" '.[$k] = $v' <<<"$json")"
  done
  write_sops_file secrets.yaml "$json"
}

# --- main ---------------------------------------------------------------------

echo "Checking KeePassXC secrets in $DB_PATH (group: $GROUP)"
unlock
if [[ "$MODE" == env ]]; then
  load_env_file "$ENV_FILE"
fi

MISSING=()
for id in "${SECRETS[@]}"; do
  if is_defined "$id"; then
    ok "$(entry_of "$id")"
  else
    fail "$(entry_of "$id") is missing"
    MISSING+=("$id")
  fi
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
      a) MODE=auto ;;
      e)
        read -rp "Path to .env file: " ENV_FILE
        load_env_file "$ENV_FILE" && MODE="env"
        ;;
      g) MODE=guided ;;
      s) MODE=skip ;;
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
else
  echo "All secrets are defined."
fi
if [[ -n "$ENV_LOADED" ]]; then
  echo "The values from $ENV_LOADED are now in KeePassXC; consider deleting that file."
fi
