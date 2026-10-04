#!/usr/bin/env bash
# make-recon-usb.sh - build the Surface Laptop 7 "recon USB kit"
#
# Runs on the build host (ramius, x86_64 Arch). Needs sudo only for the steps
# that touch a real device (dd, sfdisk, mkfs, mount).
#
#   1. download the dwhinham archlinux-sp11 aarch64 ISO (resumable), verify sha256
#   2. remaster it minimally: add /sl7-autostart.sh and script=/copytoram=n kernel options
#      to the loader entries (archiso runs it on the tty1 autologin); the UKI,
#      airootfs.sfs and boot records stay untouched
#   3. write it to a removable device (or an image file with --image)
#   4. add partition SL7DATA (FAT32) in the free space and populate it
#   5. optional (--kernel-artifacts / --from-ci): add the linux-sl7 test kernel as
#      extra boot entries; SL7DATA then gets the XBOOTLDR partition type
#
# usage:
#   make-recon-usb.sh --device /dev/sdX [--no-firmware]
#   make-recon-usb.sh --image FILE [--size 8G] [--no-firmware] [--loop]
#   make-recon-usb.sh --build-only
#   make-recon-usb.sh --device /dev/sdX --kernel-artifacts DIR [--iptsd-pkg FILE]
#   make-recon-usb.sh --device /dev/sdX --from-ci RUNID|latest [--iptsd-from-ci RUNID|latest]
#
# Work files live in $SL7_WORK (default: the research tree), never /tmp or the repo.

set -euo pipefail

ISO_NAME="archlinux-sp11-2026.09.26-aarch64.iso"
ISO_URL="https://github.com/dwhinham/archiso-aarch64-sp11/releases/download/2026-09-26/$ISO_NAME"
ISO_SHA256="388ebc2e59865329d6f0f09567a902976efb4002692353373d6d195facccb3bb"

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESEARCH="${SL7_RESEARCH:-/mnt/Rocket4/Quadrant/Personal/Research/omarchy-dragon-sl7}"
WORK="${SL7_WORK:-$RESEARCH/recon/work}"
MSI_ROOT="${SL7_MSI:-$RESEARCH/msi}"
FW_BASE="$MSI_ROOT/extracted/ProgramFiles64Folder/SurfaceUpdate"
LOCAL_TOOLS="$WORK/root"   # user-space extraction of pacman packages, used only as a fallback

DATA_TYPE_GUID="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
# systemd-boot reads entries and kernels only from the ESP and from a partition of
# this type; the ESP in the ISO has ~8 MB free, so the test kernel lives on SL7DATA.
XBOOTLDR_TYPE_GUID="BC13C2FF-59E6-4262-A352-B275FD6F7172"
DATA_LABEL="SL7DATA"
DATA_MIN_SECTORS=262144
GH_REPO="${SL7_REPO:-qBitnaut/omarchy-dragon-sl7}"

DEVICE=""
IMAGE=""
IMAGE_SIZE="8G"
WITH_FW=1
BUILD_ONLY=0
USE_LOOP=0
REBUILD=0
FORCE_LARGE=0
TEST_WIPE=0
KERNEL_DIR=""
IPTSD_PKG=""
CI_RUN=""
IPTSD_CI_RUN=""
KERNEL_MODE=0
LOOPDEV=""
MNT=""

die() {
	echo "ERROR: $*" >&2
	exit 1
}
info() { echo "==> $*"; }

