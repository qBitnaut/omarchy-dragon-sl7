#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the omarchy-sl7 repository directory that gets published as GitHub Release
# assets (tag repo-aarch64). Needs repo-add, vercmp, bsdtar, gpg (run it in an Arch
# container; .github/workflows/publish-repo.yml does).
#
# usage: repo-build.sh POOL
#   POOL  directory holding the existing release packages plus the new ones
#         (*.pkg.tar.zst and their .sig). It is rewritten in place:
#         - firmware guard (guard-artifacts.sh), debug packages dropped, file names checked
#         - only the newest KEEP (default 2) versions of each package stay
#         - every package without a valid detached signature is signed
#         - omarchy-sl7.db / .files (REAL copies, not symlinks) and their .sig are created
#         - POOL/.assets lists every file to upload
# Environment:
#   REPO_SIGNING_KEY      ASCII-armored private key, no passphrase (CI secret)
#   REPO_SIGNING_KEY_ID   its key id or fingerprint (CI secret)
#   Without them signing is SKIPPED with a loud warning; everything else still runs.
#   KEEP                  versions kept per package (default 2)
#   KEYRING_TRUSTED       omarchy-sl7-trusted to cross-check the key against
#   HOST_UID, HOST_GID    chown the result to them (container runs as root)
set -euo pipefail

pool="${1:?usage: repo-build.sh POOL}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
keep="${KEEP:-2}"
trusted="${KEYRING_TRUSTED:-$root/pkgs/omarchy-sl7-keyring/omarchy-sl7-trusted}"
repo=omarchy-sl7
[[ -d $pool ]] || { echo "repo-build: no such directory: $pool" >&2; exit 2; }
cd "$pool"
shopt -s nullglob

warn() { if [[ -n ${GITHUB_ACTIONS:-} ]]; then echo "::warning title=repo-build::$*"; fi; echo "repo-build: WARNING: $*" >&2; }

