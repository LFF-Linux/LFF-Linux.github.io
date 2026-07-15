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

# Build package indexes from pool/main
dpkg-scanpackages --arch all   pool/main /dev/null > "${base}/binary-all/Packages"
dpkg-scanpackages --arch amd64 pool/main /dev/null > "${base}/binary-amd64/Packages"
dpkg-scanpackages --arch arm64 pool/main /dev/null > "${base}/binary-arm64/Packages"

gzip -kf "${base}/binary-all/Packages"
gzip -kf "${base}/binary-amd64/Packages"
gzip -kf "${base}/binary-arm64/Packages"

# Generate Release with checksums
apt-ftparchive release "dists/${suite}" > "dists/${suite}/Release"
