#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# omarchy-sl7-bootstrap: put an EXISTING Omarchy install on the Surface Laptop 7 onto the
# omarchy-sl7 package repository, so `omarchy update` brings linux-sl7, iptsd-sl7 and
# omarchy-surface-sl7 from then on. Clean installs from our installer do not need this.
#
# Recommended: download it, read it, run it.
#   curl -fsSLO https://github.com/qBitnaut/omarchy-dragon-sl7/raw/main/tools/bootstrap/omarchy-sl7-bootstrap.sh
#   less omarchy-sl7-bootstrap.sh
#   bash omarchy-sl7-bootstrap.sh --dry-run     # read-only: shows what it would change
#   bash omarchy-sl7-bootstrap.sh
# `curl ... | bash` works too (the whole script is parsed before anything runs).
#
# What it does, in order (prints each change; safe to re-run, every step is idempotent):
#   1. checks this is a Surface Laptop 7 (aarch64) running Omarchy
#   2. fetches the repository public key and requires its fingerprint to equal the one
#      embedded below; checks that the published database verifies against it
#   3. adds the key to pacman's keyring and locally signs it (pacman-key --add, --lsign-key)
#   4. writes /etc/pacman.d/omarchy-sl7.conf and Includes it above [core] in /etc/pacman.conf
#      (backup: /etc/pacman.conf.pre-omarchy-sl7)
#   5. installs/upgrades omarchy-sl7-keyring omarchy-surface-sl7 linux-sl7 linux-sl7-headers
#      iptsd-sl7 in ONE `pacman -Syu` transaction, through omarchy-update-pacman (Omarchy's own
#      transaction wrapper, which satisfies its update guard), else through the guard's
#      documented bypass OMARCHY_ALLOW_DIRECT_PACMAN=1. Never a bare -Sy.
#   6. gives your user the `omarchy refresh pacman` hook and runs sl7-doctor
#
# Options:
#   --dry-run          change nothing, print what would happen
#   --no-install       stop after step 4; then run `omarchy update` yourself
#   --yes              pacman --noconfirm in step 5
#   --key-file FILE    use this public key instead of downloading it
#   --no-hardware-check  skip step 1 (testing only)
set -euo pipefail

# Fingerprint of the repository signing key (also in omarchy-sl7-keyring's
# omarchy-sl7-trusted). Rotate: update both.
EXPECTED_FPR=${SL7_EXPECTED_FPR:-6387C619EF246F6F20C536B72C3331C78353BA04}  # SL7_EXPECTED_FPR: tests only

REPO_URL=${SL7_REPO_URL:-https://github.com/qBitnaut/omarchy-dragon-sl7/releases/download/repo-aarch64}
KEY_URLS=("$REPO_URL/omarchy-sl7.pub.asc"
	"https://raw.githubusercontent.com/qBitnaut/omarchy-dragon-sl7/main/tools/repo/omarchy-sl7.pub.asc")
PACKAGES=(omarchy-sl7-keyring omarchy-surface-sl7 linux-sl7 linux-sl7-headers iptsd-sl7)

CONF=${SL7_PACMAN_CONF:-/etc/pacman.conf}
SNIPPET=${SL7_SNIPPET:-/etc/pacman.d/omarchy-sl7.conf}
GNUPGDIR=${SL7_PACMAN_GNUPG:-/etc/pacman.d/gnupg}
DMI_PRODUCT=${SL7_DMI_PRODUCT:-/sys/class/dmi/id/product_name}
PACMAN_KEY=${SL7_PACMAN_KEY:-pacman-key}

dry=0 install=1 yes=0 keyfile="" hwcheck=1
tmp=""

say() { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf 'omarchy-sl7-bootstrap: %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -n $tmp ]] && rm -rf "$tmp"; return 0; }

as_root() { # command...  (echoes; skipped in --dry-run)
	local sudo_cmd=()
	if ((EUID != 0)); then read -ra sudo_cmd <<<"${SL7_SUDO:-sudo}"; fi
	if ((dry)); then printf '    WOULD run: %s\n' "${sudo_cmd[*]} $*"; return 0; fi
	printf '    $ %s\n' "${sudo_cmd[*]} $*"
	"${sudo_cmd[@]}" "$@"
}

# The one awk that places the Include: before the first section other than [options],
# dropping an earlier misplaced copy. Same logic as omarchy-sl7-repo-ensure.
rewrite_conf() {
	awk -v inc="Include = $SNIPPET" '
		{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t) }
		skipblank && t == "" { skipblank = 0; next }
		{ skipblank = 0 }
		t == inc { skipblank = 1; next }
		t ~ /^\[.*\]$/ && t != "[options]" && !done { print inc; print ""; done = 1 }
		{ print }
		END { if (!done) { print ""; print inc } }
	' "$CONF"
}

include_ok() {
	awk -v inc="Include = $SNIPPET" '
		{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t) }
		t == inc { n++; if (sec) bad = 1; next }
		t ~ /^\[.*\]$/ && t != "[options]" { sec = 1 }
		END { exit !(n == 1 && !bad) }
	' "$CONF"
}

