#!/usr/bin/env bash
set -euo pipefail

# Makes sure every machine-identifying secret this repo needs is defined in
# KeePassXC, asking for the missing ones one at a time and reading each back
# to confirm it was stored. Then derives the local, never-committed state
# from KeePassXC:
#
#   ~/.config/sops/age/keys.txt  age identity (attachment of the age-key entry)
#   .sops.yaml                   recipients file, git-ignored
#   secrets/host.yaml            username/hostname, sops-encrypted (safe to commit)
#
# See docs/secrets.md.

usage() {
  echo "Usage: $0 [path-to-database.kdbx]" >&2
  echo "  The database can also be given as \$KEEPASSXC_DATABASE." >&2
  echo "  Optional: \$KEEPASSXC_KEYFILE, \$NIX_SECRETS_GROUP (default: nix-config)." >&2
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

DB_PATH="${1:-${KEEPASSXC_DATABASE:-}}"
if [[ -z "$DB_PATH" ]]; then
  read -rp "Path to KeePassXC database (.kdbx): " DB_PATH
fi
DB_PATH="${DB_PATH/#\~/$HOME}"
if [[ ! -f "$DB_PATH" ]]; then
  echo "Error: database not found: $DB_PATH" >&2
  exit 1
fi

GROUP="${NIX_SECRETS_GROUP:-nix-config}"
AGE_ENTRY="$GROUP/age-key"
AGE_ATTACHMENT="keys.txt"

REPO="${NIX_CONFIG_DIR:-$(git rev-parse --show-toplevel)}"
SOPS_CONFIG="$REPO/.sops.yaml"
HOST_FILE="secrets/host.yaml"

AGE_KEY_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt"
# sops' default on macOS is ~/Library/Application Support; pin it to the
# same file sops-nix reads (home/modules/secrets.nix).
export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

KEYFILE_ARGS=()
if [[ -n "${KEEPASSXC_KEYFILE:-}" ]]; then
  KEYFILE_ARGS=(-k "$KEEPASSXC_KEYFILE")
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }

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

entry_exists() { kp show "$1" >/dev/null 2>&1; }

ensure_group() {
  if ! kp ls "$GROUP" >/dev/null 2>&1; then
    kp mkdir "$GROUP" >/dev/null
    ok "Created group $GROUP"
  fi
}

# Reads a value stored in an entry's UserName field.
get_value() { kp show -a UserName "$1" 2>/dev/null || true; }

set_value() {
  if entry_exists "$1"; then
    kp edit -u "$2" "$1" >/dev/null
  else
    kp add -u "$2" "$1" >/dev/null
  fi
}

# ensure_value <entry> <description> <suggested default> [allowed pattern]
ensure_value() {
  local entry="$1" description="$2" default="$3" pattern="${4:-}" value stored

  if [[ -n "$(get_value "$entry")" ]]; then
    ok "$entry is defined"
    return
  fi

  echo
  echo "Missing: $entry ($description)"
  while true; do
    read -rp "  Value${default:+ [$default]}: " value
    value="${value:-$default}"
    if [[ -z "$value" ]]; then
      fail "A value is required."
      continue
    fi
    if [[ -n "$pattern" && ! "$value" =~ $pattern ]]; then
      fail "'$value' must match $pattern."
      continue
    fi
    confirm "  Store '$value' in $entry?" || continue

    set_value "$entry" "$value"
    stored="$(get_value "$entry")"
    if [[ "$stored" == "$value" ]]; then
      ok "$entry stored and verified"
      return
    fi
    fail "Read back '$stored' from $entry instead of '$value'; let's try again."
  done
}

ensure_age_key() {
  local source choice

  if kp attachment-export --stdout "$AGE_ENTRY" "$AGE_ATTACHMENT" 2>/dev/null | grep -q '^AGE-SECRET-KEY-'; then
    ok "$AGE_ENTRY is defined"
    return
  fi

  echo
  echo "Missing: $AGE_ENTRY (age private key that decrypts this repo's secrets, attachment '$AGE_ATTACHMENT')"
  while true; do
    if [[ -f "$AGE_KEY_FILE" ]]; then
      read -rp "  [g]enerate a new key, [i]mport a key file, or [u]se $AGE_KEY_FILE? " choice
    else
      read -rp "  [g]enerate a new key or [i]mport a key file? " choice
    fi
    case "$choice" in
      g*)
        rm -f "$TMP_DIR/keys.txt"
        (umask 077 && age-keygen -o "$TMP_DIR/keys.txt" 2>/dev/null)
        source="$TMP_DIR/keys.txt"
        ;;
      i*)
        read -rp "  Path to age key file: " source
        source="${source/#\~/$HOME}"
        ;;
      u*)
        [[ -f "$AGE_KEY_FILE" ]] || continue
        source="$AGE_KEY_FILE"
        ;;
      *) continue ;;
    esac

    if ! age-keygen -y "$source" >/dev/null 2>&1; then
      fail "$source is not a valid age identity."
      continue
    fi
    confirm "  Store the key with public key $(age-keygen -y "$source") in $AGE_ENTRY?" || continue

    entry_exists "$AGE_ENTRY" || kp add "$AGE_ENTRY" >/dev/null
    kp attachment-import -f "$AGE_ENTRY" "$AGE_ATTACHMENT" "$source" >/dev/null
    if kp attachment-export --stdout "$AGE_ENTRY" "$AGE_ATTACHMENT" | cmp -s - "$source"; then
      ok "$AGE_ENTRY stored and verified"
      return
    fi
    fail "The attachment read back from $AGE_ENTRY does not match; let's try again."
  done
}

