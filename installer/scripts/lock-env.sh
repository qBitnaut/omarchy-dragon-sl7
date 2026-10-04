#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Print the KEY=value lines of upstream.lock after validating its shape, for
#   installer/scripts/lock-env.sh >> "$GITHUB_ENV"
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_lock
grep -E '^[A-Z0-9_]+=' "${UPSTREAM_LOCK:-$REPO_ROOT/upstream.lock}"
