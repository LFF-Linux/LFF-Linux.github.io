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

python3 - "$repo_root" "$stage_root" <<'PY'
import subprocess
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
stage_root = Path(sys.argv[2])
pool = repo_root / "pool" / "main"

deb_files = sorted(pool.glob("*.deb"))

def read_fields(path: Path):
    out = subprocess.check_output(
        ["dpkg-deb", "-f", str(path), "Package", "Version", "Architecture"],
        text=True,
    )
    data = {}
    for line in out.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            data[k.strip()] = v.strip()
    return data.get("Package", ""), data.get("Version", ""), data.get("Architecture", "")

def version_gt(a: str, b: str) -> bool:
    if a == b:
        return False
    return subprocess.run(
        ["dpkg", "--compare-versions", a, "gt", b],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0

best = {}  # (package, arch) -> (version, path)

for deb in deb_files:
    pkg, ver, arch = read_fields(deb)
    if not pkg or not ver or not arch:
        continue

    key = (pkg, arch)
    if key not in best or version_gt(ver, best[key][0]):
        best[key] = (ver, deb)

for (pkg, arch), (_, deb) in best.items():
    if arch == "all":
        dest = stage_root / "binary-all" / deb.name
    elif arch == "amd64":
        dest = stage_root / "binary-amd64" / deb.name
    elif arch == "arm64":
        dest = stage_root / "binary-arm64" / deb.name
    else:
        continue

    dest.write_bytes(deb.read_bytes())
PY

if [ -f dists/stable/release.conf ]; then
    :
else
    cat > dists/stable/release.conf <<'EOF'
APT::FTPArchive::Release::Origin "LFF Linux";
APT::FTPArchive::Release::Label "LFF Linux";
APT::FTPArchive::Release::Suite "stable";
APT::FTPArchive::Release::Codename "stable";
APT::FTPArchive::Release::Architectures "all amd64 arm64";
APT::FTPArchive::Release::Components "main";
APT::FTPArchive::Release::Description "LFF Linux Package Repository";
EOF
fi

dpkg-scanpackages --arch all "${stage_root}/binary-all" /dev/null > "${base}/binary-all/Packages"
dpkg-scanpackages --arch amd64 "${stage_root}/binary-amd64" /dev/null > "${base}/binary-amd64/Packages"
dpkg-scanpackages --arch arm64 "${stage_root}/binary-arm64" /dev/null > "${base}/binary-arm64/Packages"

gzip -kf "${base}/binary-all/Packages"
gzip -kf "${base}/binary-amd64/Packages"
gzip -kf "${base}/binary-arm64/Packages"

apt-ftparchive -c dists/stable/release.conf release dists/stable > dists/stable/Release

if [[ -z "${GPG_PRIVATE_KEY:-}" || -z "${GPG_KEY_ID:-}" || -z "${GPG_PASSPHRASE:-}" ]]; then
    echo "Error: missing one or more GPG secrets: GPG_PRIVATE_KEY, GPG_KEY_ID, GPG_PASSPHRASE" >&2
    exit 1
fi

export GNUPGHOME
GNUPGHOME="$(mktemp -d)"
chmod 700 "$GNUPGHOME"
trap 'rm -rf "$GNUPGHOME"' EXIT

printf '%s' "$GPG_PRIVATE_KEY" | gpg --batch --import >/dev/null 2>&1

cd dists/stable

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