install_age_key() {
  local key_dir public_kp public_local
  key_dir="$(dirname "$AGE_KEY_FILE")"
  public_kp="$(kp attachment-export --stdout "$AGE_ENTRY" "$AGE_ATTACHMENT" | age-keygen -y)"

  if [[ -f "$AGE_KEY_FILE" ]]; then
    public_local="$(age-keygen -y "$AGE_KEY_FILE")"
    if [[ "$public_local" != "$public_kp" ]]; then
      fail "$AGE_KEY_FILE holds a different key than $AGE_ENTRY; not touching it."
      fail "Move it aside and rerun to install the key from KeePassXC."
      exit 1
    fi
    ok "$AGE_KEY_FILE matches KeePassXC"
    return
  fi

  mkdir -p "$key_dir"
  chmod 700 "$key_dir"
  (umask 077 && kp attachment-export --stdout "$AGE_ENTRY" "$AGE_ATTACHMENT" >"$AGE_KEY_FILE")
  chmod 600 "$AGE_KEY_FILE"
  ok "Installed age key at $AGE_KEY_FILE"
}

write_sops_config() {
  local label public_key
  label="$(get_value "$GROUP/age-key-label")"
  public_key="$(age-keygen -y "$AGE_KEY_FILE")"

  if ! git -C "$REPO" check-ignore -q "$SOPS_CONFIG"; then
    fail "$SOPS_CONFIG is not git-ignored; refusing to write it."
    exit 1
  fi

  cat >"$SOPS_CONFIG" <<EOF
# Generated by nix-secrets-setup from KeePassXC ($GROUP); git-ignored.
keys:
  - &$label $public_key
creation_rules:
  - path_regex: secrets/.*\.ya?ml$
    key_groups:
      - age:
          - *$label
EOF
  ok "Wrote $SOPS_CONFIG"
}

host_value() { sops decrypt --extract "[\"$1\"]" "$REPO/$HOST_FILE" 2>/dev/null || true; }

write_host_secrets() {
  local username hostname
  username="$(get_value "$GROUP/username")"
  hostname="$(get_value "$GROUP/hostname")"

  if [[ -f "$REPO/$HOST_FILE" && "$(host_value username)" == "$username" && "$(host_value hostname)" == "$hostname" ]]; then
    ok "$HOST_FILE is up to date"
    return
  fi

  mkdir -p "$REPO/secrets"
  printf 'username: %s\nhostname: %s\n' "$username" "$hostname" |
    (cd "$REPO" && sops --config "$SOPS_CONFIG" encrypt --filename-override "$HOST_FILE" >"$TMP_DIR/host.yaml")
  mv "$TMP_DIR/host.yaml" "$REPO/$HOST_FILE"

  if [[ "$(host_value username)" == "$username" && "$(host_value hostname)" == "$hostname" ]]; then
    ok "Encrypted username/hostname into $HOST_FILE"
  else
    fail "$HOST_FILE did not decrypt back to the KeePassXC values."
    exit 1
  fi
}

default_hostname() {
  if command -v scutil >/dev/null 2>&1; then
    scutil --get LocalHostName 2>/dev/null && return
  fi
  hostname -s 2>/dev/null || true
}

echo "Checking KeePassXC secrets in $DB_PATH (group: $GROUP)"
unlock
ensure_group
ensure_age_key
ensure_value "$GROUP/age-key-label" "name for the age key in .sops.yaml" "primary" '^[A-Za-z0-9_-]+$'
ensure_value "$GROUP/username" "macOS user nix-darwin and Home Manager manage" "$(id -un)"
ensure_value "$GROUP/hostname" "host name; also the darwinConfigurations attribute" "$(default_hostname)"

echo
echo "Syncing local state from KeePassXC"
install_age_key
write_sops_config
write_host_secrets

echo
echo "All secrets are defined. Apply the system with: darwin-switch"
