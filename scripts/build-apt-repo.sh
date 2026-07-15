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

# Rebuild package indexes from the packages you drop into pool/main/
dpkg-scanpackages --arch all pool/main /dev/null > "${base}/binary-all/Packages"
dpkg-scanpackages --arch amd64 pool/main /dev/null > "${base}/binary-amd64/Packages"
dpkg-scanpackages --arch arm64 pool/main /dev/null > "${base}/binary-arm64/Packages"

gzip -kf "${base}/binary-all/Packages"
gzip -kf "${base}/binary-amd64/Packages"
gzip -kf "${base}/binary-arm64/Packages"

# Generate Release with checksums and metadata
cat > "${repo_root}/dists/${suite}/release.conf" <<'EOF'
APT::FTPArchive::Release::Origin "LFF Linux";
APT::FTPArchive::Release::Label "LFF Linux";
APT::FTPArchive::Release::Suite "stable";
APT::FTPArchive::Release::Codename "stable";
APT::FTPArchive::Release::Architectures "all amd64 arm64";
APT::FTPArchive::Release::Components "main";
APT::FTPArchive::Release::Description "LFF Linux Package Repository";
EOF

apt-ftparchive -c "${repo_root}/dists/${suite}/release.conf" release "dists/${suite}" > "dists/${suite}/Release"

# Sign only if secrets are present
if [[ -z "${GPG_PRIVATE_KEY:-}" || -z "${GPG_KEY_ID:-}" || -z "${GPG_PASSPHRASE:-}" ]]; then
  echo "Missing one or more GPG secrets: GPG_PRIVATE_KEY, GPG_KEY_ID, GPG_PASSPHRASE" >&2
  exit 1
fi

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
