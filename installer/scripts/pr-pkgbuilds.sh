#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Export the PKGBUILD directories of the two open omarchy-pkgs PRs at the
# commits pinned in upstream.lock, ready for build-repo.sh.
#   #221 pkgbuilds/qcom-firmware-extract
#   #222 pkgbuilds/linux-aarch64-pkgbase-shim
#
# usage: pr-pkgbuilds.sh PKGS_CHECKOUT OUT_DIR
#   PKGS_CHECKOUT is the omarchy-pkgs checkout from fetch-upstreams.sh (it must
#   hold the PR commits). OUT_DIR/<pkgname>/ is created fresh.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pkgs="${1:?usage: pr-pkgbuilds.sh PKGS_CHECKOUT OUT_DIR}"
out="${2:?usage: pr-pkgbuilds.sh PKGS_CHECKOUT OUT_DIR}"
load_lock

export_pkg() { # sha pkgname
	local sha="$1" name="$2"
	info "$name from $sha"
	git -C "$pkgs" cat-file -e "$sha:pkgbuilds/$name/PKGBUILD" ||
		die "$sha has no pkgbuilds/$name/PKGBUILD"
	rm -rf "${out:?}/$name"
	mkdir -p "$out/$name"
	git -C "$pkgs" archive "$sha" "pkgbuilds/$name" | tar -x -C "$out/$name" --strip-components=2
	[ -f "$out/$name/PKGBUILD" ] || die "export of $name failed"
}

export_pkg "$OMARCHY_PKGS_PR221_SHA" qcom-firmware-extract
export_pkg "$OMARCHY_PKGS_PR222_SHA" linux-aarch64-pkgbase-shim