snippet_text() {
	cat <<'EOF'
# omarchy-sl7: Surface Laptop 7 packages (linux-sl7, iptsd-sl7, omarchy-surface-sl7, ...).
# Included from /etc/pacman.conf ABOVE [core]/[alarm]/[omarchy] so these packages win;
# omarchy-sl7-repo-ensure keeps the Include line there (see the package README).
# Hosted as GitHub Release assets; pacman follows the redirect to GitHub's object storage.
[omarchy-sl7]
SigLevel = Required DatabaseOptional
Server = https://github.com/qBitnaut/omarchy-dragon-sl7/releases/download/repo-aarch64
EOF
}

key_fprs() { # file -> primary key fingerprints, one per line
	gpg --batch --show-keys --with-colons "$1" 2>/dev/null |
		awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }'
}

key_trusted() {
	local v
	v=$(gpg --homedir "$GNUPGDIR" --batch --no-auto-check-trustdb --with-colons \
		--list-keys "$EXPECTED_FPR" 2>/dev/null | awk -F: '$1 == "pub" { print $2; exit }')
	[[ $v == f || $v == u ]]
}

step_preflight() {
	say "1. Checking this machine"
	if ((!hwcheck)); then note "hardware check skipped (--no-hardware-check)"; return 0; fi
	[[ $(uname -m) == aarch64 ]] || die "not aarch64 ($(uname -m)); this is for the Surface Laptop 7 only"
	local product
	product=$(cat "$DMI_PRODUCT" 2>/dev/null || true)
	[[ $product == *"Surface Laptop, 7th Edition"* ]] ||
		die "DMI product is '${product:-unknown}', not 'Microsoft Surface Laptop, 7th Edition'"
	[[ -d /usr/share/omarchy ]] || command -v omarchy >/dev/null 2>&1 || die "Omarchy is not installed"
	command -v pacman >/dev/null 2>&1 || die "pacman not found"
	note "$product, $(uname -m), Omarchy present"
}

step_key() {
	say "2. Fetching and verifying the repository key"
	local f=$tmp/key.asc u fprs
	if [[ -n $keyfile ]]; then
		cp -- "$keyfile" "$f" || die "cannot read $keyfile"
		note "using $keyfile"
	else
		for u in "${KEY_URLS[@]}"; do
			if curl -fsSL --retry 2 -o "$f" "$u"; then note "downloaded $u"; break; fi
			rm -f "$f"
		done
		[[ -s $f ]] || die "could not download the public key (is the repository published? try --key-file)"
	fi
	fprs=$(key_fprs "$f")
	[[ $(wc -l <<<"$fprs") == 1 && ${fprs^^} == "$EXPECTED_FPR" ]] ||
		die "key fingerprint mismatch: got '${fprs//$'\n'/ }', expected $EXPECTED_FPR. Refusing."
	note "fingerprint $EXPECTED_FPR matches the one embedded in this script"
	# The database must verify against exactly this key, or `pacman -Sy` would fail.
	mkdir -p "$tmp/gnupg" && chmod 700 "$tmp/gnupg"
	gpg --homedir "$tmp/gnupg" --batch --quiet --import "$f" 2>/dev/null
	if curl -fsSL --retry 2 -o "$tmp/db" "$REPO_URL/omarchy-sl7.db"; then
		if curl -fsSL --retry 2 -o "$tmp/db.sig" "$REPO_URL/omarchy-sl7.db.sig"; then
			gpg --homedir "$tmp/gnupg" --batch --verify "$tmp/db.sig" "$tmp/db" 2>/dev/null ||
				die "the published omarchy-sl7.db does not verify against the key; not touching anything"
			note "published database verifies against the key"
		else
			die "the published database has no signature; not touching anything"
		fi
	else
		die "$REPO_URL/omarchy-sl7.db is not published yet; not touching anything"
	fi
	keyfile=$f
}

