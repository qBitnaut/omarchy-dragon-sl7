#!/usr/bin/env bash
# make-install-usb.sh - write the Surface Laptop 7 Omarchy installer stick
#
# Runs on the build host (x86_64 Arch is fine). Needs sudo only for the steps
# that touch a real device (dd, sfdisk, mkfs, mount).
#
#   1. take the installer ISO from the latest GitHub release (default, or
#      --from-release), a CI run (--from-ci) or a file (--iso) and verify its sha256
#   2. write it to a removable device (or an image file with --image)
#   3. relocate the backup GPT, add partition SL7DATA (FAT32, Microsoft basic
#      data) in the free space
#   4. copy firmware/ onto SL7DATA from the LOCAL MSI extraction (personal
#      stick only: the ISO has no firmware, and nothing here goes to git or CI)
#   5. verify, sync, unmount
#
# usage:
#   make-install-usb.sh --device /dev/sdX [--from-release] [--no-firmware]
#   make-install-usb.sh --device /dev/sdX --from-ci RUNID|latest [--no-firmware]
#   make-install-usb.sh --device /dev/sdX --iso FILE [--sha256 HEX] [--no-firmware]
#   make-install-usb.sh --image FILE --iso FILE [--size 8G] [--loop]   (test, no root)
#
# Work files live in $SL7_WORK (default: the research tree), never /tmp or the repo.

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESEARCH="${SL7_RESEARCH:-}"
WORK="${SL7_WORK:-${RESEARCH:+$RESEARCH/installer/work/kit}}"
WORK="${WORK:-$PWD/sl7-installer-work}"
MSI_ROOT="${SL7_MSI:-${RESEARCH:+$RESEARCH/msi}}"
MSI_ROOT="${MSI_ROOT:-$PWD/sl7-msi}"
FW_BASE="$MSI_ROOT/extracted/ProgramFiles64Folder/SurfaceUpdate"
GH_REPO="${SL7_REPO:-qBitnaut/omarchy-dragon-sl7}"
CI_WORKFLOW="installer-iso.yml"
CI_ARTIFACT="omarchy-sl7-installer-iso"
RELEASE_TAG="installer-latest"

# Microsoft basic data: the partition is only read by the installer's live system.
DATA_TYPE_GUID="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
DATA_LABEL="SL7DATA"
DATA_MIN_SECTORS=262144

DEVICE=""
IMAGE=""
IMAGE_SIZE=""
WITH_FW=1
USE_LOOP=0
FORCE_LARGE=0
ISO=""
ISO_SHA256=""
CI_RUN=""
FROM_RELEASE=0
LOOPDEV=""
MNT=""

# shared stick functions: die, info, as_root, cleanup, validate_device, write_iso,
# add_data_partition, wipe/unmount helpers, populate_*, stage_firmware
# shellcheck source=../lib/usb.sh
source "$KIT_DIR/../lib/usb.sh"

