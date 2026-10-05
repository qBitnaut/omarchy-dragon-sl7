#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Run INSIDE the Arch Linux ARM builder container, as root.
# Builds howdy-next-models and howdy-next with makepkg as an unprivileged user.
#
# howdy-next-models is not in the ALARM repos, so dependencies are installed
# here (everything except it) and makepkg runs with --nodeps. makepkg still
# verifies the sha256sums of every source.
#
# Environment:
#   HOWDY_SRC  read-only mount of pkgs/   (default /src)
#   HOWDY_OUT  writable output directory  (default /out)
set -euo pipefail

src="${HOWDY_SRC:-/src}"
out="${HOWDY_OUT:-/out}"

# Docker on the runner may not allow pacman's download sandbox (landlock).
grep -q '^DisableSandbox' /etc/pacman.conf \
    || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf

pacman -Syu --noconfirm --needed base-devel git
sed -i "s|^PKGEXT=.*|PKGEXT='.pkg.tar.zst'|" /etc/makepkg.conf
id builder >/dev/null 2>&1 || useradd -m builder
mkdir -p "$out"

for p in howdy-next-models howdy-next; do
    build="/build/$p"
    mkdir -p "$build"
    cp -a "$src/$p/." "$build/"
    chown -R builder:builder "$build"

    mapfile -t deps < <(
        cd "$build"
        # shellcheck disable=SC1091
        . ./PKGBUILD
        # shellcheck disable=SC2154
        printf '%s\n' "${depends[@]}" "${makedepends[@]}" "${checkdepends[@]:-}" |
            grep -v -e '^$' -e '^howdy-next-models$' || true
    )
    if [ "${#deps[@]}" -gt 0 ]; then
        pacman -S --noconfirm --needed "${deps[@]}"
    fi

    runuser -u builder -- bash -c "cd '$build' && makepkg --nodeps --noconfirm --force"
    cp -v "$build"/*.pkg.tar.zst "$out"/
done
rm -f "$out"/*-debug-*.pkg.tar.zst
echo "ci-build: packages in $out"
