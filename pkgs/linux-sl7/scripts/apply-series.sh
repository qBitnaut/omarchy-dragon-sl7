#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Apply the linux-sl7 patch queue to an unpacked kernel source tree.
# Usage: apply-series.sh <kernel-src-dir> [--dry-run]
# With --dry-run every patch is only checked (note: later patches that depend
# on earlier ones can fail a dry run, so the real apply is the authoritative
# check; CI uses the real apply).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:?usage: apply-series.sh <kernel-src-dir> [--dry-run]}"
mode="${2:-}"
series="$here/patches/series"

[[ -d $src ]] || { echo "apply-series: no such directory: $src" >&2; exit 2; }
[[ -f $series ]] || { echo "apply-series: missing $series" >&2; exit 2; }

n=0
while IFS= read -r name; do
    [[ -z $name || $name == \#* ]] && continue
    p="$here/patches/$name"
    [[ -f $p ]] || { echo "apply-series: missing patch $name" >&2; exit 1; }
    if [[ $mode == --dry-run ]]; then
        patch -d "$src" -p1 --dry-run --no-backup-if-mismatch -s < "$p" \
            || { echo "apply-series: FAILED (dry run) $name" >&2; exit 1; }
    else
        patch -d "$src" -p1 --no-backup-if-mismatch -s < "$p" \
            || { echo "apply-series: FAILED $name" >&2; exit 1; }
    fi
    n=$((n + 1))
    echo "ok  $name"
done < "$series"
echo "apply-series: $n patches ${mode:+checked}${mode:-applied}"
