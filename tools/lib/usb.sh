#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# usb.sh - shared USB-stick functions of the SL7 kits (recon-kit, installer-kit).
# Source it; do not run it. Factored out of make-recon-usb.sh without changing
# what that script does.
#
# The caller sets these before calling the functions (all plain globals):
#   DEVICE / IMAGE   target block device, or an image file (test mode, no root)
#   USE_LOOP         1: image attached with losetup -P, same path as a device
#   FORCE_LARGE      1: allow devices larger than 256 GB
#   WORK             work directory (mount points are created below it)
#   STAGE            directory whose contents go onto the data partition
#   DATA_LABEL, DATA_TYPE_GUID, DATA_MIN_SECTORS   the data partition
#   MSI_ROOT, FW_BASE   local MSI extraction (stage_firmware)
#   MNT, LOOPDEV     set to "" before the first use; cleanup() releases them
# Results: P_NUM / P_START / P_SIZE (add_data_partition, part_info).
# Optional hooks, called when the caller defines them:
#   usb_verify_blockdev MOUNTPOINT   extra checks while the data partition is mounted
#   usb_verify_image IMAGE OFFSET    extra checks of the data partition inside an image
# The caller installs: trap cleanup EXIT
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # P_NUM/P_SIZE are read by the sourcing script

DATA_LABEL="${DATA_LABEL:-SL7DATA}"
FORCE_LARGE="${FORCE_LARGE:-0}"
USE_LOOP="${USE_LOOP:-0}"
DEVICE="${DEVICE:-}"
MNT="${MNT:-}"
LOOPDEV="${LOOPDEV:-}"

die() {
	echo "ERROR: $*" >&2
	exit 1
}
info() { echo "==> $*"; }

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
	if declare -F usb_verify_blockdev >/dev/null; then
		usb_verify_blockdev "$MNT" "$pd"
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
	if declare -F usb_verify_image >/dev/null; then
		usb_verify_image "$img" "$off"
	fi
	blkid -p -O "$off" "$img" | sed 's/^/    /'
}
