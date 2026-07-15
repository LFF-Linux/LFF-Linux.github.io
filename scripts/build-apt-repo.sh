#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

for cmd in dpkg-deb dpkg-scanpackages apt-ftparchive gpg python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: missing required command: $cmd" >&2
        exit 1
    fi
done

suite="stable"
component="main"
base="dists/${suite}/${component}"

mkdir -p "${base}/binary-all" "${base}/binary-amd64" "${base}/binary-arm64"

echo "Selecting newest packages and cleaning up old versions..."
python3 - "$repo_root" <<'PY'
import subprocess
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
pool = repo_root / "pool" / "main"

if not pool.exists():
    print(f"Warning: Pool directory {pool} does not exist.")
    sys.exit(0)

def deb_fields(path: Path):
    out = subprocess.check_output(
        ["dpkg-deb", "-f", str(path), "Package", "Version", "Architecture"],
        text=True,
    )
    data = {}
    for line in out.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            data[k.strip()] = v.strip()
    return data["Package"], data["Version"], data["Architecture"]

def ver_gt(a: str, b: str) -> bool:
    return subprocess.run(
        ["dpkg", "--compare-versions", a, "gt", b],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0

best = {}
all_debs = []

for deb in sorted(pool.glob("*.deb")):
    try:
        pkg, ver, arch = deb_fields(deb)
        all_debs.append(deb)
    except Exception:
        continue

    key = (pkg, arch)
    current = best.get(key)
    if current is None or ver_gt(ver, current[0]):
        best[key] = (ver, deb)

best_paths = {deb for ver, deb in best.values()}

# THE FIX: Physically delete older .deb files from the pool directory
for deb in all_debs:
    if deb not in best_paths:
        print(f"Removing old package: {deb.name}")
        deb.unlink()
    else:
        print(f"Keeping newest package: {deb.name}")
PY

cat > "dists/${suite}/release.conf" <<'EOF'
APT::FTPArchive::Release::Origin "LFF Linux";
APT::FTPArchive::Release::Label "LFF Linux";
APT::FTPArchive::Release::Suite "stable";
APT::FTPArchive::Release::Codename "stable";
APT::FTPArchive::Release::Architectures "all amd64 arm64";
APT::FTPArchive::Release::Components "main";
APT::FTPArchive::Release::Description "LFF Linux Package Repository";
EOF

# THE FIX: Scan directly from pool/main so the Filename paths are correctly mapped
dpkg-scanpackages --arch all pool/main /dev/null > "${base}/binary-all/Packages"
dpkg-scanpackages --arch amd64 pool/main /dev/null > "${base}/binary-amd64/Packages"
dpkg-scanpackages --arch arm64 pool/main /dev/null > "${base}/binary-arm64/Packages"

gzip -kf "${base}/binary-all/Packages"
gzip -kf "${base}/binary-amd64/Packages"
gzip -kf "${base}/binary-arm64/Packages"

apt-ftparchive -c "dists/${suite}/release.conf" release "dists/${suite}" > "dists/${suite}/Release"

if [[ -z "${GPG_PRIVATE_KEY:-}" || -z "${GPG_KEY_ID:-}" || -z "${GPG_PASSPHRASE:-}" ]]; then
    echo "Error: missing one or more GPG secrets: GPG_PRIVATE_KEY, GPG_KEY_ID, GPG_PASSPHRASE" >&2
    exit 1
fi

export GNUPGHOME
GNUPGHOME="$(mktemp -d)"
chmod 700 "$GNUPGHOME"
trap 'rm -rf "$GNUPGHOME"' EXIT

printf '%s' "$GPG_PRIVATE_KEY" | gpg --batch --import >/dev/null 2>&1

cd "dists/${suite}"
rm -f InRelease Release.gpg

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
