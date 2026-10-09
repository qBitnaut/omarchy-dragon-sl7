#!/usr/bin/env bash
# get-sl7-firmware.sh - prepare the Microsoft firmware extraction that
# make-install-usb.sh copies onto the installer stick.
#
# Runs on any Linux machine (x86_64 or arm64) and on macOS. Nothing is read from
# your Surface or from Windows: the firmware comes from Microsoft's public
# Surface Laptop 7 driver MSI (download id 106120).
#
#   1. download the MSI (resumable) or take one you already have (--msi FILE)
#   2. verify its sha256 against the pin used by omarchy-surface-sl7-firmware
#   3. extract it with msiextract (msitools)
#   4. write the layout make-install-usb.sh reads:
#        DIR/extracted/ProgramFiles64Folder/SurfaceUpdate/<package>/<file>
#        DIR/SHA256SUMS.extracted   (sha256sum format, paths as ./ProgramFiles64Folder/...)
#
# usage:
#   get-sl7-firmware.sh [--dir DIR] [--msi FILE] [--allow-unverified] [--force]
#
# DIR defaults to $SL7_MSI, else ./sl7-msi. Running it again is safe: a finished,
# verified extraction is left alone (--force redoes it) and a partial download resumes.
#
# The extracted files are Microsoft/Qualcomm firmware for your own device. Do not
# share, upload or commit them.

set -euo pipefail

prog=${0##*/}
# Known driver packages, newest first (same pins as
# pkgs/omarchy-surface-sl7/omarchy-surface-sl7-firmware). Microsoft replaces the
# MSI under download id 106120 from time to time and the old URL then returns
# 404; the firmware files this kit needs were identical in the packages below.
# Fields: version  sha256  file name
known_msis=(
	"26.091.9400.0 0917d206fb35278b4df4be980240318475300f3a130a86edac836519059a453d SurfaceLaptop7_ARM_Win11_26100_26.091.9400.0.msi"
	"26.053.36539.0 66b6e1ace7e5f01bc592cd4c9ae78aa30bbb0e04ab57491cd03ec2aaa6e1229b SurfaceLaptop7_ARM_Win11_26100_26.053.36539.0.msi"
)
msi_base_url="https://download.microsoft.com/download/b7ca2c3f-d320-4795-be0f-529a0117abb4"
msi_version="" # set to the matching known version once the MSI is verified

# sha256  path under SurfaceUpdate/ (required files, same list as the firmware package)
required=(
	"b526e365b644b019b4866d0eec9544de6aa61975a7ab7086af6ea4ee4f7ef8c7 qcdx8380/qcdxkmsuc8380.mbn"
	"3a0240f9a1c0c43b657959b1bf10433a1a9793eb5c4af9f6beff8644c174f5a0 proextadsp8380/qcadsp8380.mbn"
	"b03f066e2645dbe35a33a08a91312842f5cee3676cac3e111f1f3dabd1cf4e9e proextadsp8380/adsp_dtbs.elf"
	"4a67a03367f2eff2f8a0e867ca25d2bf2fcd5aee3e41e2c9f436c804e257c789 qcnspmcdmextcdsp8380/qccdsp8380.mbn"
	"93941f040da14b8305d39579686d886706d22954a538b03da676c1aaa191797f qcnspmcdmextcdsp8380/cdsp_dtbs.elf"
	"121d6864e5b8408f5c43d211f1634b59a6fb333c98c880cdbcd1bcb9f3c7e2f4 qcdx8380/qcvss8380.mbn"
)

fw_rel="ProgramFiles64Folder/SurfaceUpdate"

usage() {
	sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	cat <<USAGE

options:
  --dir DIR           output directory (default: \$SL7_MSI, else ./sl7-msi)
  --msi FILE          use this MSI instead of downloading it
  --allow-unverified  continue when the MSI sha256 differs from the pin (a newer
                      MSI). Not recommended: DSP firmware is signed and a wrong
                      file only fails at boot.
  --force             extract again even if DIR is already complete
  -h, --help          this text

Known MSIs (newest is downloaded first; an older one is tried if Microsoft
has removed the newer URL; either is accepted with --msi FILE):
USAGE
	local e v h n
	for e in "${known_msis[@]}"; do
		read -r v h n <<<"$e"
		echo "  $v  sha256 $h"
		echo "    $msi_base_url/$n"
	done
	cat <<USAGE

Microsoft replaces the driver MSI from time to time. If every URL above returns
404, download the current Surface Laptop 7 (Snapdragon) driver MSI by hand from
https://www.microsoft.com/download/details.aspx?id=106120 and pass it with
--msi FILE. It is accepted only if its sha256 matches a known one above;
otherwise this script stops, and --allow-unverified checks just the firmware
files below.
USAGE
}

die() {
	echo "$prog: $*" >&2
	exit 1
}
info() { echo "==> $*"; }

dir="${SL7_MSI:-./sl7-msi}"
msi=""
allow_unverified=0
force=0

while [ $# -gt 0 ]; do
	case "$1" in
	--dir) dir="${2:?--dir needs a directory}"; shift 2 ;;
	--msi) msi="${2:?--msi needs a file}"; shift 2 ;;
	--allow-unverified) allow_unverified=1; shift ;;
	--force) force=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) usage >&2; die "unknown argument: $1" ;;
	esac