step_trust() {
	say "3. Trusting the key in pacman's keyring"
	[[ -d $GNUPGDIR ]] || die "$GNUPGDIR does not exist (pacman-key --init has not run)"
	if key_trusted; then
		note "already trusted"
		return 0
	fi
	as_root "$PACMAN_KEY" --add "$keyfile"
	as_root "$PACMAN_KEY" --lsign-key "$EXPECTED_FPR"
}

step_config() {
	say "4. Configuring the repository"
	[[ -r $CONF ]] || die "cannot read $CONF"
	if grep -Eq '^[[:space:]]*\[omarchy-sl7\][[:space:]]*$' "$CONF"; then
		die "$CONF already defines [omarchy-sl7] itself. Remove that section (keep a backup) and re-run."
	fi
	if [[ -f $SNIPPET ]] && [[ $(<"$SNIPPET") == "$(snippet_text)" ]]; then
		note "$SNIPPET is up to date"
	else
		snippet_text >"$tmp/snippet"
		as_root install -Dm644 "$tmp/snippet" "$SNIPPET"
	fi
	if include_ok; then
		note "$CONF already includes $SNIPPET above the other repositories"
		return 0
	fi
	rewrite_conf >"$tmp/pacman.conf"
	if ((dry)); then
		note "pacman.conf would change as follows:"
		diff -u "$CONF" "$tmp/pacman.conf" | sed 's/^/      /' || true
	fi
	[[ -e $CONF.pre-omarchy-sl7 ]] || as_root cp -p "$CONF" "$CONF.pre-omarchy-sl7"
	as_root install -m644 "$tmp/pacman.conf" "$CONF"
}

step_install() {
	say "5. Installing $(printf '%s ' "${PACKAGES[@]}")"
	if ((!install)); then
		note "skipped (--no-install). Run: omarchy update"
		return 0
	fi
	local args=(-Syu --needed --overwrite "$SNIPPET")
	((yes)) && args+=(--noconfirm)
	args+=("${PACKAGES[@]}")
	# --overwrite: step 4 wrote the config file the package also ships.
	if command -v omarchy-update-pacman >/dev/null 2>&1; then
		note "via omarchy-update-pacman (Omarchy's update transaction wrapper)"
		if ((dry)); then note "WOULD run: omarchy-update-pacman ${args[*]}"; else omarchy-update-pacman "${args[@]}"; fi
	else
		note "omarchy-update-pacman not found; using the update guard's documented bypass"
		as_root env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman "${args[@]}"
	fi
}

step_finish() {
	say "6. Hook and health check"
	if ((dry)); then
		note "WOULD run: omarchy-sl7-repo-ensure --provision-users, then sl7-doctor"
		return 0
	fi
	if command -v omarchy-sl7-repo-ensure >/dev/null 2>&1; then
		as_root omarchy-sl7-repo-ensure --provision-users
	else
		note "omarchy-sl7-repo-ensure not installed (the package step was skipped)"
	fi
	if command -v sl7-doctor >/dev/null 2>&1; then
		sl7-doctor || note "sl7-doctor reported failures (firmware missing etc. is independent of this repository)"
	fi
	note "Done. Reboot when linux-sl7 was upgraded. Future updates: omarchy update"
}

main() {
	while (($#)); do
		case $1 in
			--dry-run) dry=1 ;;
			--no-install) install=0 ;;
			--yes) yes=1 ;;
			--key-file) keyfile=${2:?--key-file needs a file}; shift ;;
			--no-hardware-check) hwcheck=0 ;;
			-h | --help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
			*) die "unknown option: $1" ;;
		esac
		shift
	done
	# curl | bash: stdin is the script; pacman's prompts and sudo need the terminal.
	if [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then exec </dev/tty; fi
	tmp=$(mktemp -d)
	trap cleanup EXIT
	((dry)) && say "DRY RUN: nothing will be changed"
	step_preflight
	step_key
	step_trust
	step_config
	step_install
	step_finish
}

main "$@"
