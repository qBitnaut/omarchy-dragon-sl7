#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Assert that a resolved .config contains every option set in config.sl7,
# including "# CONFIG_X is not set" lines.
# Usage: check-config.sh [path/to/.config] [path/to/config.sl7]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${1:-.config}"
fragment="${2:-$here/config.sl7}"

[[ -f $config ]] || { echo "check-config: no such file: $config" >&2; exit 2; }
[[ -f $fragment ]] || { echo "check-config: no such file: $fragment" >&2; exit 2; }

fail=0
checked=0
while IFS= read -r line; do
    [[ $line =~ ^CONFIG_[A-Za-z0-9_]+= || $line =~ ^#\ CONFIG_[A-Za-z0-9_]+\ is\ not\ set$ ]] || continue
    checked=$((checked + 1))
    if ! grep -qxF -- "$line" "$config"; then
        if [[ $line == '# '* ]]; then
            name="${line#\# }"
            name="${name%% *}"
        else
            name="${line%%=*}"
        fi
        actual="$(grep -E "^(${name}=|# ${name} is not set)" "$config" || true)"
        echo "FAIL: want $line, have: ${actual:-<absent>}" >&2
        fail=$((fail + 1))
    fi
done < "$fragment"

if ((fail > 0)); then
    echo "check-config: $fail of $checked options not satisfied" >&2
    exit 1
fi
echo "check-config: all $checked options satisfied"