done

hash_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		die "need sha256sum (coreutils) or shasum"
	fi
}

install_hint() {
	local id=""
	echo "msiextract not found. It is part of msitools:" >&2
	if [ "$(uname -s)" = Darwin ]; then
		echo "  brew install msitools" >&2
		return
	fi
	if [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		id="$(. /etc/os-release && echo "${ID:-} ${ID_LIKE:-}")"
	fi
	case " $id " in
	*" arch "* | *" manjaro "*) echo "  sudo pacman -S msitools" >&2 ;;
	*" debian "* | *" ubuntu "*) echo "  sudo apt install msitools" >&2 ;;
	*" fedora "* | *" rhel "* | *" centos "*) echo "  sudo dnf install msitools" >&2 ;;
	*" opensuse"* | *" suse "*) echo "  sudo zypper install msitools" >&2 ;;
	*" alpine "*) echo "  sudo apk add msitools" >&2 ;;
	*" nixos "*) echo "  nix-shell -p msitools" >&2 ;;
	*)
		echo "  Arch: sudo pacman -S msitools   Debian/Ubuntu: sudo apt install msitools" >&2
		echo "  Fedora: sudo dnf install msitools   macOS: brew install msitools" >&2
		;;
	esac
}

download() { # URL DEST: resumable, writes DEST.part then renames
	local url=$1 dest=$2 part
	part="$dest.part"
	if command -v curl >/dev/null 2>&1; then
		curl -fL --retry 3 -C - -o "$part" "$url" || { echo "    download failed (re-run to resume): $url" >&2; return 1; }
	elif command -v wget >/dev/null 2>&1; then
		wget -c -O "$part" "$url" || { echo "    download failed (re-run to resume): $url" >&2; return 1; }
	else
		die "need curl or wget to download the MSI (or pass --msi FILE)"
	fi
	mv "$part" "$dest"
}

command -v msiextract >/dev/null 2>&1 || {
	install_hint
	die "install msitools and run again"
}

mkdir -p "$dir"
dir="$(cd "$dir" && pwd)"
out="$dir/extracted"
sums="$dir/SHA256SUMS.extracted"
marker="$dir/MSI.sha256"

# ---------------------------------------------------------------- 1. the MSI
known_version() { # SHA256 -> prints the known version, fails if unknown
	local e v h n
	for e in "${known_msis[@]}"; do
		read -r v h n <<<"$e"
		if [ "$h" = "$1" ]; then
			echo "$v"
			return 0
		fi
	done
	return 1
}

if [ -z "$msi" ]; then
	for e in "${known_msis[@]}"; do
		read -r v h n <<<"$e"
		if [ -f "$dir/$n" ] && [ "$(hash_of "$dir/$n")" = "$h" ]; then
			msi="$dir/$n"
			info "MSI already downloaded and verified: $msi"
			break
		fi
	done
