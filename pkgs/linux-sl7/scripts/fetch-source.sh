#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck disable=SC2154
# Download the kernel tarball and the stable patch named in the PKGBUILD,
# verify their sha256 sums, and unpack a ready-to-patch tree.
# Usage: fetch-source.sh <work-dir>
# Result: <work-dir>/linux-<base>/ at the PKGBUILD's pkgver, unpatched by
# the linux-sl7 queue. Existing verified downloads are reused.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${1:?usage: fetch-source.sh <work-dir>}"

# Read the pinned URLs, sums and version from the PKGBUILD (sourcing only
# defines variables and functions, it does not build anything).
# shellcheck source=/dev/null
source "$here/PKGBUILD"

mkdir -p "$work"
cd "$work"

fetch() {
    local url="$1" sum="$2" file
    file="$(basename "$url")"
    if [[ -f $file ]] && echo "$sum  $file" | sha256sum -c --status; then
        echo "have $file"
        return
    fi
    curl -fL --retry 3 -o "$file" "$url"
    echo "$sum  $file" | sha256sum -c
}

fetch "${source[0]}" "${sha256sums[0]}"
fetch "${source[1]}" "${sha256sums[1]}"

tree="$_srcname"
rm -rf -- "${tree:?}"
tar xf "$(basename "${source[0]}")"
xz -dc "$(basename "${source[1]}")" | patch -d "$tree" -Np1 -s --no-backup-if-mismatch
echo "source tree ready: $work/$tree (linux $pkgver)"