usage() {
	sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	cat <<'USAGE'

options:
  --device DEV     write to this removable device (asks you to type its path)
  --image FILE     write to an image file instead (test mode, no root needed)
  --size SIZE      image size for --image (default 8G)
  --loop           with --image: attach with losetup -P (needs root) and use the
                   same code path as a real device
  --no-firmware    do not copy Microsoft firmware onto SL7DATA
  --build-only     download + remaster + stage only, write nothing
  --rebuild        redo the remaster even if the cached ISO is current
  --force-large    allow devices larger than 256 GB
  --test-wipe      with --image: pre-seed an old FAT at the SL7DATA offset and
                   check the wipe step removes it (no root needed)

test kernel (adds boot entries "omarchy-dragon-sl7 test kernel"; the sp11 entries stay):
  --kernel-artifacts DIR  CI artifact directory of linux-sl7-<sha> (linux-sl7 pkg,
                   Image, dtbs/, SHA256SUMS)
  --from-ci RUN    download that artifact with gh (run id, or "latest" successful run
                   of linux-sl7.yml) into $SL7_WORK/ci and use it
  --iptsd-pkg FILE iptsd-sl7 pkg.tar.{zst,xz}, staged for the touchpad test in the guide
  --iptsd-from-ci RUN  download the iptsd-sl7-aarch64 artifact (run id or "latest")
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
	--device) DEVICE="${2:?--device needs a path}"; shift 2 ;;
	--image) IMAGE="${2:?--image needs a path}"; shift 2 ;;
	--size) IMAGE_SIZE="${2:?--size needs a value}"; shift 2 ;;
	--loop) USE_LOOP=1; shift ;;
	--no-firmware) WITH_FW=0; shift ;;
	--build-only) BUILD_ONLY=1; shift ;;
	--rebuild) REBUILD=1; shift ;;
	--force-large) FORCE_LARGE=1; shift ;;
	--test-wipe) TEST_WIPE=1; shift ;;
	--kernel-artifacts) KERNEL_DIR="${2:?--kernel-artifacts needs a directory}"; shift 2 ;;
	--iptsd-pkg) IPTSD_PKG="${2:?--iptsd-pkg needs a file}"; shift 2 ;;
	--from-ci) CI_RUN="${2:?--from-ci needs a run id or latest}"; shift 2 ;;
	--iptsd-from-ci) IPTSD_CI_RUN="${2:?--iptsd-from-ci needs a run id or latest}"; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	/dev/*) DEVICE="$1"; shift ;;
	*) usage >&2; die "unknown argument: $1" ;;
	esac
done

if [ "$BUILD_ONLY" = 0 ] && [ -z "$DEVICE" ] && [ -z "$IMAGE" ]; then
	usage >&2
	die "give --device /dev/sdX, --image FILE or --build-only"
fi
[ -n "$DEVICE" ] && [ -n "$IMAGE" ] && die "use either --device or --image, not both"
[ "$TEST_WIPE" = 0 ] || [ -n "$IMAGE" ] || die "--test-wipe needs --image"
[ -z "$KERNEL_DIR" ] || [ -z "$CI_RUN" ] || die "use either --kernel-artifacts or --from-ci, not both"
[ -z "$IPTSD_PKG" ] || [ -z "$IPTSD_CI_RUN" ] || die "use either --iptsd-pkg or --iptsd-from-ci, not both"
if [ -n "$KERNEL_DIR$CI_RUN" ]; then
	KERNEL_MODE=1
	DATA_TYPE_GUID="$XBOOTLDR_TYPE_GUID"
	[ -z "$KERNEL_DIR" ] || KERNEL_DIR="$(realpath -e "$KERNEL_DIR")" || die "--kernel-artifacts: no such directory"
elif [ -n "$IPTSD_PKG$IPTSD_CI_RUN" ]; then
	die "--iptsd-pkg/--iptsd-from-ci only make sense together with --kernel-artifacts or --from-ci"
fi
[ -z "$IPTSD_PKG" ] || IPTSD_PKG="$(realpath -e "$IPTSD_PKG")" || die "--iptsd-pkg: no such file"
REPO_ROOT="$(cd "$KIT_DIR/../.." && pwd)"
case "$WORK" in /tmp/* | "$REPO_ROOT"/*) die "work dir must not be under /tmp or the repo: $WORK" ;; esac

# Image test mode (without --loop) never needs root.
as_root() {
	if [ "$(id -u)" = 0 ] || { [ -z "$DEVICE" ] && [ "$USE_LOOP" = 0 ]; }; then
		"$@"
	else
		sudo "$@"
	fi
}

cleanup() {
	if [ -n "$MNT" ] && mountpoint -q "$MNT" 2>/dev/null; then
		as_root umount "$MNT" 2>/dev/null || true
	fi
	[ -n "$MNT" ] && rmdir "$MNT" 2>/dev/null || true
	if [ -n "$LOOPDEV" ]; then
		as_root losetup -d "$LOOPDEV" 2>/dev/null || true
	fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- tools
# Use a system tool when present, else the user-space copy under $LOCAL_TOOLS.
need_tool() { # name package
	if command -v "$1" >/dev/null 2>&1; then
		return 0
	fi
	if [ -x "$LOCAL_TOOLS/usr/bin/$1" ]; then
		eval "$1() { LD_LIBRARY_PATH='$LOCAL_TOOLS/usr/lib' '$LOCAL_TOOLS/usr/bin/$1' \"\$@\"; }"
		return 0
	fi
	MISSING_PKGS+=("$2")
	return 1
}

check_tools() {
	MISSING_PKGS=()
	local t
	for t in curl sha256sum sfdisk mkfs.fat python3; do
		command -v "$t" >/dev/null 2>&1 || MISSING_PKGS+=("$t")
	done
	need_tool xorriso libisoburn || true
	need_tool mcopy mtools || true
	need_tool mtype mtools || true
	need_tool mdir mtools || true
	command -v blkid >/dev/null 2>&1 || MISSING_PKGS+=(util-linux)
	if [ "$KERNEL_MODE" = 1 ]; then
		for t in tar zstd xz cpio depmod; do
			command -v "$t" >/dev/null 2>&1 || MISSING_PKGS+=("$t")
		done
		need_tool unsquashfs squashfs-tools || true
		if [ -n "$CI_RUN$IPTSD_CI_RUN" ]; then
			command -v gh >/dev/null 2>&1 || MISSING_PKGS+=(github-cli)
		fi
	fi
	if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
		echo "Missing tools. Install with:" >&2
		echo "  sudo pacman -S --needed libisoburn dosfstools mtools util-linux curl python" >&2
		[ "$KERNEL_MODE" = 0 ] || echo "  (test kernel) sudo pacman -S --needed squashfs-tools zstd xz cpio kmod tar github-cli" >&2
		die "missing: ${MISSING_PKGS[*]}"
	fi
}

# ---------------------------------------------------------------- 1. download
download_iso() {
	local iso="$WORK/dl/$ISO_NAME" sum
	mkdir -p "$WORK/dl"
	if [ -f "$iso" ] && [ "$(sha256sum "$iso" | cut -d' ' -f1)" = "$ISO_SHA256" ]; then
		info "ISO already downloaded and verified"
		return 0
	fi
	info "Downloading $ISO_NAME (resumable)"
	curl -L -C - --fail --retry 5 --retry-delay 3 -o "$iso" "$ISO_URL" ||
		curl -L --fail --retry 5 -o "$iso" "$ISO_URL" ||
		die "download failed"
	info "Verifying sha256"
	sum="$(sha256sum "$iso" | cut -d' ' -f1)"
	if [ "$sum" != "$ISO_SHA256" ]; then
		mv -f "$iso" "$iso.bad"
		die "sha256 mismatch: got $sum, expected $ISO_SHA256 (file moved to $iso.bad)"
	fi
	info "sha256 OK"
}

# ---------------------------------------------------------------- 2. remaster
# The archiso initramfs honours script=<path> on the kernel command line: on the
# tty1 root autologin, /root/.zlogin runs .automated_script.sh, which copies that
# file to /tmp/startup_script and executes it. So the remaster is only:
#   - /sl7-autostart.sh added to the ISO9660 tree (mounted at /run/archiso/bootmnt)
#   - " copytoram=n script=..." appended to the options line of both systemd-boot loader entries
#     (in the ISO9660 tree and in the appended ESP partition)
# airootfs.sfs, airootfs.sha512, the kernel UKI (stubble + DTBs) and the initramfs
# stay byte-identical, so there is no checksum or signature to regenerate.
# copytoram=n keeps /run/archiso/bootmnt mounted: with the default copytoram=auto the
# initramfs copies the rootfs to RAM and unmounts the ISO partition before login,
# which would make the script= path vanish.
SCRIPT_PARAM="copytoram=n script=/run/archiso/bootmnt/sl7-autostart.sh"
# With SL7DATA typed XBOOTLDR, systemd-gpt-auto-generator would automount it at /boot,
# a second mount of the filesystem the autostart script mounts at /sl7. Turn it off.
[ "$KERNEL_MODE" = 0 ] || SCRIPT_PARAM="$SCRIPT_PARAM systemd.gpt_auto=0"
ENTRIES=(01-archiso-linux 02-archiso-speech-linux)

write_autostart() { # dest
	cat >"$1" <<'EOF'
#!/bin/sh
# SL7 recon kit launcher (added by make-recon-usb.sh), run by archiso's
# .automated_script.sh on the tty1 root autologin. Re-run any time:
#   sh /run/archiso/bootmnt/sl7-autostart.sh
MNT=/sl7
echo "SL7 recon kit: looking for the SL7DATA partition..."
udevadm settle 2>/dev/null
i=0
DEV=
while [ "$i" -lt 45 ]; do
	if [ -e /dev/disk/by-label/SL7DATA ]; then
		DEV="$(readlink -f /dev/disk/by-label/SL7DATA)"
		break
	fi
	i=$((i + 1))
	sleep 1
done
if [ -z "$DEV" ]; then
	cat <<MSG

SL7DATA partition not found.
 - Make sure the recon stick is still plugged in (the boot partition and
   SL7DATA are on the same stick), then run:
       sh /run/archiso/bootmnt/sl7-autostart.sh
 - Manual fallback:
       lsblk -o NAME,LABEL,SIZE
       mkdir -p /sl7 && mount /dev/<partition-labelled-SL7DATA> /sl7
       bash /sl7/sl7-guide.sh
MSG
	exit 1
fi
mkdir -p "$MNT"
# The hybrid ISO can make archiso mount the WHOLE disk (same iso9660 UUID on the disk
# and on partition 1; udev's by-uuid link is a race). A claimed disk makes the kernel
# refuse to open its partitions ("Can't open blockdev"), so fall back to a loop device
# over the partition's byte range on the parent disk (rw works, regions don't overlap).
sl7_mount() {
	mount -o rw "$1" "$MNT" 2>/dev/null && return 0
	b="${1##*/}"
	[ -r "/sys/class/block/$b/start" ] || return 1
	p="$(basename "$(readlink -f "/sys/class/block/$b/..")")"
	LDEV="$(losetup -f --show -o $(($(cat "/sys/class/block/$b/start") * 512)) \
		--sizelimit $(($(cat "/sys/class/block/$b/size") * 512)) "/dev/$p")" || return 1
	echo "(whole disk /dev/$p is claimed by archiso: using loop $LDEV for $1)"
	mount -o rw "$LDEV" "$MNT" || { losetup -d "$LDEV"; return 1; }
}
if ! mountpoint -q "$MNT"; then
	sl7_mount "$DEV" || {
		echo "Could not mount $DEV at $MNT (see dmesg)."
		exit 1
	}
