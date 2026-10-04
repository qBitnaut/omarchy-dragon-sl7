#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Run INSIDE the Arch Linux ARM builder container, as root.
# Builds linux-sl7 and linux-sl7-headers with makepkg as an unprivileged user
# and collects the artifacts.
#
# Environment:
#   SL7_SRC    read-only mount of pkgs/linux-sl7      (default /src)
#   SL7_OUT    writable output directory              (default /out)
#   CCACHE_DIR writable ccache directory              (default /ccache)
set -euo pipefail

src="${SL7_SRC:-/src}"
out="${SL7_OUT:-/out}"
ccache_dir="${CCACHE_DIR:-/ccache}"
build=/build/linux-sl7
jobs="$(nproc)"

# Docker on the runner may not allow pacman's download sandbox (landlock).
grep -q '^DisableSandbox' /etc/pacman.conf \
    || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf

pacman -Syu --noconfirm --needed \
    base-devel bc ccache cpio dtc git inetutils kmod pahole perl python tar xz

# makepkg: native -j, ccache, zstd packages
sed -i "s|^#\?MAKEFLAGS=.*|MAKEFLAGS=\"-j${jobs}\"|" /etc/makepkg.conf
sed -i "s|^PKGEXT=.*|PKGEXT='.pkg.tar.zst'|" /etc/makepkg.conf
sed -i 's|^BUILDENV=(\(.*\)!ccache|BUILDENV=(\1ccache|' /etc/makepkg.conf
grep -q '^BUILDENV=.*[^!]ccache' /etc/makepkg.conf \
    || { echo "ci-build: could not enable ccache in makepkg.conf" >&2; exit 1; }

mkdir -p "$build" "$out" "$ccache_dir"
cp -a "$src/." "$build/"
# makepkg looks up local sources by basename in the build dir, so the
# entries listed as scripts/... and patches/... must also sit at the top.
cp -a "$src/scripts/check-config.sh" "$src"/patches/* "$build/"
chown -R builder:builder "$build" "$ccache_dir"
chmod 0777 "$out"

runuser -u builder -- env \
    CCACHE_DIR="$ccache_dir" \
    CCACHE_MAXSIZE=5G \
    CCACHE_SLOPPINESS=time_macros,include_file_mtime \
    bash -c "cd '$build' && makepkg --syncdeps --noconfirm --force"

runuser -u builder -- ccache -s || true

kdir="$(echo "$build"/src/linux-*/)"
kdir="${kdir%/}"

cp -v "$build"/*.pkg.tar.* "$out"/
cp -v "$kdir/arch/arm64/boot/Image" "$out/Image"
cp -v "$kdir/.config" "$out/config.final"
mkdir -p "$out/dtbs"
cp -v "$kdir"/arch/arm64/boot/dts/qcom/x1*.dtb "$out/dtbs/"

(
    cd "$out"
    sums="$(mktemp)"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > "$sums"
    mv "$sums" SHA256SUMS
    chmod 0644 SHA256SUMS
)
echo "ci-build: artifacts in $out"
