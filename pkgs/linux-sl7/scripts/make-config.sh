#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the linux-sl7 .config in a patched kernel tree: config.alarm merged
# with config.sl7, resolved by olddefconfig, then asserted.
# Usage: make-config.sh <kernel-src-dir>
# Honours CROSS_COMPILE and LLVM from the environment. Without a cross
# compiler the host compiler is used, which is enough for config resolution.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:?usage: make-config.sh <kernel-src-dir>}"
cd "$src"

export ARCH=arm64
cp "$here/config.alarm" .config
scripts/kconfig/merge_config.sh -m -O . .config "$here/config.sl7" > /dev/null
make olddefconfig
"$here/scripts/check-config.sh" .config "$here/config.sl7"
