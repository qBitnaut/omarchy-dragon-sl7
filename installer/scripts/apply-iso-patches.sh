#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Apply installer/iso-patches (in series order) to an omarchy-iso checkout.
#
# usage: apply-iso-patches.sh ISO_DIR [--check]
#   --check  verify that the whole series applies, change nothing
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

iso="${1:?usage: apply-iso-patches.sh ISO_DIR [--check]}"
mode="${2:-apply}"
patches="$REPO_ROOT/installer/iso-patches"
[ -d "$iso/builder" ] && [ -d "$iso/configs" ] || die "$iso is not an omarchy-iso checkout"

patch_list() { grep -vE '^(#.*|)$' "$patches/series"; }

if [ "$mode" = "--check" ]; then
	# Apply onto a throwaway copy of the tracked files so that later patches
	# are checked against the result of the earlier ones.
	tmp="$(mktemp -d)"
	trap 'rm -rf "${tmp:?}"' EXIT
	git -C "$iso" ls-files -z | xargs -0 tar -C "$iso" -cf - | tar -C "$tmp" -xf -
	git -C "$tmp" init -q
	iso="$tmp"
elif [ "$mode" != "apply" ]; then
	die "unknown option: $mode"
fi

while IFS= read -r p; do
	info "patch $p"
	git -C "$iso" apply --check "$patches/$p" || die "$p does not apply"
	git -C "$iso" apply "$patches/$p"
done < <(patch_list)
info "all patches in installer/iso-patches/series applied${tmp:+ (check only)}"
