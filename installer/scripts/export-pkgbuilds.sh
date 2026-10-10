#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Export two PKGBUILD directories of the omarchy-pkgs checkout at the commit
# pinned in upstream.lock, ready for build-repo.sh (both were open pull requests
# #221 and #222 until they were merged into master):
#   pkgbuilds/qcom-firmware-extract
#   pkgbuilds/linux-aarch64-pkgbase-shim
#
# usage: export-pkgbuilds.sh PKGS_CHECKOUT OUT_DIR
#   PKGS_CHECKOUT is the omarchy-pkgs checkout from fetch-upstreams.sh.
#   OUT_DIR/<pkgname>/ is created fresh.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pkgs="${1:?usage: export-pkgbuilds.sh PKGS_CHECKOUT OUT_DIR}"
out="${2:?usage: export-pkgbuilds.sh PKGS_CHECKOUT OUT_DIR}"
load_lock

export_pkg() { # pkgname
	local name="$1" sha="$OMARCHY_PKGS_SHA"
	info "$name from $sha"
	git -C "$pkgs" cat-file -e "$sha:pkgbuilds/$name/PKGBUILD" ||
		die "$sha has no pkgbuilds/$name/PKGBUILD"
	rm -rf "${out:?}/$name"
	mkdir -p "$out/$name"
	git -C "$pkgs" archive "$sha" "pkgbuilds/$name" | tar -x -C "$out/$name" --strip-components=2
	[ -f "$out/$name/PKGBUILD" ] || die "export of $name failed"
}

export_pkg qcom-firmware-extract
export_pkg linux-aarch64-pkgbase-shim