# 1. firmware guard, debug packages, names. GitHub rewrites characters outside
# [A-Za-z0-9._-] in asset names, which would break the database entries.
"$root/pkgs/linux-sl7/scripts/guard-artifacts.sh" "$pool"
rm -f -- *-debug-*.pkg.tar.* omarchy-sl7.db* omarchy-sl7.files* ./*.old .assets
for f in *.pkg.tar.*; do
	[[ $f =~ ^[A-Za-z0-9._-]+$ ]] || { echo "repo-build: asset name would be rewritten by GitHub: $f" >&2; exit 1; }
	case $f in *.sig) ;; *.pkg.tar.zst) ;; *) echo "repo-build: unexpected file $f" >&2; exit 1 ;; esac
done

# 2. newest KEEP versions per package name (version from .PKGINFO, vercmp order)
pkg_field() { bsdtar -xOf "$1" .PKGINFO | awk -F' = ' -v k="$2" '$1 == k { print $2; exit }'; }
records=()
for f in *.pkg.tar.zst; do
	n="$(pkg_field "$f" pkgname)"
	v="$(pkg_field "$f" pkgver)"
	[[ -n $n && -n $v ]] || { echo "repo-build: no pkgname/pkgver in $f" >&2; exit 1; }
	[[ $v != *:* ]] || { echo "repo-build: epoch in $f (asset name would change)" >&2; exit 1; }
	records+=("$n $v $f")
done
mapfile -t names < <(printf '%s\n' "${records[@]}" | awk '{print $1}' | sort -u)
current=()
for n in "${names[@]}"; do
	mapfile -t files < <(printf '%s\n' "${records[@]}" | awk -v n="$n" '$1 == n { print $2, $3 }')
	# insertion sort, newest first, by vercmp
	sorted=()
	for rec in "${files[@]}"; do
		v="${rec%% *}"
		placed=0
		out=()
		for s in "${sorted[@]}"; do
			if ((!placed)) && (($(vercmp "$v" "${s%% *}") > 0)); then out+=("$rec"); placed=1; fi
			out+=("$s")
		done
		((placed)) || out+=("$rec")
		sorted=("${out[@]}")
	done
	i=0
	for rec in "${sorted[@]}"; do
		i=$((i + 1))
		f="${rec#* }"
		if ((i == 1)); then current+=("$f"); fi
		if ((i > keep)); then echo "repo-build: dropping old $f"; rm -f -- "$f" "$f.sig"; fi
	done
done
((${#current[@]})) || { echo "repo-build: no packages in $pool" >&2; exit 1; }
printf 'repo-build: current: %s\n' "${current[@]}"

# 3. signing
sign=0
gnupghome=""
cleanup() { [[ -n $gnupghome ]] && { gpgconf --homedir "$gnupghome" --kill all 2>/dev/null || true; rm -rf "$gnupghome"; }; return 0; }
trap cleanup EXIT
if [[ -n ${REPO_SIGNING_KEY:-} && -n ${REPO_SIGNING_KEY_ID:-} ]]; then
	gnupghome="$(mktemp -d)"
	chmod 700 "$gnupghome"
	export GNUPGHOME="$gnupghome"
	printf '%s\n' "$REPO_SIGNING_KEY" | gpg --batch --quiet --import
	gpg --batch --list-secret-keys "$REPO_SIGNING_KEY_ID" >/dev/null ||
		{ echo "repo-build: REPO_SIGNING_KEY does not contain REPO_SIGNING_KEY_ID" >&2; exit 1; }
	fpr="$(gpg --batch --with-colons --list-secret-keys "$REPO_SIGNING_KEY_ID" | awk -F: '$1 == "fpr" { print $10; exit }')"
	# Clients only trust what omarchy-sl7-keyring ships: refuse a mismatching key.
	want="$(cut -d: -f1 "$trusted" 2>/dev/null | grep -E '^[0-9A-Fa-f]{40}$' || true)"
	if [[ -n $want ]]; then
		grep -qix "$fpr" <<<"$want" ||
			{ echo "repo-build: signing key $fpr is not in $trusted; clients would reject the repository" >&2; exit 1; }
	else
		warn "$trusted lists no key; not cross-checking the signing key"
	fi
	sign=1
	echo "repo-build: signing with $fpr"
else
	warn "REPO_SIGNING_KEY / REPO_SIGNING_KEY_ID not set: packages and database are NOT signed. Clients with SigLevel = Required will reject this repository."
fi

if ((sign)); then
	for f in *.pkg.tar.zst; do
		if [[ -f $f.sig ]] && gpg --batch --quiet --verify "$f.sig" "$f" 2>/dev/null; then continue; fi
		rm -f "$f.sig"
		gpg --batch --yes --quiet --detach-sign --no-armor --local-user "$fpr" --output "$f.sig" "$f"
		gpg --batch --quiet --verify "$f.sig" "$f" 2>/dev/null
		echo "repo-build: signed $f"
	done
else
	for f in *.pkg.tar.zst; do
		[[ -f $f.sig ]] || echo "repo-build: unsigned: $f"
	done
fi

# 4. database: only the newest version of each package; real files, no symlinks
if ((sign)); then
	repo-add --quiet --sign --key "$fpr" "$repo.db.tar.gz" "${current[@]}"
else
	repo-add --quiet "$repo.db.tar.gz" "${current[@]}"
fi
for ext in db files; do
	cp --remove-destination -L "$repo.$ext.tar.gz" "$repo.$ext"
	if [[ -f $repo.$ext.tar.gz.sig ]]; then cp --remove-destination -L "$repo.$ext.tar.gz.sig" "$repo.$ext.sig"; fi
	rm -f "$repo.$ext.tar.gz" "$repo.$ext.tar.gz.sig" "$repo.$ext.tar.gz.old"
done
((sign)) && { gpg --batch --quiet --verify "$repo.db.sig" "$repo.db" 2>/dev/null; gpg --batch --quiet --verify "$repo.files.sig" "$repo.files" 2>/dev/null; }
for f in "${current[@]}"; do
	bsdtar -tzf "$repo.db" | grep -Eq "^$(pkg_field "$f" pkgname)-[^/]*/desc$" || { echo "repo-build: $f missing from $repo.db" >&2; exit 1; }
done
if ((sign)); then
	gpg --batch --armor --export "$fpr" >omarchy-sl7.pub.asc
fi
for f in *; do [[ -L $f ]] && { echo "repo-build: symlink in pool: $f" >&2; exit 1; }; done

printf '%s\n' * >.assets
if [[ -n ${HOST_UID:-} ]]; then chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$pool"; fi
echo "repo-build: $(wc -l <.assets) files in $pool; signed=$sign"
