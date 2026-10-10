#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fetch the upstream checkouts named in upstream.lock at exactly the pinned SHAs.
#
# usage: fetch-upstreams.sh DEST NAME...
#   NAME is omarchy, omarchy-iso or omarchy-pkgs. DEST/NAME is created fresh.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dest="${1:?usage: fetch-upstreams.sh DEST NAME...}"
shift
[ $# -gt 0 ] || die "name at least one of: omarchy omarchy-iso omarchy-pkgs"
load_lock

# fetch_sha DIR SHA: fetch one commit by SHA.
fetch_sha() {
	local dir="$1" sha="$2"
	git -C "$dir" fetch -q --depth 1 origin "$sha" 2>/dev/null ||
		die "cannot fetch $sha from $(git -C "$dir" remote get-url origin)"
}

checkout_pinned() { # name url sha
	local name="$1" url="$2" sha="$3" dir="$dest/$1"
	info "$name @ $sha"
	rm -rf "${dir:?}"
	mkdir -p "$dir"
	git -C "$dir" init -q
	git -C "$dir" remote add origin "$url"
	fetch_sha "$dir" "$sha"
	git -C "$dir" checkout -q --detach "$sha"
	[ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ] || die "$name: HEAD is not $sha"
}

for name in "$@"; do
	case "$name" in
	omarchy)
		checkout_pinned omarchy "$OMARCHY_REPO" "$OMARCHY_SHA"
		;;
	omarchy-iso)
		checkout_pinned omarchy-iso "$OMARCHY_ISO_REPO" "$OMARCHY_ISO_SHA"
		gitlink="$(git -C "$dest/omarchy-iso" ls-tree HEAD archiso | awk '{print $3}')"
		[ "$gitlink" = "$OMARCHY_ISO_ARCHISO_SHA" ] ||
			die "omarchy-iso records archiso $gitlink, upstream.lock pins $OMARCHY_ISO_ARCHISO_SHA"
		;;
	omarchy-pkgs)
		checkout_pinned omarchy-pkgs "$OMARCHY_PKGS_REPO" "$OMARCHY_PKGS_SHA"
		;;
	*) die "unknown upstream: $name" ;;
	esac
done
