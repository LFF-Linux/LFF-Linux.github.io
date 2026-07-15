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

stage_root="$(mktemp -d)"
trap 'rm -rf "$stage_root"' EXIT

mkdir -p "${stage_root}/binary-all" "${stage_root}/binary-amd64" "${stage_root}/binary-arm64"

echo "Selecting newest package per package/architecture..."
python3 - "$repo_root" "$stage_root" <<'PY'
import subprocess
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
stage_root = Path(sys.argv[2])
pool = repo_root / "pool" / "main"

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

# Keep highest version for each (Package, Architecture)
best = {}

for deb in sorted(pool.glob("*.deb")):
    try:
        pkg, ver, arch = deb_fields(deb)
    except Exception:
        continue

    key = (pkg, arch)
    current = best.get(key)
    if current is None or ver_gt(ver, current[0]):
        best[key] = (ver, deb)

# Copy only winners into staged dirs
for (pkg, arch), (ver, deb) in sorted(best.items()):
    if arch == "all":
        dest_dir = stage_root / "binary-all"
    elif arch == "amd64":
        dest_dir = stage_root / "binary-amd64"
    elif arch == "arm64":
        dest_dir = stage_root / "binary-arm64"
    else:
        # Ignore any other architectures for this repo
        continue

    dest = dest_dir / deb.name
    dest.write_bytes(deb.read_bytes())
    print(f"keep {pkg} {ver} {arch}: {deb.name}")
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

dpkg-scanpackages --arch all "${stage_root}/binary-all" /dev/null > "${base}/binary-all/Packages"
dpkg-scanpackages --arch amd64 "${stage_root}/binary-amd64" /dev/null > "${base}/binary-amd64/Packages"
dpkg-scanpackages --arch arm64 "${stage_root}/binary-arm64" /dev/null > "${base}/binary-arm64/Packages"

gzip -kf "${base}/binary-all/Packages"
gzip -kf "${base}/binary-amd64/Packages"
gzip -kf "${base}/binary-amd64/Packages" 2>/dev/null || true
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
