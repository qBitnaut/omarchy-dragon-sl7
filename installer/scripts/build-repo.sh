#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Run INSIDE the Arch Linux ARM builder container, as root.
# Builds the packages that are not downloaded as CI artifacts, adds the
# prebuilt linux-sl7 and iptsd-sl7 packages, and creates the local pacman
# repository "omarchy-sl7" that omarchy-iso mounts with --local-repo.
#
# Environment (all mounts read-only except /repo):
#   SL7_PREBUILT  directory holding the downloaded *.pkg.tar.* (default /prebuilt)
#   SL7_SOURCES   directories to build, one PKGBUILD directory each, in
#                 sub-directories (default /src: /src/omarchy-surface-sl7,
#                 /src/omarchy-sl7-keyring, /src/pr/qcom-firmware-extract, /src/pr/linux-aarch64-pkgbase-shim)
#   ARCHINSTALL_VERSION, ARCHINSTALL_SHA256  pinned archinstall (upstream.lock)
#   SL7_REPO      output repository directory (default /repo)
set -euo pipefail

prebuilt="${SL7_PREBUILT:-/prebuilt}"
src="${SL7_SOURCES:-/src}"
repo="${SL7_REPO:-/repo}"
work=/build
expected=(linux-sl7 linux-sl7-headers iptsd-sl7 omarchy-surface-sl7 omarchy-sl7-keyring omarchy-sl7-battery qcom-firmware-extract linux-aarch64-pkgbase-shim archinstall)

grep -q '^DisableSandbox' /etc/pacman.conf ||
	sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
pacman -Syu --noconfirm --needed base-devel git curl
sed -i "s|^PKGEXT=.*|PKGEXT='.pkg.tar.zst'|" /etc/makepkg.conf
id builder >/dev/null 2>&1 || useradd -m builder

mkdir -p "$repo" "$work/out"
chown builder:builder "$work/out"

# Build one PKGBUILD directory as the unprivileged builder user. --nodeps: the
# packages are files and scripts only, and their runtime dependencies (omarchy,
# linux-sl7, ...) come from other repositories at install time.
build_pkg() { # directory
	local dir="$1" name
	name="$(basename "$dir")"
	[ -f "$dir/PKGBUILD" ] || { echo "build-repo: no PKGBUILD in $dir" >&2; exit 1; }
	echo "==> building $name"
	rm -rf "${work:?}/$name"
	cp -a "$dir" "$work/$name"
	chown -R builder:builder "$work/$name"
	runuser -u builder -- env PKGDEST="$work/out" \
		bash -c "cd '$work/$name' && makepkg --nodeps --noconfirm --force --cleanbuild"
}

build_pkg "$src/omarchy-sl7-keyring"
build_pkg "$src/omarchy-surface-sl7"
build_pkg "$src/pr/qcom-firmware-extract"
build_pkg "$src/pr/linux-aarch64-pkgbase-shim"

# archinstall: the orchestrator needs 4.4; ALARM extra has 4.5 (API break).
# arch=any, so the Arch archive package is used as is, checksum-pinned.
: "${ARCHINSTALL_VERSION:?ARCHINSTALL_VERSION not set (upstream.lock)}"
: "${ARCHINSTALL_SHA256:?ARCHINSTALL_SHA256 not set (upstream.lock)}"
ai_file="archinstall-${ARCHINSTALL_VERSION}-any.pkg.tar.zst"
curl -fsSL --retry 3 -o "$work/out/$ai_file" \
	"https://archive.archlinux.org/packages/a/archinstall/$ai_file"
echo "$ARCHINSTALL_SHA256  $work/out/$ai_file" | sha256sum -c -

# Debug packages are not part of the repository.
find "$work/out" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*-debug-*' -exec cp -v {} "$repo/" \;
find "$prebuilt" -name '*.pkg.tar.*' ! -name '*.sig' ! -name '*-debug-*' -exec cp -v {} "$repo/" \;

cd "$repo"
rm -f omarchy-sl7.db* omarchy-sl7.files* omarchy.db
repo-add omarchy-sl7.db.tar.gz ./*.pkg.tar.*
# omarchy-iso-make and build-iso.sh insist on a file named omarchy.db inside the
# --local-repo directory. Nothing reads it: the repository section is
# [omarchy-sl7] (installer/iso-patches/0005).
ln -sf omarchy-sl7.db omarchy.db

# Every package the installer needs must be listed in the database.
listing="$(tar -tzf omarchy-sl7.db.tar.gz)"
for name in "${expected[@]}"; do
	if ! grep -Eq "^$name-[0-9][^/]*/desc$" <<<"$listing"; then
		echo "build-repo: $name is missing from omarchy-sl7.db" >&2
		exit 1
	fi
done
chmod -R a+rX "$repo"
echo "build-repo: repository $repo:"
ls -l "$repo"
