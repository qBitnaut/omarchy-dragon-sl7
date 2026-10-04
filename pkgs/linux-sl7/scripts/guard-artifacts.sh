#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fail if a build output directory contains anything that looks like
# Microsoft or Qualcomm firmware (*.mbn, *_dtbs.elf, *.jsn), either loose or
# inside a pkg.tar.* archive. Firmware is never built, committed or shipped
# by this project.
# Usage: guard-artifacts.sh <artifact-dir>
set -euo pipefail

dir="${1:?usage: guard-artifacts.sh <artifact-dir>}"
[[ -d $dir ]] || { echo "guard: no such directory: $dir" >&2; exit 2; }

pattern='\.(mbn|jsn)$|_dtbs\.elf$'
bad=0

while IFS= read -r f; do
    echo "guard: forbidden file in artifacts: $f" >&2
    bad=1
done < <(find "$dir" -type f \( -name '*.mbn' -o -name '*_dtbs.elf' -o -name '*.jsn' \))

shopt -s nullglob
for pkg in "$dir"/*.pkg.tar.*; do
    case "$pkg" in *.sig) continue ;; esac
    if tar -tf "$pkg" | grep -E "$pattern"; then
        echo "guard: forbidden file inside $pkg" >&2
        bad=1
    fi
done

if ((bad)); then
    exit 1
fi
echo "guard: no firmware files in $dir"
