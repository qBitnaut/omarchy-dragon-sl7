#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fetch the upstream checkouts named in upstream.lock at exactly the pinned SHAs.
#
# usage: fetch-upstreams.sh DEST NAME...
#   NAME is omarchy, omarchy-iso or omarchy-pkgs. DEST/NAME is created fresh.
#   omarchy-pkgs also fetches the PR #221/#222 commits (see pr-pkgbuilds.sh).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dest="${1:?usage: fetch-upstreams.sh DEST NAME...}"
shift
[ $# -gt 0 ] || die "name at least one of: omarchy omarchy-iso omarchy-pkgs"
load_lock

# fetch_sha DIR SHA [PR-NUMBER]: fetch one commit by SHA; for a PR commit that
# the server will not serve by SHA, fall back to refs/pull/N/head and require
# it to still point at the pinned SHA.
fetch_sha() {
	local dir="$1" sha="$2" pr="${3:-}" got
	if git -C "$dir" fetch -q --depth 1 origin "$sha" 2>/dev/null; then
		return 0
	fi
	[ -n "$pr" ] || die "cannot fetch $sha from $(git -C "$dir" remote get-url origin)"
	git -C "$dir" fetch -q --depth 1 origin "refs/pull/$pr/head" || die "cannot fetch PR #$pr"
	got="$(git -C "$dir" rev-parse FETCH_HEAD)"
	[ "$got" = "$sha" ] || die "PR #$pr head is $got, upstream.lock pins $sha (PR was updated: review it, then update upstream.lock)"
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
		fetch_sha "$dest/omarchy-pkgs" "$OMARCHY_PKGS_PR221_SHA" 221
		fetch_sha "$dest/omarchy-pkgs" "$OMARCHY_PKGS_PR222_SHA" 222
		git -C "$dest/omarchy-pkgs" cat-file -e "$OMARCHY_PKGS_PR221_SHA^{commit}"
		git -C "$dest/omarchy-pkgs" cat-file -e "$OMARCHY_PKGS_PR222_SHA^{commit}"
		;;
	*) die "unknown upstream: $name" ;;
	esac
done