fi
if [ ! -f "$MNT/sl7-guide.sh" ]; then
	echo "$MNT/sl7-guide.sh is missing from SL7DATA."
	exit 1
fi
bash "$MNT/sl7-guide.sh"
echo "Guide ended. To run it again: sh /run/archiso/bootmnt/sl7-autostart.sh   (finish with: poweroff)"
EOF
}

# part_geometry IMAGE NUM -> "start size" in sectors
part_geometry() {
	sfdisk -J "$1" 2>/dev/null | python3 -c '
import json, sys
p = json.load(sys.stdin)["partitiontable"]["partitions"][int(sys.argv[1]) - 1]
print(p["start"], p["size"])
' "$2"
}

remaster_iso() {
	local orig="$WORK/dl/$ISO_NAME" out="$WORK/sl7-recon-live.iso" rm_dir="$WORK/remaster"
	local esp="$WORK/remaster/esp.img" start size e want stamp
	REMASTERED_ISO="$out"

	mkdir -p "$rm_dir"
	write_autostart "$rm_dir/sl7-autostart.sh"
	want="$ISO_SHA256 $SCRIPT_PARAM $(sha256sum "$rm_dir/sl7-autostart.sh" | cut -d' ' -f1)"
	stamp="$WORK/remaster.stamp"
	if [ "$REBUILD" = 0 ] && [ -f "$out" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
		info "Remastered ISO is current: $out"
		return 0
	fi

	export MTOOLS_SKIP_CHECK=1
	info "Extracting the ESP (appended partition 2) and patching its loader entries"
	read -r start size <<<"$(part_geometry "$orig" 2)"
	dd if="$orig" of="$esp" bs=512 skip="$start" count="$size" status=none
	for e in "${ENTRIES[@]}"; do
		mtype -i "$esp" "::/loader/entries/$e.conf" | sed "/^options/ s#\$# $SCRIPT_PARAM#" >"$rm_dir/$e.conf"
		grep -q "$SCRIPT_PARAM" "$rm_dir/$e.conf" || die "could not patch $e.conf"
		mcopy -o -i "$esp" "$rm_dir/$e.conf" "::/loader/entries/$e.conf"
	done

	info "Rebuilding the ISO with xorriso (boot records replayed)"
	rm -f "$out"
	# -volume_date uuid keeps the iso9660 UUID that archisosearchuuid= on the cmdline matches.
	xorriso -indev "$orig" -outdev "$out" \
		-volume_date uuid 2026092611361300 \
		-boot_image any replay \
		-map "$rm_dir/sl7-autostart.sh" /sl7-autostart.sh \
		-map "$rm_dir/${ENTRIES[0]}.conf" "/loader/entries/${ENTRIES[0]}.conf" \
		-map "$rm_dir/${ENTRIES[1]}.conf" "/loader/entries/${ENTRIES[1]}.conf" \
		-append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$esp" \
		-commit >"$WORK/xorriso-rebuild.log" 2>&1 || {
		tail -n 20 "$WORK/xorriso-rebuild.log" >&2
		die "xorriso rebuild failed"
	}
	verify_remaster "$orig" "$out"
	echo "$want" >"$stamp"
}

esp_file_sum() { # image path-in-esp
	local start size
	read -r start size <<<"$(part_geometry "$1" 2)"
	mtype -i "$1@@$((start * 512))" "::$2" | sha256sum | cut -d' ' -f1
}

# The boot path must be untouched: same partition layout, UKI and initramfs
# bytes identical inside the ESP, same ISO UUID, entries differ only by script=.
verify_remaster() { # orig new
	local orig="$1" new="$2" lo ln so sn start size f e
	export MTOOLS_SKIP_CHECK=1
	info "Verifying boot records"
	lo="$(sfdisk -d "$orig" 2>/dev/null | grep -E 'start=' | sed -E 's/.*(type=[^,]*).*/\1/' | tr '\n' ' ')"
	ln="$(sfdisk -d "$new" 2>/dev/null | grep -E 'start=' | sed -E 's/.*(type=[^,]*).*/\1/' | tr '\n' ' ')"
	[ "$lo" = "$ln" ] || die "partition types differ: orig [$lo] new [$ln]"
	echo "    partition types identical: $ln"
	read -r start size <<<"$(part_geometry "$orig" 2)"
	so="$start $size"
	read -r start size <<<"$(part_geometry "$new" 2)"
	sn="$start $size"
	[ "${so#* }" = "${sn#* }" ] || die "ESP size changed ($so -> $sn)"
	for f in /arch/boot/aarch64/vmlinuz-linux-sp11 /arch/boot/aarch64/initramfs-linux-sp11.img /EFI/BOOT/BOOTAA64.EFI /shellaa64.efi; do
		so="$(esp_file_sum "$orig" "$f")"
		sn="$(esp_file_sum "$new" "$f")"
		[ "$so" = "$sn" ] || die "ESP file differs: $f"
	done
	echo "    ESP kernel UKI, initramfs and EFI binaries byte-identical"
	for e in "${ENTRIES[@]}"; do
		read -r start size <<<"$(part_geometry "$new" 2)"
		mtype -i "$new@@$((start * 512))" "::/loader/entries/$e.conf" | grep -q "$SCRIPT_PARAM" || die "entry $e not patched in the ESP"
	done
	echo "    loader entries patched with $SCRIPT_PARAM"
	{ xorriso -indev "$new" -lsl /sl7-autostart.sh -ls /boot/ 2>&1 | grep -E 'sl7-autostart|\.uuid' || true; } | sed 's/^/    /'
	{ xorriso -indev "$new" -report_el_torito as_mkisofs 2>&1 | grep -E "^-V|modification-date|-append_partition|^-e" || true; } | sed 's/^/    /'
}

# ---------------------------------------------------------------- stage SL7DATA
fw_copy() { # src-rel dst-rel
	local src="$FW_BASE/$1" dst="$STAGE/firmware/$2"
	[ -f "$src" ] || die "firmware source missing: $src (see $MSI_ROOT/FIRMWARE-INDEX.md)"
	mkdir -p "$(dirname "$dst")"
	cp "$src" "$dst"
}

stage_firmware() {
	local f r="qcom/x1e80100/microsoft/Romulus"
	[ -d "$FW_BASE" ] || die "MSI extraction not found at $FW_BASE (use --no-firmware to skip)"
	info "Staging firmware from the local MSI extraction"
	fw_copy qcdx8380/qcdxkmsuc8380.mbn qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn
	for f in qcadsp8380.mbn adsp_dtbs.elf adspr.jsn adsps.jsn adspua.jsn battmgr.jsn; do
		fw_copy "proextadsp8380/$f" "$r/$f"
	done
	for f in qccdsp8380.mbn cdsp_dtbs.elf cdspr.jsn; do
		fw_copy "qcnspmcdmextcdsp8380/$f" "$r/$f"
	done
	if [ -f "$MSI_ROOT/SHA256SUMS.extracted" ]; then
		(
			cd "$MSI_ROOT/extracted"
			for f in qcdx8380/qcdxkmsuc8380.mbn proextadsp8380/qcadsp8380.mbn proextadsp8380/adsp_dtbs.elf \
				qcnspmcdmextcdsp8380/qccdsp8380.mbn qcnspmcdmextcdsp8380/cdsp_dtbs.elf; do
				grep -F "./ProgramFiles64Folder/SurfaceUpdate/$f" "$MSI_ROOT/SHA256SUMS.extracted" | sha256sum -c --quiet - ||
					exit 1
			done
		) || die "firmware checksum mismatch against SHA256SUMS.extracted"
		echo "    firmware sha256 verified against SHA256SUMS.extracted"
	fi
	find "$STAGE/firmware" -type f | sed "s#^$STAGE/##" | sort | sed 's/^/    /'
}