usage() {
	sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	cat <<'USAGE'

options:
  --device DEV     write to this removable device (asks you to type its path)
  --from-release   download the ISO of the "installer-latest" GitHub release
                   (the default when no ISO source is given) into $SL7_WORK/release;
                   needs curl and python3, no GitHub login
  --from-ci RUN    download the ISO of that installer-iso.yml run (run id, or
                   "latest" successful run) with gh into $SL7_WORK/ci
  --iso FILE       use this ISO; its sha256 comes from FILE.sha256 or --sha256
  --sha256 HEX     expected sha256 of the ISO (overrides FILE.sha256)
  --image FILE     write to an image file instead (test mode, no root needed)
  --size SIZE      image size for --image (default: ISO size + 512M)
  --loop           with --image: attach with losetup -P (needs root) and use the
                   same code path as a real device
  --no-firmware    do not copy Microsoft firmware onto SL7DATA
  --force-large    allow devices larger than 256 GB
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
	--device) DEVICE="${2:?--device needs a path}"; shift 2 ;;
	--image) IMAGE="${2:?--image needs a path}"; shift 2 ;;
	--size) IMAGE_SIZE="${2:?--size needs a value}"; shift 2 ;;
	--from-release) FROM_RELEASE=1; shift ;;
	--from-ci) CI_RUN="${2:?--from-ci needs a run id or latest}"; shift 2 ;;
	--iso) ISO="${2:?--iso needs a file}"; shift 2 ;;
	--sha256) ISO_SHA256="${2:?--sha256 needs a hex digest}"; shift 2 ;;
	--loop) USE_LOOP=1; shift ;;
	--no-firmware) WITH_FW=0; shift ;;
	--force-large) FORCE_LARGE=1; shift ;;
	-h | --help) usage; exit 0 ;;
	/dev/*) DEVICE="$1"; shift ;;
	*) usage >&2; die "unknown argument: $1" ;;
	esac
done

[ -n "$DEVICE" ] || [ -n "$IMAGE" ] || { usage >&2; die "give --device /dev/sdX or --image FILE"; }
[ -z "$DEVICE" ] || [ -z "$IMAGE" ] || die "use either --device or --image, not both"
if [ -z "$ISO" ] && [ -z "$CI_RUN" ]; then FROM_RELEASE=1; fi
n_src=$((FROM_RELEASE + (${#ISO} > 0 ? 1 : 0) + (${#CI_RUN} > 0 ? 1 : 0)))
[ "$n_src" = 1 ] || die "use only one of --from-release, --from-ci and --iso"
[ -z "$ISO" ] || ISO="$(realpath -e "$ISO")" || die "--iso: no such file"
[ "$USE_LOOP" = 0 ] || [ -n "$IMAGE" ] || die "--loop needs --image"
if [ -n "$ISO_SHA256" ] && ! [[ $ISO_SHA256 =~ ^[0-9a-fA-F]{64}$ ]]; then
	die "--sha256 must be 64 hex digits"
fi
REPO_ROOT="$(cd "$KIT_DIR/../.." && pwd)"
case "$WORK" in /tmp/* | "$REPO_ROOT"/*) die "work dir must not be under /tmp or the repo: $WORK" ;; esac

trap cleanup EXIT

check_tools() {
	local t missing=()
	[ "$FROM_RELEASE" = 0 ] || for t in curl python3; do
		command -v "$t" >/dev/null 2>&1 || missing+=("$t")
	done
	for t in sha256sum sfdisk mkfs.fat python3 blkid lsblk cmp find; do
		command -v "$t" >/dev/null 2>&1 || missing+=("$t")
	done
	if [ -n "$IMAGE" ] && [ "$USE_LOOP" = 0 ]; then
		for t in mcopy mdir; do
			command -v "$t" >/dev/null 2>&1 || missing+=("mtools")
		done
	fi
	[ -z "$CI_RUN" ] || command -v gh >/dev/null 2>&1 || missing+=(github-cli)
	if [ "$WITH_FW" = 1 ] && [ ! -d "$FW_BASE" ]; then
		echo "No firmware extraction at $FW_BASE" >&2
		echo "  Create it with: SL7_MSI=\"$MSI_ROOT\" $KIT_DIR/get-sl7-firmware.sh   (or pass --no-firmware)" >&2
		die "MSI extraction missing"
	fi
	if [ "${#missing[@]}" -gt 0 ]; then
		echo "Missing tools. Install with:" >&2
		echo "  sudo pacman -S --needed dosfstools mtools util-linux python github-cli" >&2
		die "missing: ${missing[*]}"
	fi
}

# ---------------------------------------------------------------- 1. the ISO
# The ISO is larger than GitHub's 2 GiB asset limit, so the release holds it in
# parts (NAME.iso.part-00, -01, ...) plus NAME.iso.sha256 and NAME.iso.parts.sha256.
fetch_release_iso() {
	local dest="$WORK/release" api list name url iso
	api="https://api.github.com/repos/$GH_REPO/releases/tags/$RELEASE_TAG"
	info "Looking up release $RELEASE_TAG of $GH_REPO"
	list="$(curl -fsSL --retry 3 "$api" | python3 -c '
import json, sys
for a in json.load(sys.stdin)["assets"]:
    print(a["name"], a["browser_download_url"])
')" || die "cannot read $api"
	[ -n "$list" ] || die "release $RELEASE_TAG has no assets"
	mkdir -p "$dest"
	while read -r name url; do
		case "$name" in
		*.iso.part-* | *.iso.sha256 | *.iso.parts.sha256 | *.iso.sha256.sig | omarchy-sl7.pub.asc)
			if [ ! -f "$dest/$name" ] || [[ $name == *.sha256* ]]; then
				info "Downloading $name"
				curl -fL --retry 3 -C - -o "$dest/$name" "$url" || die "download of $name failed"
			fi ;;
		*) ;;
		esac
	done <<<"$list"
	iso="$(find "$dest" -maxdepth 1 -name '*.iso.sha256' ! -name '*.parts.sha256' -print -quit)"
	[ -n "$iso" ] || die "release has no ISO checksum"
	iso="${iso%.sha256}"
	info "Checking the parts and reassembling $(basename "$iso")"
	(cd "$dest" && sha256sum -c --quiet "$(basename "$iso").parts.sha256") || die "a release part is corrupt: delete $dest and retry"
	cat "$iso".part-* >"$iso.tmp" && mv "$iso.tmp" "$iso"
	if [ -f "$iso.sha256.sig" ] && [ -f "$dest/omarchy-sl7.pub.asc" ] && command -v gpg >/dev/null 2>&1; then
		local gh
		gh="$(mktemp -d)"
		if GNUPGHOME="$gh" gpg --batch -q --import "$dest/omarchy-sl7.pub.asc" 2>/dev/null &&
			GNUPGHOME="$gh" gpg --batch --verify "$iso.sha256.sig" "$iso.sha256" 2>&1 | grep -q "Good signature"; then
			echo "    checksum signature OK"
		else
			rm -rf "$gh"
			die "the signature of $(basename "$iso").sha256 does not verify"
		fi
		rm -rf "$gh"
	fi
	ISO="$iso"
	CI_FETCHED_RUN="release $RELEASE_TAG"
}

fetch_ci_iso() {
	local run="$CI_RUN" concl dest found n
	if [ "$run" = latest ]; then
		run="$(gh run list -R "$GH_REPO" --workflow "$CI_WORKFLOW" --status success --limit 1 --json databaseId -q '.[0].databaseId' | grep -E '^[0-9]+$' | head -n 1 || true)"
		[ -n "$run" ] || die "no successful $CI_WORKFLOW run in $GH_REPO yet (check: gh run list --workflow $CI_WORKFLOW)"
	fi
	concl="$(gh run view "$run" -R "$GH_REPO" --json conclusion -q .conclusion | tail -n 1)" || die "gh run view $run failed (gh auth status?)"
	[ "$concl" = success ] || die "run $run has conclusion '${concl:-none}', not success"
	dest="$WORK/ci/$run"
	if [ ! -d "$dest" ] || [ -z "$(find "$dest" -name '*.iso' -print -quit)" ]; then
		info "Downloading artifact '$CI_ARTIFACT' of run $run"
		rm -rf "$dest"
		mkdir -p "$dest"
		gh run download "$run" -R "$GH_REPO" -n "$CI_ARTIFACT" -D "$dest" || die "gh run download failed (artifacts expire after 14 days)"
	else
		info "ISO of run $run already downloaded"
	fi
	found="$(find "$dest" -name '*.iso')"
	n="$(grep -c . <<<"$found" || true)"
	[ "$n" = 1 ] || die "expected exactly one ISO in $dest, found $n"
	ISO="$found"
	CI_FETCHED_RUN="$run"
}

verify_iso() {
	local want="$ISO_SHA256" got
	if [ -z "$want" ]; then
		[ -f "$ISO.sha256" ] || die "no checksum for $ISO: pass --sha256 HEX or create $ISO.sha256 (sha256sum FILE > FILE.sha256)"
		want="$(awk '{print $1; exit}' "$ISO.sha256")"
		[[ $want =~ ^[0-9a-fA-F]{64}$ ]] || die "$ISO.sha256 does not start with a sha256 digest"
	fi
	info "Verifying the ISO sha256"
	got="$(sha256sum "$ISO" | cut -d' ' -f1)"
	[ "$got" = "${want,,}" ] || die "sha256 mismatch for $ISO: got $got, expected ${want,,}"
	ISO_SHA256="$got"
	echo "    sha256 OK: $got"
}

# ---------------------------------------------------------------- 2. SL7DATA contents
write_readme() {
	cat >"$STAGE/README.txt" <<'RDM'
SL7DATA - Surface Laptop 7 Omarchy installer stick (omarchy-dragon-sl7)
========================================================================

The installer's live system mounts this partition read-only at boot
(sl7-firmware-stage.service) and passes firmware/ to qcom-firmware-extract, which
stages the files the device tree asks for (GPU zap shader, ADSP, CDSP) and the
installer copies them into the new system.

PRIVACY AND LICENSE
-------------------
camera/ holds Microsoft's camera tuning file from the same package. The installed
system builds the webcam's libcamera tuning from it at first boot and then deletes
this staged copy.

firmware/ contains Microsoft/Qualcomm firmware extracted from the Surface
driver package. It is for your personal use on your own device only. Do NOT
share, upload or copy this stick's firmware/ directory anywhere, and do not
make an image of this stick public.
RDM
}

stage_data() {
	STAGE="$WORK/sl7data-stage"
	rm -rf "$STAGE"
	mkdir -p "$STAGE"
	write_readme
	{
		echo "iso: $(basename "$ISO")"
		echo "iso sha256: $ISO_SHA256"
		echo "ci run: ${CI_FETCHED_RUN:-local file}"
		echo "firmware: $([ "$WITH_FW" = 1 ] && echo included || echo none)"
	} >"$STAGE/installer-info.txt"
	if [ "$WITH_FW" = 1 ]; then
		stage_firmware
	else
		info "--no-firmware: firmware/ not included (the installer will look for a Windows driver store)"
	fi
}

# ---------------------------------------------------------------- main
main() {
	local target pd iso_bytes
	check_tools
	mkdir -p "$WORK"
	[ -z "$CI_RUN" ] || fetch_ci_iso
	[ "$FROM_RELEASE" = 0 ] || fetch_release_iso
	verify_iso
	stage_data
	iso_bytes="$(stat -c %s "$ISO")"

	if [ -n "$DEVICE" ]; then
		target="$DEVICE"
		validate_device "$DEVICE"
	else
		target="$IMAGE"
		mkdir -p "$(dirname "$IMAGE")"
		rm -f "$IMAGE"
		truncate -s "${IMAGE_SIZE:-$((iso_bytes + 512 * 1024 * 1024))}" "$IMAGE"
	fi

	[ -z "$DEVICE" ] || wipe_old_signatures "$DEVICE"
	write_iso "$ISO" "$target"
	info "Verifying the written ISO against the file"
	as_root cmp -n "$iso_bytes" "$ISO" "$target" || die "the data written to $target differs from the ISO"
	echo "    $iso_bytes bytes identical"
	add_data_partition "$target"
	zero_data_region "$target" "$P_START" "$P_SIZE"

	if [ -n "$DEVICE" ]; then
		as_root partprobe "$DEVICE" 2>/dev/null || as_root blockdev --rereadpt "$DEVICE" 2>/dev/null || true
		as_root udevadm settle 2>/dev/null || true
		pd="$(partdev_of "$DEVICE" "$P_NUM")"
		populate_blockdev "$pd"
		lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$DEVICE"
	elif [ "$USE_LOOP" = 1 ]; then
		LOOPDEV="$(as_root losetup -Pf --show "$IMAGE")"
		as_root udevadm settle 2>/dev/null || true
		populate_blockdev "$(partdev_of "$LOOPDEV" "$P_NUM")"
		lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$LOOPDEV"
	else
		populate_image_offset "$IMAGE"
	fi
	sync

	echo
	if [ "$WITH_FW" = 1 ]; then
		echo "REMINDER: this stick holds Microsoft/Qualcomm firmware for your personal use."
		echo "          Do NOT share the stick, its firmware/ directory, or an image of it."
	fi
	if [ -n "$DEVICE" ]; then
		info "Installer stick ready: $DEVICE is unmounted and synced. Remove it, plug it into the SL7's USB-A port and follow tools/installer-kit/README.md."
	else
		info "Installer stick ready (test image): $IMAGE"
	fi
}

main
