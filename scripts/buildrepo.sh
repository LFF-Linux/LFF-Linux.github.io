#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SUITE="stable"
COMPONENT="main"

BASE="dists/$SUITE/$COMPONENT"

echo "Cleaning old indexes..."

rm -rf \
    "$BASE/binary-all" \
    "$BASE/binary-amd64" \
    "$BASE/binary-arm64"

mkdir -p \
    "$BASE/binary-all" \
    "$BASE/binary-amd64" \
    "$BASE/binary-arm64"


TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT


echo "Selecting newest packages..."


python3 <<PY
import subprocess
import shutil
from pathlib import Path

pool = Path("pool/main")

targets = {
    "all": Path("dists/stable/main/binary-all"),
    "amd64": Path("dists/stable/main/binary-amd64"),
    "arm64": Path("dists/stable/main/binary-arm64"),
}


def get_info(file):

    out=subprocess.check_output(
        [
            "dpkg-deb",
            "-f",
            str(file),
            "Package",
            "Version",
            "Architecture"
        ],
        text=True
    )

    result={}

    for line in out.splitlines():
        key,value=line.split(":",1)
        result[key]=value.strip()

    return result



def newer(a,b):

    return subprocess.run(
        [
            "dpkg",
            "--compare-versions",
            a,
            "gt",
            b
        ],
        stdout=subprocess.DEVNULL
    ).returncode == 0



packages={}


for deb in pool.glob("*.deb"):

    info=get_info(deb)

    key=(
        info["Package"],
        info["Architecture"]
    )


    if key not in packages:
        packages[key]=(info["Version"],deb)

    elif newer(info["Version"],packages[key][0]):
        packages[key]=(info["Version"],deb)



for (name,arch),(version,file) in packages.items():

    if arch not in targets:
        continue

    shutil.copy(
        file,
        targets[arch] / file.name
    )

    print(
        f"Using {name} {version} ({arch})"
    )

PY


echo "Generating Packages files..."


dpkg-scanpackages \
    --arch all \
    "$BASE/binary-all" \
    /dev/null \
    > "$BASE/binary-all/Packages"


dpkg-scanpackages \
    --arch amd64 \
    "$BASE/binary-amd64" \
    /dev/null \
    > "$BASE/binary-amd64/Packages"


dpkg-scanpackages \
    --arch arm64 \
    "$BASE/binary-arm64" \
    /dev/null \
    > "$BASE/binary-arm64/Packages"


gzip -kf "$BASE/binary-all/Packages"
gzip -kf "$BASE/binary-amd64/Packages"
gzip -kf "$BASE/binary-arm64/Packages"


echo "Generating Release..."


cat > dists/stable/release.conf <<EOF
APT::FTPArchive::Release::Origin "LFF Linux";
APT::FTPArchive::Release::Label "LFF Linux";
APT::FTPArchive::Release::Suite "stable";
APT::FTPArchive::Release::Codename "stable";
APT::FTPArchive::Release::Architectures "all amd64 arm64";
APT::FTPArchive::Release::Components "main";
EOF


apt-ftparchive \
    -c dists/stable/release.conf \
    release \
    dists/stable \
    > dists/stable/Release



echo "Signing repository..."


rm -f \
    dists/stable/InRelease \
    dists/stable/Release.gpg


gpg \
    --default-key "C5E8494532E5FAC3DF4589AD39200693EB6F536B" \
    --armor \
    --detach-sign \
    --output dists/stable/Release.gpg \
    dists/stable/Release



gpg \
    --default-key "C5E8494532E5FAC3DF4589AD39200693EB6F536B" \
    --clearsign \
    --output dists/stable/InRelease \
    dists/stable/Release



echo "APT repository built"