write_readme() {
	cat >"$STAGE/README.txt" <<'EOF'
SL7DATA - Surface Laptop 7 recon stick (omarchy-dragon-sl7)
============================================================

This partition is mounted at /sl7 on the SL7 live system.

  sl7-guide.sh     the guided recon (starts automatically on tty1; re-run: sl7-start)
  sl7-recon.sh     read-only hardware report, called by the guide
  firmware/        OPTIONAL Microsoft/Qualcomm firmware, copied into RAM only
  results/         everything the guide collects (bring it back to ramius)

Boot the SL7 from this stick (Volume Down + power, or UEFI boot menu), stay on
AC power, and follow the on-screen steps. Finish with:  poweroff

PRIVACY AND LICENSE
-------------------
firmware/ contains Microsoft/Qualcomm firmware extracted from the Surface
driver package. It is for your personal use on your own device only. Do NOT
share, upload or copy this stick's firmware/ directory anywhere. results/ may
contain your serial number in results/*/private/ - do not publish it.
EOF
}

stage_data() {
	STAGE="$WORK/sl7data-stage"
	rm -rf "$STAGE"
	mkdir -p "$STAGE/results"
	[ -f "$KIT_DIR/sl7-guide.sh" ] || die "missing $KIT_DIR/sl7-guide.sh"
	[ -f "$KIT_DIR/../sl7-recon.sh" ] || die "missing $KIT_DIR/../sl7-recon.sh"
	cp "$KIT_DIR/sl7-guide.sh" "$STAGE/sl7-guide.sh"
	cp "$KIT_DIR/../sl7-recon.sh" "$STAGE/sl7-recon.sh"
	write_readme
	if [ "$WITH_FW" = 1 ]; then
		stage_firmware
	else
		info "--no-firmware: firmware/ not included"
	fi
	if [ "$KERNEL_MODE" = 1 ]; then
		stage_kernel
		# XBOOTLDR needs room for the staged kernel files plus headroom for results
		DATA_MIN_SECTORS=$(($(du -sk "$STAGE" | cut -f1) * 2 + 524288))
	fi
}

# ---------------------------------------------------------------- test kernel
# Design (see README "Test kernel"): the linux-sl7 files live on SL7DATA (retyped
# XBOOTLDR so systemd-boot reads loader/entries and kernels from it), because the ISO's
# ESP has only ~8 MB free. The sp11 entries on the ESP stay as control/fallback.
#   initramfs = sp11 archiso initramfs (hooks, busybox, udev: aarch64 binaries we cannot
#               build on x86) + a cpio overlay with OUR modules (depmod'ed) and the
#               zap shader + a late hook that puts both into the live root.
#   entry 1   = systemd-stub UKI: our Image + .dtbauto (romulus13/15) + .hwids
#   entry 2   = raw Image + explicit `devicetree` line (romulus13)
# Nothing here comes from or goes to git: firmware is read from the local SL7DATA stage.
KBUILD="$WORK/kernel-build"
UKI_TOOLS="$WORK/ukitools"

# fetch_ci RUN WORKFLOW PATTERN DEST: gh run download into DEST, sets CI_FETCHED_RUN
fetch_ci() {
	local run="$1" wf="$2" pat="$3" dest="$4" concl
	if [ "$run" = latest ]; then
		run="$(gh run list -R "$GH_REPO" --workflow "$wf" --status success --limit 1 --json databaseId -q '.[0].databaseId' | grep -E '^[0-9]+$' | head -n 1 || true)"
		[ -n "$run" ] || die "no successful $wf run in $GH_REPO yet (check: gh run list --workflow $wf)"
	fi
	concl="$(gh run view "$run" -R "$GH_REPO" --json conclusion -q .conclusion | tail -n 1)" || die "gh run view $run failed (gh auth status?)"
	[ "$concl" = success ] || die "run $run of $wf has conclusion '${concl:-none}', not success"
	info "Downloading artifact '$pat' of run $run ($wf)"
	rm -rf "$dest"
	mkdir -p "$dest"
	gh run download "$run" -R "$GH_REPO" --pattern "$pat" --dir "$dest" || die "gh run download failed (artifacts expire after 14 days)"
	CI_FETCHED_RUN="$run"
}

resolve_ci() {
	local d
	if [ -n "$CI_RUN" ]; then
		fetch_ci "$CI_RUN" linux-sl7.yml 'linux-sl7-*' "$WORK/ci/linux-sl7"
		KERNEL_CI_ID="$CI_FETCHED_RUN"
		d="$(find "$WORK/ci/linux-sl7" -name SHA256SUMS -printf '%h\n' | head -n 1)"
		[ -n "$d" ] || die "downloaded artifact has no SHA256SUMS"
		KERNEL_DIR="$d"
	fi
	if [ -n "$IPTSD_CI_RUN" ]; then
		fetch_ci "$IPTSD_CI_RUN" iptsd-sl7.yml 'iptsd-sl7-*' "$WORK/ci/iptsd-sl7"
		# ALARM's makepkg defaults to .pkg.tar.xz; accept either compression
		IPTSD_PKG="$(find "$WORK/ci/iptsd-sl7" \( -name '*.pkg.tar.zst' -o -name '*.pkg.tar.xz' \) | head -n 1)"
		[ -n "$IPTSD_PKG" ] || die "downloaded iptsd artifact has no pkg.tar.zst or pkg.tar.xz"
	fi
}

# ukify, the aarch64 systemd-stub, the romulus hwids and pefile come from the ISO's own
# live root (systemd >= 260), extracted once and cached.
extract_uki_tools() {
	local stamp="$WORK/ukitools.stamp" tmp_sfs="$WORK/dl/airootfs.sfs.tmp"
	if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$ISO_SHA256" ] && [ -x "$UKI_TOOLS/usr/bin/ukify" ]; then
		return 0
	fi
	info "Extracting ukify, systemd-stub and hwids from the ISO live root (once)"
	rm -rf "$UKI_TOOLS" "$tmp_sfs"
	xorriso -osirrox on -indev "$WORK/dl/$ISO_NAME" -extract /arch/aarch64/airootfs.sfs "$tmp_sfs" >"$WORK/xorriso-extract.log" 2>&1 ||
		die "could not extract airootfs.sfs (see $WORK/xorriso-extract.log)"
	# squashfs-tools >= 4.6 globs the extract names by default
	unsquashfs -no-progress -d "$UKI_TOOLS" "$tmp_sfs" \
		usr/lib/systemd/boot/efi/linuxaa64.efi.stub \
		'usr/lib/systemd/boot/hwids/aa64/x1e80100-microsoft-*.json' \
		usr/bin/ukify \
		'usr/lib/python3*/site-packages/pefile.py' \
		'usr/lib/python3*/site-packages/peutils.py' \
		'usr/lib/python3*/site-packages/ordlookup/*' >"$WORK/unsquashfs.log" 2>&1 ||
		{ rm -f "$tmp_sfs"; die "unsquashfs failed (see $WORK/unsquashfs.log)"; }
	rm -f "$tmp_sfs"
	[ -f "$UKI_TOOLS/usr/lib/systemd/boot/efi/linuxaa64.efi.stub" ] || die "aarch64 systemd-stub missing in the ISO"
	[ -x "$UKI_TOOLS/usr/bin/ukify" ] || die "ukify missing in the ISO"
	echo "$ISO_SHA256" >"$stamp"
}

# The late hook runs after archiso has mounted the live root at /sysroot and before
# switch_root. The initramfs only exists in RAM until then, so modules and firmware are
# handed over here. Modules go onto their own tmpfs (not the 256 MB cow overlay).
write_sl7test_hook() { # dest
	cat >"$1" <<'EOF'
#!/usr/bin/ash
# sl7test late hook (added by make-recon-usb.sh): linux-sl7 modules + zap shader into the live root.
run_latehook() {
	local ver fw
	ver="$(uname -r)"
	case "$ver" in *sl7*) ;; *) return 0 ;; esac
	msg ":: sl7test: handing modules and zap firmware for $ver to the live root"
	if [ -d "/usr/lib/modules/$ver" ]; then
		mkdir -p "/sysroot/usr/lib/modules/$ver"
		mount -t tmpfs -o size=2G,mode=0755 sl7modules "/sysroot/usr/lib/modules/$ver" &&
			cp -a "/usr/lib/modules/$ver/." "/sysroot/usr/lib/modules/$ver/" ||
			err "sl7test: could not copy modules into the live root"
	fi
	fw=qcom/x1e80100/microsoft
	if [ -d "/usr/lib/firmware/$fw" ]; then
		mkdir -p "/sysroot/usr/lib/firmware/$fw"
		cp -a "/usr/lib/firmware/$fw/." "/sysroot/usr/lib/firmware/$fw/" ||
			err "sl7test: could not copy firmware into the live root"
	fi
}
EOF
}

# Split the sp11 initramfs: an uncompressed early cpio (modules, firmware) followed by
# one xz-compressed cpio (init, hooks, busybox). Writes early.bin and main.cpio.
split_sp11_initramfs() { # src outdir
	python3 - "$1" "$2" <<'PYEND' || die "unexpected sp11 initramfs layout"
import sys
src, out = sys.argv[1:3]
d = open(src, "rb").read()
t = d.find(b"TRAILER!!!")
x = d.find(b"\xfd7zXZ\x00", t)
if t < 0 or x < 0 or x % 4:
    sys.exit("layout: no uncompressed cpio followed by an xz stream")
open(out + "/early.bin", "wb").write(d[:x])
open(out + "/main.xz", "wb").write(d[x:])
PYEND
	xz -dc "$2/main.xz" >"$2/main.cpio" || die "could not decompress the sp11 main initramfs"
	cpio -i --to-stdout config <"$2/main.cpio" 2>/dev/null | grep -q 'LATEHOOKS=' || die "sp11 initramfs has no /config with LATEHOOKS"
}

# build_kernel_boot: everything in $KBUILD, cached by an input stamp
build_kernel_boot() {
	local pkg ver kroot="$KBUILD/pkg" ov="$KBUILD/overlay" dm="$KBUILD/depmod" sp="$KBUILD/split"
	local want stamp="$KBUILD/stamp" zap="$STAGE/firmware/qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn" ukiopts f pysite

	pkg="$(find "$KERNEL_DIR" -maxdepth 1 -name 'linux-sl7-[0-9]*.pkg.tar.zst' | sort | head -n 1)"
	[ -n "$pkg" ] || die "no linux-sl7-<ver>.pkg.tar.zst in $KERNEL_DIR"
	[ "$(find "$KERNEL_DIR" -maxdepth 1 -name 'linux-sl7-[0-9]*.pkg.tar.zst' | wc -l)" = 1 ] || die "more than one linux-sl7 package in $KERNEL_DIR"
	for f in Image dtbs/x1e80100-microsoft-romulus13.dtb dtbs/x1e80100-microsoft-romulus15.dtb; do
		[ -s "$KERNEL_DIR/$f" ] || die "missing $KERNEL_DIR/$f"
	done
	ukiopts="$(sed -n 's/^options[[:space:]]*//p' "$WORK/remaster/${ENTRIES[0]}.conf")"
	[ -n "$ukiopts" ] || die "no options line in the remastered ${ENTRIES[0]}.conf"
	KERNEL_OPTS="$ukiopts"

	mkdir -p "$KBUILD"
	extract_uki_tools
	want="$(
		sha256sum "$pkg" "$KERNEL_DIR/Image" "$KERNEL_DIR"/dtbs/*.dtb | cut -d' ' -f1
		echo "$ISO_SHA256 $ukiopts"
		if [ -f "$zap" ]; then sha256sum "$zap" | cut -d' ' -f1; fi
		write_sl7test_hook /dev/stdout | sha256sum | cut -d' ' -f1
		sha256sum "${BASH_SOURCE[0]}" | cut -d' ' -f1
	)"
	want="$(echo "$want" | sha256sum | cut -d' ' -f1)"
	if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ] && [ -s "$KBUILD/omarchy-dragon-sl7.efi" ] &&
		[ -s "$KBUILD/initramfs-sl7-archiso.img" ] && [ -f "$KBUILD/version" ]; then
		info "Test-kernel boot files are current ($(cat "$KBUILD/version"))"
		return 0
	fi
	rm -f "$stamp"

	info "Unpacking $(basename "$pkg")"
	rm -rf "$kroot" "$ov" "$dm" "$sp"
	mkdir -p "$kroot" "$ov/usr/lib/modules" "$dm" "$sp"
	tar --zstd -xf "$pkg" -C "$kroot" usr/lib/modules || die "could not unpack $pkg"
	ver="$(find "$kroot/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')"
	{ [ -n "$ver" ] && [ "$(echo "$ver" | wc -l)" = 1 ]; } || die "expected exactly one usr/lib/modules/<ver> in the package"
	case "$ver" in *sl7*) ;; *) die "kernel release '$ver' lacks 'sl7' (the guide detects our kernel by it)" ;; esac
	[ -s "$kroot/usr/lib/modules/$ver/vmlinuz" ] || die "package has no vmlinuz"
	if ! cmp -s "$kroot/usr/lib/modules/$ver/vmlinuz" "$KERNEL_DIR/Image"; then
		echo "    WARNING: artifact Image differs from the package's vmlinuz"
	fi

	info "Building the module overlay for $ver (zstd, depmod)"
	cp -a "$kroot/usr/lib/modules/$ver" "$ov/usr/lib/modules/"
	rm -rf "$ov/usr/lib/modules/$ver"/{dtbs,build,vmlinuz,pkgbase}
	find "$ov/usr/lib/modules/$ver" -name '*.ko' -print0 | xargs -0 -r -P "$(nproc)" -n 32 zstd -q -10 --rm
	ln -s "$ov/usr/lib" "$dm/lib"
	depmod -b "$dm" "$ver" || die "depmod failed"
	[ -s "$ov/usr/lib/modules/$ver/modules.dep.bin" ] || die "depmod produced no modules.dep.bin"
	echo "    modules: $(find "$ov/usr/lib/modules/$ver" -name '*.ko.zst' | wc -l), $(du -sh "$ov/usr/lib/modules/$ver" | cut -f1) compressed"
	if [ -f "$zap" ]; then
		mkdir -p "$ov/usr/lib/firmware/qcom/x1e80100/microsoft"
		cp "$zap" "$ov/usr/lib/firmware/qcom/x1e80100/microsoft/"
		echo "    zap shader qcdxkmsuc8380.mbn included (initramfs only, never in git/CI)"
	else
		echo "    NOTE: no zap shader staged (--no-firmware?): the GPU will report -2 as on the sp11 kernel"
	fi

	info "Assembling the initramfs (sp11 archiso initramfs + overlay + late hook)"
	mcopy -n -i "$WORK/remaster/esp.img" ::/arch/boot/aarch64/initramfs-linux-sp11.img "$sp/initramfs-sp11.img" || die "could not read the sp11 initramfs from the ESP"
	split_sp11_initramfs "$sp/initramfs-sp11.img" "$sp"
	(cd "$ov" && find usr -print | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet) >"$sp/overlay.cpio"
	mkdir -p "$sp/hook/hooks"
	cpio -i --to-stdout config <"$sp/main.cpio" 2>/dev/null |
		sed 's/^LATEHOOKS="\(.*\)"/LATEHOOKS="\1 sl7test"/' >"$sp/hook/config"
	grep -q 'LATEHOOKS=".* sl7test"' "$sp/hook/config" || die "could not extend LATEHOOKS in the initramfs /config"
	write_sl7test_hook "$sp/hook/hooks/sl7test"
	chmod 0644 "$sp/hook/config"
	chmod 0755 "$sp/hook/hooks/sl7test" "$sp/hook/hooks" "$sp/hook"
	(cd "$sp/hook" && printf '%s\n' config hooks hooks/sl7test | cpio -o -H newc -R 0:0 --quiet) >"$sp/hook.cpio"
	# Same shape as the original (plain cpio first, then one xz member). The hook cpio is
	# appended inside the xz member, after the original main cpio, so its /config wins.
	cat "$sp/main.cpio" "$sp/hook.cpio" | xz --check=crc32 -6 -T0 >"$sp/main2.xz"
	cat "$sp/early.bin" "$sp/overlay.cpio" "$sp/main2.xz" >"$KBUILD/initramfs-sl7-archiso.img"
	echo "    initramfs-sl7-archiso.img: $(du -h "$KBUILD/initramfs-sl7-archiso.img" | cut -f1)"

	info "Building the UKI (systemd-stub, .dtbauto romulus13/15, .hwids)"
	printf 'NAME="omarchy-dragon-sl7"\nPRETTY_NAME="omarchy-dragon-sl7 test kernel"\nID=sl7test\n' >"$sp/os-release"
	pysite="$(find "$UKI_TOOLS/usr/lib" -maxdepth 2 -type d -name site-packages | head -n 1)"
	PYTHONPATH="$pysite" python3 "$UKI_TOOLS/usr/bin/ukify" build \
		--stub="$UKI_TOOLS/usr/lib/systemd/boot/efi/linuxaa64.efi.stub" \
		--linux="$KERNEL_DIR/Image" \
		--uname="$ver" \
		--os-release="@$sp/os-release" \
		--cmdline="$ukiopts" \
		--hwids="$UKI_TOOLS/usr/lib/systemd/boot/hwids/aa64" \
		--devicetree-auto="$KERNEL_DIR/dtbs/x1e80100-microsoft-romulus13.dtb" \
		--devicetree-auto="$KERNEL_DIR/dtbs/x1e80100-microsoft-romulus15.dtb" \
		--output="$KBUILD/omarchy-dragon-sl7.efi" >"$KBUILD/ukify.log" 2>&1 || {
		tail -n 20 "$KBUILD/ukify.log" >&2
		die "ukify failed"
	}
	PYTHONPATH="$pysite" python3 "$UKI_TOOLS/usr/bin/ukify" inspect "$KBUILD/omarchy-dragon-sl7.efi" >"$KBUILD/uki-sections.txt" 2>&1 || true
	[ "$(grep -c '^\.dtbauto:' "$KBUILD/uki-sections.txt")" = 2 ] || die "UKI does not have exactly two .dtbauto sections (see $KBUILD/uki-sections.txt)"
	grep -q '^\.hwids:' "$KBUILD/uki-sections.txt" || die "UKI has no .hwids section"
	echo "    UKI: $(du -h "$KBUILD/omarchy-dragon-sl7.efi" | cut -f1), 2 x .dtbauto, .hwids present"

	echo "$ver" >"$KBUILD/version"
	echo "$want" >"$stamp"
}

write_boot_entries() { # ver
	local ver="$1" e="$STAGE/loader/entries"
	mkdir -p "$e"
	cat >"$e/20-omarchy-dragon-sl7.conf" <<EOF
title    omarchy-dragon-sl7 test kernel
sort-key 20
version  $ver
linux    /sl7boot/omarchy-dragon-sl7.efi
initrd   /sl7boot/initramfs-sl7-archiso.img
options  $KERNEL_OPTS
EOF
	cat >"$e/21-omarchy-dragon-sl7-devicetree.conf" <<EOF
title    omarchy-dragon-sl7 test kernel (explicit romulus13 devicetree, no UKI)
sort-key 21
version  $ver
linux    /sl7boot/Image
initrd   /sl7boot/initramfs-sl7-archiso.img
devicetree /sl7boot/x1e80100-microsoft-romulus13.dtb
options  $KERNEL_OPTS
EOF
}

stage_kernel() {
	local kd="$KERNEL_DIR" ver f
	info "Staging the linux-sl7 test kernel from $kd"
	[ -f "$kd/SHA256SUMS" ] || die "$kd/SHA256SUMS missing"
	(cd "$kd" && sha256sum -c --quiet SHA256SUMS) || die "artifact checksum mismatch in $kd"
	echo "    artifact SHA256SUMS verified"
	if [ -n "$(find "$kd" -maxdepth 3 \( -name '*.mbn' -o -name '*_dtbs.elf' -o -name '*.jsn' \) -print -quit)" ]; then
		die "firmware files found in the artifacts: refusing (firmware must only come from the local stage)"
	fi
	build_kernel_boot
	ver="$(cat "$KBUILD/version")"
	mkdir -p "$STAGE/sl7boot" "$STAGE/sl7test"
	cp "$KBUILD/omarchy-dragon-sl7.efi" "$KBUILD/initramfs-sl7-archiso.img" "$STAGE/sl7boot/"
	cp "$kd/Image" "$STAGE/sl7boot/Image"
	cp "$kd/dtbs/x1e80100-microsoft-romulus13.dtb" "$kd/dtbs/x1e80100-microsoft-romulus15.dtb" "$STAGE/sl7boot/"
	write_boot_entries "$ver"
	if [ -n "$IPTSD_PKG" ]; then
		# GNU tar detects the compression on read. List once, then search:
		# `tar | grep -q` under pipefail fails when grep exits early (SIGPIPE).
		local ilist
		ilist="$(tar -tf "$IPTSD_PKG")" || die "cannot list $IPTSD_PKG"
		grep -qx 'usr/bin/iptsd' <<<"$ilist" || die "$IPTSD_PKG does not contain usr/bin/iptsd"
		if grep -qE '\.(mbn|jsn)$|_dtbs\.elf$' <<<"$ilist"; then die "firmware inside $IPTSD_PKG"; fi
		# the guide expects a zstd package; recompress an .xz one when staging
		case "$IPTSD_PKG" in
		*.pkg.tar.xz) xz -dc "$IPTSD_PKG" | zstd -q -o "$STAGE/sl7test/iptsd-sl7.pkg.tar.zst" ;;
		*) cp "$IPTSD_PKG" "$STAGE/sl7test/iptsd-sl7.pkg.tar.zst" ;;
		esac
	else
		echo "    no --iptsd-pkg: the guide will skip the touchpad (iptsd) test"
	fi
	{
		echo "kernel release: $ver"
		echo "ci run: ${KERNEL_CI_ID:-local artifact directory}"
		echo "iptsd pkg: ${IPTSD_PKG:+$(basename "$IPTSD_PKG")}"
		(cd "$kd" && grep -E ' \./(Image|linux-sl7-[0-9]|dtbs/)' SHA256SUMS)
	} >"$STAGE/sl7test/kernel-info.txt"
	cat >>"$STAGE/README.txt" <<EOF

TEST KERNEL ($ver)
------------------
This partition is typed XBOOTLDR so systemd-boot lists the entries in loader/entries:
  "omarchy-dragon-sl7 test kernel"                    UKI, device tree chosen from SMBIOS (.hwids)
  "omarchy-dragon-sl7 test kernel (explicit ...)"     raw Image + devicetree romulus13
The archlinux-sp11 entries stay as control. sl7boot/ holds the kernel, initramfs and DTBs,
sl7test/ the iptsd package and kernel-info.txt. The guide adds the sl7 checks automatically
when the running kernel is ours.
EOF
	echo "    boot entries:"
	grep -H '^title' "$STAGE"/loader/entries/*.conf | sed 's#^.*/#        #'
	for f in sl7boot/omarchy-dragon-sl7.efi sl7boot/initramfs-sl7-archiso.img sl7boot/Image; do
		echo "    $f: $(du -h "$STAGE/$f" | cut -f1)"
	done
}

