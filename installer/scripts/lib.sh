#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Shared helpers for the installer pipeline scripts. Source it, do not run it.
# Sets REPO_ROOT and loads upstream.lock.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"

die() {
	echo "ERROR: $*" >&2
	exit 1
}
info() { echo "==> $*"; }

load_lock() {
	local lock="${UPSTREAM_LOCK:-$REPO_ROOT/upstream.lock}"
	[ -f "$lock" ] || die "missing $lock"
	# Only KEY=value lines of a strict shape are ever evaluated.
	if grep -vE '^([A-Z0-9_]+=[A-Za-z0-9:/._-]*|#.*|)$' "$lock"; then
		die "$lock has lines that are not KEY=value or comments"
	fi
	# shellcheck disable=SC1090
	source "$lock"
}
