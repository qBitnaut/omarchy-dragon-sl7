#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fast validation of the linux-sl7 patch queue and config, no full build:
#   1. fetch and unpack the pinned kernel source
#   2. apply patches/series
#   3. merge config.alarm + config.sl7, olddefconfig, assert the options
#   4. build the Surface Laptop 7 DTBs and run dtbs_check (needs dtschema)
#   5. with SL7_COMPILE=1 (CI sets it on arm64 runners), compile the objects
#      the patch queue touches
# Usage: fast-check.sh <work-dir>
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${1:?usage: fast-check.sh <work-dir>}"

"$here/scripts/fetch-source.sh" "$work"
src="$(echo "$work"/linux-*/)"
src="${src%/}"

"$here/scripts/apply-series.sh" "$src"
"$here/scripts/make-config.sh" "$src"
"$here/scripts/check-dtbs.sh" "$src"

if [[ ${SL7_COMPILE:-0} == 1 ]]; then
    cd "$src"
    export ARCH=arm64
    make -j"$(nproc)" modules_prepare
    make -j"$(nproc)" \
        drivers/spi/spi-geni-qcom.o \
        drivers/dma/qcom/gpi.o \
        drivers/hid/spi-hid/ \
        drivers/firmware/arm_scmi/perf.o \
        drivers/power/supply/qcom_battmgr.o \
        drivers/usb/typec/mux/ps883x.o \
        drivers/net/wireless/ath/ath12k/core.o
fi
echo "fast-check: OK"