# ---------------------------------------------------------------- 3. write
validate_device() {
	local dev="$1" type tran rm size mp mounts sys=0 bytes
	[ -b "$dev" ] || die "$dev is not a block device"
	type="$(lsblk -dno TYPE "$dev")"
	[ "$type" = disk ] || die "$dev is type '$type', need a whole disk (not a partition)"
	tran="$(lsblk -dno TRAN "$dev" | tr -d ' ')"
	rm="$(lsblk -dno RM "$dev" | tr -d ' ')"
	if [ "$tran" != usb ] && [ "$rm" != 1 ]; then
		die "$dev is not removable/USB (TRAN='$tran' RM='$rm'). Refusing."
	fi
	mounts="$(lsblk -nro MOUNTPOINTS "$dev" | sed '/^$/d')"
	while IFS= read -r mp; do
		[ -z "$mp" ] && continue
		case "$mp" in / | /boot | /boot/* | /efi | /efi/* | /home | /usr | /var | /etc | '[SWAP]') sys=1 ;; esac
	done <<<"$mounts"
	[ "$sys" = 0 ] || die "$dev holds a system mount point (/, /boot, ...). Refusing."
	bytes="$(lsblk -bdno SIZE "$dev")"
	[ "$bytes" -ge $((4 * 1024 * 1024 * 1024)) ] || die "$dev is smaller than 4 GiB"
	if [ "$bytes" -gt $((256 * 1024 * 1024 * 1024)) ] && [ "$FORCE_LARGE" = 0 ]; then
		die "$dev is larger than 256 GB; pass --force-large if you are sure"
	fi
	size="$(lsblk -dno SIZE "$dev")"
	echo
	lsblk -o NAME,MODEL,SIZE,TRAN,RM,FSTYPE,LABEL,MOUNTPOINTS "$dev"
	echo
	echo "ALL DATA ON $dev ($(lsblk -dno MODEL "$dev" | sed 's/ *$//'), $size) WILL BE ERASED."
	local ans
	read -r -p "Type the device path ($dev) to confirm: " ans
	[ "$ans" = "$dev" ] || die "confirmation did not match; nothing written"
	if [ -n "$mounts" ]; then
		info "Unmounting partitions of $dev"
		while IFS= read -r mp; do
			[ -n "$mp" ] && as_root umount "$mp"
		done <<<"$mounts"
	fi
}

write_iso() { # iso target
	if [ -n "$DEVICE" ]; then
		info "Writing ISO to $DEVICE"
		as_root dd if="$1" of="$2" bs=4M conv=fsync oflag=direct status=progress
	else
		info "Writing ISO to image file $2"
		dd if="$1" of="$2" bs=4M conv=fsync,notrunc status=progress
	fi
	sync
}

# part_info TARGET -> sets P_NUM P_START P_SIZE for the partition named SL7DATA
part_info() {
	local out
	out="$(as_root sfdisk -J "$1" 2>/dev/null | python3 -c '
import json, sys
t = json.load(sys.stdin)["partitiontable"]
for i, p in enumerate(t["partitions"], 1):
    if p.get("name") == "SL7DATA":
        print(i, p["start"], p["size"])
')"
	[ -n "$out" ] || die "partition $DATA_LABEL not found after partitioning"
	read -r P_NUM P_START P_SIZE <<<"$out"
}

add_data_partition() { # target
	local t="$1" total
	info "Relocating the backup GPT to the end of the device"
	as_root sfdisk --relocate gpt-bak-std "$t" >/dev/null 2>&1 || true
	info "Adding partition $DATA_LABEL in the remaining space"
	echo "type=$DATA_TYPE_GUID, name=$DATA_LABEL" | as_root sfdisk --append --no-reread --no-tell-kernel "$t" >/dev/null
	part_info "$t"
	total="$(as_root sfdisk -J "$t" 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["partitiontable"]["partitions"]))')"
	echo "    partitions on target: $total; $DATA_LABEL is #$P_NUM start=${P_START}s size=$((P_SIZE / 2048)) MiB"
	[ "$P_SIZE" -ge "$DATA_MIN_SECTORS" ] || die "less than $((DATA_MIN_SECTORS / 2048)) MiB free after the ISO; use a larger stick (or --size)"
	as_root sfdisk -V "$t" 2>&1 | sed 's/^/    /' || true
}

partdev_of() { # parent-device number
	case "$1" in
	*[0-9]) echo "${1}p$2" ;;
	*) echo "${1}$2" ;;
	esac
}

wait_for_node() { # path
	local i
	for ((i = 0; i < 30; i++)); do
		[ -b "$1" ] && return 0
		sleep 1
	done
	die "partition node $1 did not appear"
}

# Partition device nodes (not the disk itself) of a whole-disk device.
parts_of() { # parent-device
	lsblk -lnpo NAME,TYPE "$1" 2>/dev/null | awk '$2 == "part" { print $1 }'
}

# Unmount anything mounted from the target's partitions (desktop automounters
# such as udisks2 grab a fresh FAT the moment it appears). Loops until findmnt
# shows nothing; udisksctl as the user when available, else umount via sudo.
unmount_target_parts() { # parent-device
	local dev="$1" i p mp left
	for ((i = 0; i < 15; i++)); do
		left=0
		for p in $(parts_of "$dev"); do
			while IFS= read -r mp; do
				[ -n "$mp" ] || continue
				left=1
				mp="$(printf '%b' "$mp")"
				info "Unmounting $p ($mp)"
				if [ "$(id -u)" != 0 ] && command -v udisksctl >/dev/null 2>&1 &&
					udisksctl unmount -b "$p" >/dev/null 2>&1; then
					:
				else
					as_root umount "$p" >/dev/null 2>&1 || as_root umount "$mp" >/dev/null 2>&1 || true
				fi
			done < <(findmnt -rno TARGET -S "$p" 2>/dev/null || true)
		done
		[ "$left" = 0 ] && return 0
		sleep 1
	done
	die "could not unmount all partitions of $dev"
}

# Erase filesystem signatures of the old partitions (must be unmounted) and of
# the disk itself, before the ISO is written over them.
wipe_old_signatures() { # device
	local dev="$1" p
	unmount_target_parts "$dev"
	for p in $(parts_of "$dev"); do
		info "Wiping signatures on old partition $p"
		as_root wipefs -a "$p" >/dev/null
	done
	info "Wiping signatures on $dev"
	as_root wipefs -a "$dev" >/dev/null
	as_root udevadm settle 2>/dev/null || true
	unmount_target_parts "$dev"
}

# Zero the start of the new data partition region. dd of a hybrid ISO then an
# appended partition at the same offset as an earlier build leaves the old
# SL7DATA FAT intact there, which automounters mount as soon as the table is
# re-read. Run after partitioning, before the kernel re-reads the table.
zero_data_region() { # target start-sector size-sectors
	local t="$1" start="$2" size="$3" count=16384
	[ "$size" -ge "$count" ] || count="$size"
	info "Zeroing the first $((count / 2048)) MiB of the $DATA_LABEL region (sector $start)"
	as_root dd if=/dev/zero of="$t" bs=512 seek="$start" count="$count" conv=fsync,notrunc status=none
	sync
	if as_root blkid -p -O $((start * 512)) "$t" >/dev/null 2>&1; then
		die "a filesystem signature survives at offset $((start * 512)) on $t"
	fi
	echo "    no signature left at offset $((start * 512))"
}

# --test-wipe (image mode): plant an old FAT where partition 3 starts.
seed_old_fat() { # image start size
	info "Test: pre-seeding an old FAT signature at the $DATA_LABEL offset"
	mkfs.fat -F 32 -n OLDDATA --offset "$2" "$1" $(($3 / 2)) >/dev/null
	blkid -p -O $(($2 * 512)) "$1" >/dev/null 2>&1 || die "test: seeded FAT not detected"
	echo "    old FAT present: $(blkid -p -O $(($2 * 512)) -o value -s LABEL "$1")"
}

populate_blockdev() { # partition-device
	local pd="$1" parent
	wait_for_node "$pd"
	parent="/dev/$(basename "$(readlink -f "/sys/class/block/${pd##*/}/..")")"
	unmount_target_parts "$parent"
	info "Formatting $pd as FAT32 ($DATA_LABEL)"
	as_root mkfs.fat -F 32 -n "$DATA_LABEL" "$pd" >/dev/null
	as_root udevadm settle 2>/dev/null || true
	# the new filesystem raises a udev event: the automounter may grab it again
	unmount_target_parts "$parent"
	MNT="$(mktemp -d "$WORK/mnt.XXXXXX")"
	as_root mount -o "uid=$(id -u),gid=$(id -g),umask=022" "$pd" "$MNT"
	info "Populating $DATA_LABEL"
	cp -r "$STAGE"/. "$MNT"/
	sync
	echo "    contents:"
	(cd "$MNT" && find . -type f | sort | sed 's/^/    /')
	if [ "$KERNEL_MODE" = 1 ]; then
		local f
		for f in sl7boot/omarchy-dragon-sl7.efi sl7boot/initramfs-sl7-archiso.img sl7boot/Image loader/entries/20-omarchy-dragon-sl7.conf; do
			[ "$(sha256sum <"$MNT/$f" | cut -d' ' -f1)" = "$(sha256sum <"$STAGE/$f" | cut -d' ' -f1)" ] || die "verification failed: $f differs on $pd"
		done
		echo "    test-kernel files verified on the stick"
	fi
	as_root umount "$MNT"
	rmdir "$MNT"
	MNT=""
	as_root udevadm settle 2>/dev/null || true
	unmount_target_parts "$parent"
	info "Verification"
	as_root blkid -s LABEL -s TYPE "$pd"
}

