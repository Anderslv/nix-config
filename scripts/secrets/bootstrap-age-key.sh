#!/usr/bin/env bash
set -euo pipefail

# Bootstraps the sops/age identity on a new machine by exporting the
# "keys.txt" attachment from a KeePassXC database entry into the location
# sops-nix is configured to read it from (see home/modules/secrets.nix).
#
# The private key never touches this repo and is only ever written to the
# single destination file below.

usage() {
  echo "Usage: $0 <path-to-database.kdbx> [entry-title] [attachment-name]" >&2
  echo "  entry-title      KeePassXC entry holding the key (default: sops-age-key)" >&2
  echo "  attachment-name  Attachment to export (default: keys.txt)" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

DB_PATH="$1"
ENTRY_TITLE="${2:-sops-age-key}"
ATTACHMENT_NAME="${3:-keys.txt}"

KEY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sops/age"
KEY_FILE="$KEY_DIR/keys.txt"

if [[ -e "$KEY_FILE" ]]; then
  echo "Error: $KEY_FILE already exists; refusing to overwrite." >&2
  echo "Remove it first if you intend to replace it." >&2
  exit 1
fi

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

# Ensure the exported key file is never created world/group readable, even
# momentarily, regardless of the umask of the invoking shell.
umask 077

echo "Unlocking $DB_PATH to export '$ENTRY_TITLE' -> '$ATTACHMENT_NAME' ..." >&2
keepassxc-cli attachment-export "$DB_PATH" "$ENTRY_TITLE" "$ATTACHMENT_NAME" "$KEY_FILE"
chmod 600 "$KEY_FILE"

echo "Age identity written to $KEY_FILE"
echo "Public key: $(age-keygen -y "$KEY_FILE")"
echo
echo "Confirm this public key matches the one in .sops.yaml before relying on it."
