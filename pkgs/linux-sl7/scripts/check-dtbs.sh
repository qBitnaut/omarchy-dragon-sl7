#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build and schema-check the Surface Laptop 7 device trees in a patched tree
# whose .config already exists (run make-config.sh first). Needs dtschema
# (dt-validate) on PATH for the schema check.
# Usage: check-dtbs.sh <kernel-src-dir>
#
# Three findings are expected and allow-listed because they come from the
# carried spi-hid v4 series and the out-of-tree QSPI support, which ship no
# matching binding updates:
#   - qcom,geni-spi-qspi is not in the geni-se binding
#   - read-opcode / write-opcode are declared uint8 in hid-over-spi.yaml but
#     the driver reads them with device_property_read_u32(), so the DT must
#     use 32-bit cells to work
# Any other warning for the romulus trees fails the check.
set -euo pipefail

src="${1:?usage: check-dtbs.sh <kernel-src-dir>}"
cd "$src"
export ARCH=arm64

dtbs=(qcom/x1e80100-microsoft-romulus13.dtb qcom/x1e80100-microsoft-romulus15.dtb)

make -j"$(nproc)" "${dtbs[@]}"

if ! command -v dt-validate > /dev/null; then
    echo "check-dtbs: dt-validate not found, skipping schema check" >&2
    exit 0
fi

make -j"$(nproc)" dt_binding_schemas
# Force a rebuild so the schema check runs on freshly compiled blobs.
for d in "${dtbs[@]}"; do rm -f "arch/arm64/boot/dts/$d"; done
out="$(make CHECK_DTBS=y "${dtbs[@]}" 2>&1)" || true

allowed="spi@[0-9a-f]+:compatible:0: 'qcom,geni-spi' was expected"
allowed+="|failed to match any schema with compatible: \['qcom,geni-spi-qspi'\]"
allowed+="|(read|write)-opcode: (\[0, 0, 0, [0-9]+\] is not of type 'integer'|size is 32, expected 8)"

unexpected="$(grep -E 'romulus1[35]\.dtb:' <<< "$out" | grep -Ev "$allowed" || true)"
if [[ -n $unexpected ]]; then
    echo "check-dtbs: unexpected dtbs_check findings:" >&2
    echo "$unexpected" >&2
    exit 1
fi
echo "check-dtbs: dtbs built, only the allow-listed findings remain"
