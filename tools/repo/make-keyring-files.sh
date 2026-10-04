#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Write pkgs/omarchy-sl7-keyring/{omarchy-sl7.gpg,omarchy-sl7-trusted} from a public key
# (key rotation). Bump pkgrel in the PKGBUILD and update the fingerprint in
# tools/bootstrap/omarchy-sl7-bootstrap.sh afterwards.
# usage: make-keyring-files.sh FINGERPRINT [GNUPGHOME | PUBKEY.asc]
set -euo pipefail
fpr="${1:?usage: make-keyring-files.sh FINGERPRINT [GNUPGHOME | PUBKEY.asc]}"
src="${2:-}"
[[ $fpr =~ ^[0-9A-Fa-f]{40}$ ]] || { echo "not a 40-hex fingerprint: $fpr" >&2; exit 2; }
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../pkgs/omarchy-sl7-keyring" && pwd)"
if [[ -f $src ]]; then
	gpg --dearmor <"$src" >"$dir/omarchy-sl7.gpg"
else
	GNUPGHOME="${src:-${GNUPGHOME:-$HOME/.gnupg}}" gpg --export "$fpr" >"$dir/omarchy-sl7.gpg"
fi
[[ -s $dir/omarchy-sl7.gpg ]] || { echo "no key exported" >&2; exit 1; }
got="$(gpg --show-keys --with-colons "$dir/omarchy-sl7.gpg" | awk -F: '$1=="fpr"{print $10; exit}')"
[[ ${got^^} == "${fpr^^}" ]] || { echo "exported key is $got, not $fpr" >&2; exit 1; }
echo "${fpr^^}:4:" >"$dir/omarchy-sl7-trusted"
echo "wrote $dir/omarchy-sl7.gpg and omarchy-sl7-trusted"
