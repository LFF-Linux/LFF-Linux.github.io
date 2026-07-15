#!/usr/bin/env bash
set -euo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
    echo "Error: apt-get was not found. This script must run on Debian or Ubuntu." >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required but not installed." >&2
    exit 1
fi

if ! command -v gpg >/dev/null 2>&1; then
    echo "Error: gpg is required but not installed." >&2
    exit 1
fi

REPO_URL="https://lff-linux.github.io"
REPO_DIST="stable"
REPO_COMPONENT="main"
KEY_URL="https://lff-linux.github.io/keys/lff-linux-repo.asc"
KEYRING="/usr/share/keyrings/lff-linux.gpg"
LIST_FILE="/etc/apt/sources.list.d/lff-linux.list"

install_repo() {
    install -d -m 0755 /usr/share/keyrings

    tmp_key="$(mktemp)"
    trap 'rm -f "$tmp_key"' EXIT

    curl -fsSL "$KEY_URL" -o "$tmp_key"
    gpg --dearmor < "$tmp_key" | tee "$KEYRING" >/dev/null
    chmod 0644 "$KEYRING"

    printf 'deb [signed-by=%s] %s %s %s\n' "$KEYRING" "$REPO_URL" "$REPO_DIST" "$REPO_COMPONENT" \
        | tee "$LIST_FILE" >/dev/null
}

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Error: run this script with sudo." >&2
    exit 1
fi

install_repo
apt-get update

echo "LFF Linux repository added successfully."