fi
if [ -z "$msi" ]; then
	for e in "${known_msis[@]}"; do
		read -r v h n <<<"$e"
		cand="$dir/$n"
		if [ -f "$cand" ]; then
			# A complete file with the wrong hash is not a partial download.
			mv "$cand" "$cand.part"
		fi
		info "Downloading $n (resumable; re-run if interrupted)"
		if download "$msi_base_url/$n" "$cand"; then
			msi="$cand"
			break
		fi
		echo "    not available (Microsoft may have replaced it); trying the next known package" >&2
	done
	[ -n "$msi" ] || die "no known MSI could be downloaded. Microsoft has probably replaced the package again. Download the current Surface Laptop 7 driver MSI from https://www.microsoft.com/download/details.aspx?id=106120 and run: $prog --msi FILE (it must match a sha256 listed by --help, or add --allow-unverified)."
elif [ ! -f "$msi" ]; then
	die "$msi not found"
fi

# ---------------------------------------------------------------- 2. verify
info "Verifying the MSI sha256"
got="$(hash_of "$msi")"
if msi_version="$(known_version "$got")"; then
	echo "    sha256 OK: $got (MSI $msi_version)"
elif [ "$allow_unverified" = 1 ]; then
	echo "    WARNING: sha256 $got matches no known MSI (see --help)" >&2
	echo "    WARNING: continuing because of --allow-unverified; the firmware files are still checked" >&2
else
	die "sha256 mismatch for $msi: got $got, which is none of the known MSIs (see --help). Delete the file and retry, or use --allow-unverified for a newer MSI."
fi

# ---------------------------------------------------------------- 3. extract
if [ "$force" = 0 ] && [ -f "$marker" ] && [ "$(cat "$marker")" = "$got" ] &&
	[ -d "$out/$fw_rel" ] && [ -s "$sums" ]; then
	info "Already extracted from this MSI: $out (use --force to redo)"
else
	tmp="$(mktemp -d "$dir/.extract.XXXXXX")"
	trap 'rm -rf "$tmp"' EXIT
	info "Extracting with msiextract"
	msiextract -C "$tmp" "$msi" >/dev/null || die "msiextract failed"
	found="$(find "$tmp" -type d -name SurfaceUpdate -print -quit)"
	[ -n "$found" ] || die "no SurfaceUpdate folder in the MSI; is this the Surface Laptop 7 driver package?"

	# Place SurfaceUpdate at the path make-install-usb.sh expects, whatever
	# directory names msiextract used above it.
	new="$dir/.extracted.new"
	rm -rf "$new"
	mkdir -p "$new/ProgramFiles64Folder"
	mv "$found" "$new/$fw_rel"
	rm -rf "$out"
	mv "$new" "$out"

	# ---------------------------------------------------------------- 4. checksums
	info "Writing SHA256SUMS.extracted"
	: >"$sums.new"
	(
		cd "$out"
		find "./$fw_rel" -type f | LC_ALL=C sort | while IFS= read -r f; do
			printf '%s  %s\n' "$(hash_of "$f")" "$f"
		done
	) >"$sums.new"
	mv "$sums.new" "$sums"
	echo "$got" >"$marker"
fi

# ---------------------------------------------------------------- check the result
info "Checking the firmware files the installer needs"
bad=0
for entry in "${required[@]}"; do
	read -r want rel <<<"$entry"
	f="$out/$fw_rel/$rel"
	if [ ! -f "$f" ]; then
		echo "    MISSING  $rel" >&2
		bad=1
	elif [ "$(hash_of "$f")" != "$want" ]; then
		echo "    DIFFERS  $rel (not the pinned file)" >&2
		[ "$allow_unverified" = 1 ] || bad=1
	else
		echo "    ok       $rel"
	fi
done
[ "$bad" = 0 ] || die "required firmware files are missing or differ from the pin; do not use this extraction"

echo
echo "Done. Extracted firmware: $out/$fw_rel"
echo "      Checksums:          $sums"
echo
echo "WARNING: these files are Microsoft/Qualcomm firmware for your own device."
echo "         Do not share, upload or commit them, or an image of a stick holding them."
echo
echo "Next, write the stick (SL7_MSI tells make-install-usb.sh where this is):"
echo "  SL7_MSI=\"$dir\" tools/installer-kit/make-install-usb.sh --device /dev/sdX --from-ci latest"