populate_image_offset() { # image
	local img="$1" off blocks lbl
	off=$((P_START * 512))
	blocks=$((P_SIZE / 2))
	info "Formatting $DATA_LABEL inside the image (offset $off)"
	mkfs.fat -F 32 -n "$DATA_LABEL" --offset "$P_START" "$img" "$blocks" >/dev/null
	info "Populating $DATA_LABEL (mtools)"
	export MTOOLS_SKIP_CHECK=1
	(cd "$STAGE" && mcopy -s -m -Q -i "$img@@$off" ./* ::) || die "mcopy failed"
	echo "    contents:"
	mdir -/ -b -i "$img@@$off" :: | sed 's/^/    /'
	info "Verification"
	lbl="$(blkid -p -O "$off" -o value -s LABEL "$img")"
	echo "    blkid LABEL at offset $off: $lbl"
	[ "$lbl" = "$DATA_LABEL" ] || die "label verification failed"
	if [ "$KERNEL_MODE" = 1 ]; then
		local f
		for f in sl7boot/omarchy-dragon-sl7.efi sl7boot/initramfs-sl7-archiso.img sl7boot/Image loader/entries/20-omarchy-dragon-sl7.conf loader/entries/21-omarchy-dragon-sl7-devicetree.conf; do
			[ "$(mcopy -n -i "$img@@$off" "::/$f" - | sha256sum | cut -d' ' -f1)" = "$(sha256sum <"$STAGE/$f" | cut -d' ' -f1)" ] || die "verification failed: $f differs in the image"
		done
		echo "    test-kernel files verified in the image"
	fi
	blkid -p -O "$off" "$img" | sed 's/^/    /'
}

# ---------------------------------------------------------------- main
main() {
	local target pd
	check_tools
	mkdir -p "$WORK"
	[ "$KERNEL_MODE" = 0 ] || resolve_ci
	download_iso
	remaster_iso
	stage_data

	if [ "$BUILD_ONLY" = 1 ]; then
		info "Build only: remastered ISO at $REMASTERED_ISO"
		return 0
	fi

	if [ -n "$DEVICE" ]; then
		target="$DEVICE"
		validate_device "$DEVICE"
	else
		target="$IMAGE"
		mkdir -p "$(dirname "$IMAGE")"
		rm -f "$IMAGE"
		truncate -s "$IMAGE_SIZE" "$IMAGE"
	fi

	[ -z "$DEVICE" ] || wipe_old_signatures "$DEVICE"
	write_iso "$REMASTERED_ISO" "$target"
	add_data_partition "$target"
	[ "$TEST_WIPE" = 0 ] || seed_old_fat "$target" "$P_START" "$P_SIZE"
	zero_data_region "$target" "$P_START" "$P_SIZE"

	if [ -n "$DEVICE" ]; then
		as_root partprobe "$DEVICE" 2>/dev/null || as_root blockdev --rereadpt "$DEVICE" 2>/dev/null || true
		as_root udevadm settle 2>/dev/null || true
		pd="$(partdev_of "$DEVICE" "$P_NUM")"
		populate_blockdev "$pd"
		lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$DEVICE"
		info "$DEVICE is unmounted and ready"
	elif [ "$USE_LOOP" = 1 ]; then
		LOOPDEV="$(as_root losetup -Pf --show "$IMAGE")"
		as_root udevadm settle 2>/dev/null || true
		populate_blockdev "$(partdev_of "$LOOPDEV" "$P_NUM")"
		lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$LOOPDEV"
	else
		populate_image_offset "$IMAGE"
	fi

	echo
	info "Done."
	if [ "$WITH_FW" = 1 ]; then
		echo "REMINDER: this stick holds Microsoft/Qualcomm firmware for your personal use."
		echo "          Do NOT share the stick, its firmware/ directory, or an image of it."
	fi
	if [ -n "$DEVICE" ]; then
		echo "Stick ready: $DEVICE is unmounted and synced. Safely remove it, plug it into the SL7 and boot from it."
	else
		echo "Test image: $IMAGE"
	fi
}

main
