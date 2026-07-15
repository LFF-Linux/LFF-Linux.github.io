#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

suite="stable"
component="main"
base="dists/${suite}/${component}"

mkdir -p "${base}/binary-all"
mkdir -p "${base}/binary-amd64"
mkdir -p "${base}/binary-arm64"

# Rebuild package indexes
dpkg-scanpackages --arch all   pool/main /dev/null > "${base}/binary-all/Packages"
dpkg-scanpackages --arch amd64 pool/main /dev/null > "${base}/binary-amd64/Packages"
dpkg-scanpackages --arch arm64 pool/main /dev/null > "${base}/binary-arm64/Packages"

gzip -kf "${base}/binary-all/Packages"
gzip -kf "${base}/binary-amd64/Packages"
gzip -kf "${base}/binary-arm64/Packages"

# Generate Release metadata
apt-ftparchive release "dists/${suite}" > "dists/${suite}/Release"

# Sign Release only when secrets are provided
if [[ -n "${GPG_PRIVATE_KEY:-}" && -n "${GPG_KEY_ID:-}" && -n "${GPG_PASSPHRASE:-}" ]]; then
  export GNUPGHOME
  GNUPGHOME="$(mktemp -d)"
  chmod 700 "$GNUPGHOME"
  trap 'rm -rf "$GNUPGHOME"' EXIT

  printf '%s' "$GPG_PRIVATE_KEY" | gpg --batch --import

  cd "dists/${suite}"

  gpg --batch --yes \
      --pinentry-mode loopback \
      --passphrase "$GPG_PASSPHRASE" \
      --default-key "$GPG_KEY_ID" \
      -abs -o Release.gpg Release

  gpg --batch --yes \
      --pinentry-mode loopback \
      --passphrase "$GPG_PASSPHRASE" \
      --default-key "$GPG_KEY_ID" \
      --clearsign -o InRelease Release
fi
