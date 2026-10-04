#!/usr/bin/env bash
# sl7-recon.sh - read-only hardware reconnaissance for omarchy-dragon-sl7
#
# Target: Microsoft Surface Laptop 7 13.8" (model 2036, X1P-64-100, BIOS 175.235.235)
# booted from an existing aarch64 Linux live USB (Ubuntu/Fedora/Arch based).
#
# WHAT IT DOES
#   Collects identity, CHID inputs, CPU/cpufreq (SCMI bug verdict), GPU, firmware
#   load errors, remoteprocs, power supplies, sleep states, qcom_stats, sync_state,
#   display/EDID, input, camera, audio, wifi/bt, USB/Type-C, thermal, kernel
#   config, dmesg, journal and lsmod. One file per section plus SUMMARY.md, then
#   tars everything into sl7-recon-<date>.tar.gz.
#
# READ-ONLY
#   Reads /sys, /proc, /dev and command output only. Writes nothing except into
#   its own output directory. Never touches disks, EFI variables (read only),
#   bootloader, network config, rfkill state, regulators or LEDs. The only state
#   change: if run as root it tries `modprobe qcom_stats` (read-only counters),
#   and mounts debugfs read-only if it is not already mounted (noted in the
#   report, unmounted again afterwards).
#
# HOW TO RUN
#   sudo bash sl7-recon.sh /path/to/usb      # output dir is created under /path/to/usb
#   bash sl7-recon.sh                        # works without root, with less data
#
# RECON IMAGE NOTES (dwhinham archlinux-sp11 ISO, systemd 262)
#   The boot stick is a dd'd ISO and is read-only: pass a SECOND USB stick (mounted)
#   as $1. Without $1 the script falls back to /tmp with a loud warning (lost on
#   poweroff). There is no Windows firmware on that image, so a missing battery,
#   GPU, ADSP or camera is recorded, not treated as failure. efivarfs may be
#   writable there; this script never writes EFI variables. Finish with `poweroff`
#   (reboot is unreliable on the SL7).
#
# PRIVACY
#   Collects no data off-device and uses no network. MAC addresses and the serial
#   number are redacted from every file except private/, which holds them on
#   purpose (Chris needs the serial recorded). Do NOT publish private/ or the
#   tarball unmodified.

set -u
export LC_ALL=C

usage() {
	cat >&2 <<USAGE
usage: sudo bash sl7-recon.sh /path/to/second-usb-stick
  The live boot stick is read-only. Plug in a second USB stick, mount it
  (e.g. mount /dev/sdb1 /mnt) and pass the mount point as the argument.
USAGE
}
if [ $# -ge 1 ] && [ -d "$1" ] && [ -w "$1" ]; then
	BASE="$1"
else
	usage
	[ $# -ge 1 ] && echo "ERROR: '$1' is not a writable directory." >&2
	BASE="/tmp"
	echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
	echo "!! WARNING: writing to /tmp (RAM). EVERYTHING IS LOST ON POWEROFF.   !!" >&2
	echo "!! Copy the output dir / tarball to a mounted USB stick before      !!" >&2
	echo "!! powering off.                                                    !!" >&2
	echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
fi
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown-date)"
NAME="sl7-recon-$STAMP"
OUT="$BASE/$NAME"
PRIV="$OUT/private"
MISSING="$OUT/.missing"

if ! mkdir -p "$OUT" "$PRIV" 2>/dev/null; then
	echo "cannot create $OUT" >&2
	exit 1
fi
: >"$MISSING"
IS_ROOT=0
[ "$(id -u 2>/dev/null)" = "0" ] && IS_ROOT=1

have() {
	if command -v "$1" >/dev/null 2>&1; then
		return 0
	fi
	grep -qx "$1" "$MISSING" 2>/dev/null || echo "$1" >>"$MISSING"
	echo "missing: $1"
	return 1
}

# hdr TITLE - section sub-heading
hdr() { printf '\n### %s\n' "$*"; }

# run CMD... - run a command if its binary exists
run() {
	hdr "$*"
	have "$1" || return 0
	"$@" 2>&1
	return 0
}

# catf FILE... - print files with names, if readable
catf() {
	local f
	for f in "$@"; do
		if [ -r "$f" ]; then
			printf '%s: ' "$f"
			if [ -d "$f" ]; then echo "(dir)"; else cat "$f" 2>&1 | tr '\0' '\n'; fi
		else
			echo "$f: (unreadable or absent)"
		fi
	done
}

# dmesg_grep LABEL REGEX
dmesg_grep() {
	hdr "dmesg | grep -iE '$2'"
	if [ -s "$OUT/.dmesg" ]; then
		grep -iE "$2" "$OUT/.dmesg" 2>&1 || echo "(no match)"
	else
		echo "(dmesg unavailable)"
	fi
}

# count_cpulist LIST - count CPUs in "0-3,5" style list
count_cpulist() {
	local n=0 part a b
	[ -n "$1" ] || { echo 0; return; }
	for part in $(echo "$1" | tr ',' ' '); do
		case "$part" in
		*-*) a=${part%-*}; b=${part#*-}; n=$((n + b - a + 1)) ;;
		*) n=$((n + 1)) ;;
		esac
	done
	echo "$n"
}

rd() { [ -r "$1" ] && tr -d '\0' <"$1" 2>/dev/null | head -n1; }

# --- debugfs / qcom_stats prep (only touch state if root) ---
DEBUGFS_MOUNTED_BY_US=0
DEBUGFS_NOTE="debugfs: already mounted or not attempted (not root)"
QSTATS_NOTE="qcom_stats: not attempted (not root)"
if [ "$IS_ROOT" = 1 ]; then
	if [ -d /sys/kernel/debug/qcom_stats ] || grep -q ' /sys/kernel/debug ' /proc/mounts 2>/dev/null; then
		DEBUGFS_NOTE="debugfs: already mounted"
	elif have mount; then
		if mount -t debugfs -o ro,nosuid,nodev,noexec none /sys/kernel/debug 2>/dev/null; then
			DEBUGFS_MOUNTED_BY_US=1
			DEBUGFS_NOTE="debugfs: was not mounted; mounted read-only by this script (unmounted at end)"
		else
			DEBUGFS_NOTE="debugfs: not mounted and mount failed"
		fi
	fi
	if [ ! -d /sys/kernel/debug/qcom_stats ]; then
		if have modprobe; then
			if modprobe qcom_stats 2>/dev/null; then
				QSTATS_NOTE="qcom_stats: modprobe qcom_stats executed"
			else
				QSTATS_NOTE="qcom_stats: modprobe failed (module absent or builtin without debugfs)"
			fi
		fi
	else
		QSTATS_NOTE="qcom_stats: debugfs dir already present"
	fi
fi

# --- capture dmesg once (kept dot-hidden, redacted at the end) ---
if have dmesg; then
	dmesg >"$OUT/.dmesg" 2>&1
	[ -s "$OUT/.dmesg" ] && grep -qi 'not permitted' "$OUT/.dmesg" && echo "(dmesg restricted: run as root)" >>"$OUT/.dmesg"
fi

# ---------------- 01 identity ----------------
{
	hdr "DMI"
	for k in sys_vendor product_name product_sku product_family product_version \
		bios_vendor bios_version bios_date board_vendor board_name board_version \
		chassis_type; do
		printf '%s=%s\n' "$k" "$(rd /sys/class/dmi/id/$k)"
	done
	hdr "device-tree"
	printf 'model=%s\n' "$(rd /sys/firmware/devicetree/base/model)"
	echo "compatible:"
	if [ -r /sys/firmware/devicetree/base/compatible ]; then
		tr '\0' '\n' </sys/firmware/devicetree/base/compatible
	else
		echo "(no /sys/firmware/devicetree/base/compatible - ACPI boot?)"
	fi
	[ -d /sys/firmware/efi ] && echo "booted via EFI: yes" || echo "booted via EFI: no"
	hdr "uname -a"; uname -a 2>&1
	hdr "/proc/cmdline"; cat /proc/cmdline 2>&1
	hdr "os-release"; cat /etc/os-release 2>&1
	hdr "id"; id 2>&1
} >"$OUT/01-identity.txt" 2>&1

# ---------------- 02 CHIDs ----------------
{
	hdr "systemd-analyze chid"
	if have systemd-analyze; then
		systemd-analyze chid 2>&1
		hdr "systemd-analyze chid --json=short"
		systemd-analyze chid --json=short 2>&1
	fi
	if command -v fwupdtool >/dev/null 2>&1; then
		hdr "fwupdtool hwids"
		fwupdtool hwids 2>&1
	else
		hdr "fwupdtool hwids"
		echo "missing: fwupdtool (not required; systemd-analyze chid preferred)"
	fi
	hdr "raw DMI fields for CHID computation"
	for k in sys_vendor product_name product_sku product_family board_vendor board_name \
		bios_vendor bios_version bios_date bios_release; do
		printf '%s=%s\n' "$k" "$(rd /sys/class/dmi/id/$k)"
	done
	echo "(compare against systemd hwids/aa64 romulus13.json; BIOS-tied CHIDs reference 144.18.235 and are expected stale)"
	have dmidecode && { hdr "dmidecode -t 1,2,11,12"; dmidecode -t 1 -t 2 -t 11 -t 12 2>&1 | grep -viE 'serial number|uuid'; }
} >"$OUT/02-chids.txt" 2>&1

# ---------------- 03 CPU ----------------
CPUF=/sys/devices/system/cpu/cpufreq
{
	run lscpu
	hdr "cpu masks"
	for k in online offline possible present kernel_max; do
		printf '%s=%s\n' "$k" "$(rd /sys/devices/system/cpu/$k)"
	done
	dmesg_grep psci 'psci'
	dmesg_grep cpu-boot 'failed to boot CPU|CPU[0-9]+: failed|smp: Brought up'
	hdr "cpufreq policies"
	ls -d $CPUF/policy* 2>&1
	for p in "$CPUF"/policy*; do
		[ -d "$p" ] || continue
		echo "== $p"
		for f in affected_cpus related_cpus scaling_governor scaling_available_governors \
			scaling_available_frequencies cpuinfo_min_freq cpuinfo_max_freq \
			scaling_min_freq scaling_max_freq scaling_cur_freq scaling_driver; do
			printf '  %s=%s\n' "$f" "$(rd "$p/$f")"
		done
	done
	hdr "governor census"
	cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c
	hdr "SCMI sustained_freq verdict"
	NPOL=0
	for p in "$CPUF"/policy*; do [ -d "$p" ] && NPOL=$((NPOL + 1)); done
	if [ "$NPOL" -eq 0 ]; then
		echo "NO cpufreq policies (cpufreq not up)"
		hdr "scmi/cpufreq diagnostics (no policies)"
		lsmod | grep -i -E 'scmi|cpufreq'
		ls /sys/bus/scmi_protocol/devices /sys/firmware/devicetree/base/firmware/scmi* 2>/dev/null
		dmesg | grep -i -E 'scmi|cpufreq|cpucp'
		if [ "$IS_ROOT" = 1 ]; then
			for m in scmi-cpufreq scmi_cpufreq; do
				if modprobe "$m" 2>&1; then echo "modprobe $m: ok"; else echo "modprobe $m: failed"; fi
			done
			sleep 1
			echo "re-list after modprobe:"
			ls -d $CPUF/policy* 2>&1
		fi
	elif [ "$NPOL" -eq 1 ] && [ -d "$CPUF/policy0" ]; then
		echo "SCMI sustained_freq bug present (only policy0)"
	else
		echo "OK: $NPOL cpufreq policies (3 expected after fix)"
	fi
	hdr "cpuidle"
	for c in /sys/devices/system/cpu/cpu0 /sys/devices/system/cpu/cpu4 /sys/devices/system/cpu/cpu8; do
		[ -d "$c/cpuidle" ] || continue
		echo "== $c"
		for s in "$c"/cpuidle/state*; do
			[ -d "$s" ] || continue
			printf '  %s name=%s usage=%s time=%s disable=%s\n' "${s##*/}" "$(rd "$s/name")" \
				"$(rd "$s/usage")" "$(rd "$s/time")" "$(rd "$s/disable")"
		done
	done
	catf /sys/devices/system/cpu/cpuidle/current_driver /sys/devices/system/cpu/cpuidle/current_governor
	hdr "per-cpu max freq / capacity"
	for c in /sys/devices/system/cpu/cpu[0-9]*; do
		printf '%s cap=%s maxf=%s\n' "${c##*/}" "$(rd "$c/cpu_capacity")" "$(rd "$c/cpufreq/cpuinfo_max_freq")"
	done
} >"$OUT/03-cpu.txt" 2>&1

# ---------------- 04 GPU ----------------
{
	dmesg_grep gpu 'msm|adreno|zap|speed.?bin|a7[0-9]{2}|gen70500|gpu'
	hdr "devfreq"
	for d in /sys/class/devfreq/*; do
		[ -d "$d" ] || continue
		echo "== $d"
		for f in name governor available_frequencies min_freq max_freq cur_freq available_governors; do
			printf '  %s=%s\n' "$f" "$(rd "$d/$f")"
		done
	done
	hdr "drm cards"; ls -l /sys/class/drm/ 2>&1
	hdr "driver bound to display/gpu"
	for d in /sys/class/drm/card*/device/driver; do
		[ -e "$d" ] && echo "$d -> $(readlink -f "$d")"
	done
} >"$OUT/04-gpu.txt" 2>&1

# ---------------- 05 firmware errors ----------------
{
	dmesg_grep fw 'firmware|direct firmware load|failed to load'
} >"$OUT/05-firmware-errors.txt" 2>&1

# ---------------- 06 remoteprocs ----------------
{
	for r in /sys/class/remoteproc/*; do
		[ -d "$r" ] || continue
		printf '%s name=%s state=%s firmware=%s\n' "${r##*/}" "$(rd "$r/name")" "$(rd "$r/state")" "$(rd "$r/firmware")"
	done
	[ -d /sys/class/remoteproc ] || echo "(no /sys/class/remoteproc)"
	hdr "remoteproc dmesg"
	dmesg_grep rproc 'remoteproc|q6v5|adsp|cdsp|pas'
} >"$OUT/06-remoteproc.txt" 2>&1

# ---------------- 07 power supply ----------------
{
	hdr "power_supply list"
	ls /sys/class/power_supply/ 2>&1
	for p in /sys/class/power_supply/*; do
		[ -d "$p" ] || continue
		echo "== $p"
		cat "$p/uevent" 2>&1
		for f in "$p"/charge_control_* "$p"/charge_type "$p"/charge_behaviour; do
			[ -e "$f" ] && printf '  %s=%s\n' "${f##*/}" "$(rd "$f")"
		done
	done
	hdr "platform_profile"
	ls -l /sys/firmware/acpi/platform_profile* 2>&1
	catf /sys/firmware/acpi/platform_profile /sys/firmware/acpi/platform_profile_choices
	hdr "leds (names only, never written)"
	ls /sys/class/leds/ 2>&1
	hdr "hwmon"
	for h in /sys/class/hwmon/*; do
		[ -d "$h" ] && printf '%s name=%s\n' "${h##*/}" "$(rd "$h/name")"
	done
} >"$OUT/07-power-supply.txt" 2>&1

# ---------------- 08 sleep ----------------
{
	catf /sys/power/mem_sleep /sys/power/state /sys/power/disk /sys/power/pm_async
	hdr "wakeup-capable devices"
	grep -l enabled /sys/devices/*/*/power/wakeup /sys/devices/platform/*/power/wakeup 2>/dev/null | head -40
} >"$OUT/08-sleep.txt" 2>&1

# ---------------- 09 qcom_stats ----------------
{
	echo "$DEBUGFS_NOTE"
	echo "$QSTATS_NOTE"
	if [ "$IS_ROOT" = 1 ]; then
		if [ -d /sys/kernel/debug/qcom_stats ]; then
			for f in /sys/kernel/debug/qcom_stats/*; do
				[ -f "$f" ] || continue
				echo "== $f"
				cat "$f" 2>&1
			done
		else
			echo "(/sys/kernel/debug/qcom_stats absent)"
		fi
	else
		echo "(not root: skipped)"
	fi
} >"$OUT/09-qcom-stats.txt" 2>&1

# ---------------- 10 sync_state ----------------
{
	dmesg_grep sync 'sync_state'
	hdr "journalctl -k -b | grep sync_state"
	if have journalctl; then
		journalctl -k -b --no-pager 2>&1 | grep -i 'sync_state' || echo "(no match)"
	fi
} >"$OUT/10-sync-state.txt" 2>&1

# ---------------- 11 display ----------------
{
	for c in /sys/class/drm/card*-*; do
		[ -d "$c" ] || continue
		echo "== $c status=$(rd "$c/status") enabled=$(rd "$c/enabled")"
		echo "modes:"
		cat "$c/modes" 2>&1
		# sysfs reports edid with size 0, so read it out first and test the copy
		mkdir -p "$OUT/edid" 2>/dev/null
		cat "$c/edid" >"$OUT/edid/${c##*/}.edid.bin" 2>/dev/null
		if [ -s "$OUT/edid/${c##*/}.edid.bin" ]; then
			echo "raw edid copied: edid/${c##*/}.edid.bin"
			if command -v edid-decode >/dev/null 2>&1; then
				echo "edid-decode:"
				edid-decode "$c/edid" 2>&1 | grep -viE 'serial'
			else
				have edid-decode
				echo "edid (hex; raw binary also in edid/):"
				if command -v hexdump >/dev/null 2>&1; then
					hexdump -C "$c/edid" 2>&1
				elif command -v xxd >/dev/null 2>&1; then
					xxd "$c/edid" 2>&1
				elif command -v od >/dev/null 2>&1; then
					od -Ax -tx1 "$c/edid" 2>&1
				else
					echo "missing: hexdump/xxd/od"
				fi
			fi
		else
			rm -f "$OUT/edid/${c##*/}.edid.bin"
		fi
	done
	hdr "backlight"
	for b in /sys/class/backlight/*; do
		[ -d "$b" ] || continue
		printf '%s max=%s actual=%s brightness=%s type=%s\n' "${b##*/}" "$(rd "$b/max_brightness")" \
			"$(rd "$b/actual_brightness")" "$(rd "$b/brightness")" "$(rd "$b/type")"
	done
	hdr "DP AUX / DPCD PSR_SUPPORT (0x070), read-only"
	for a in /dev/drm_dp_aux*; do
		[ -e "$a" ] || continue
		if command -v dd >/dev/null 2>&1 && command -v od >/dev/null 2>&1; then
			printf '%s DPCD[0x070]=%s\n' "$a" "$(dd if="$a" bs=1 skip=112 count=1 2>/dev/null | od -An -tx1 | tr -d ' ')"
		fi
	done
	ls /dev/drm_dp_aux* >/dev/null 2>&1 || echo "(no /dev/drm_dp_aux*)"
	run modetest -c
	dmesg_grep drm 'drm|dp-aux|panel|edp|dpu|psr'
} >"$OUT/11-display.txt" 2>&1

# ---------------- 12 input ----------------
{
	hdr "/proc/bus/input/devices"; cat /proc/bus/input/devices 2>&1
	hdr "lsmod | grep -iE 'surface|hid|spi'"
	if have lsmod; then lsmod 2>&1 | grep -iE 'surface|hid|spi' || echo "(no match)"; fi
	hdr "Omarchy keyboard-script trigger: lsmod | grep pinctrl_"
	if have lsmod; then lsmod 2>&1 | grep 'pinctrl_' && echo "RESULT: pinctrl_ module loaded (fix-surface-keyboard.sh would fire)" || echo "RESULT: no pinctrl_ module loaded"; fi
	hdr "spi devices"
	for d in /sys/bus/spi/devices/*; do
		[ -e "$d" ] || continue
		printf '%s modalias=%s name=%s driver=%s\n' "${d##*/}" "$(rd "$d/modalias")" "$(rd "$d/name")" \
			"$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)"
	done
	ls /sys/bus/spi/devices 2>&1 | head -1 | grep -q . || echo "(none)"
	hdr "i2c devices"
	for d in /sys/bus/i2c/devices/*; do
		[ -e "$d" ] || continue
		printf '%s name=%s modalias=%s driver=%s\n' "${d##*/}" "$(rd "$d/name")" "$(rd "$d/modalias")" \
			"$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)"
	done
	hdr "hid devices"
	ls /sys/bus/hid/devices 2>&1
	hdr "surface aggregator / SAM"
	ls /sys/bus/surface_aggregator/devices 2>&1
	hdr "ACPI/platform ids of interest (MSHW*)"
	for d in /sys/bus/platform/devices/* /sys/bus/acpi/devices/*; do [ -e "$d" ] && echo "${d##*/}"; done | grep -i mshw
	dmesg_grep hid 'surface|hid|spi-hid|i2c_hid|ipts|iptsd|gpio-keys'
} >"$OUT/12-input.txt" 2>&1

# ---------------- 13 camera ----------------
{
	hdr "/dev/video* /dev/media* /dev/v4l-subdev*"
	ls -l /dev/video* /dev/media* /dev/v4l-subdev* 2>&1
	for m in /dev/media*; do
		[ -e "$m" ] || continue
		hdr "media-ctl -p -d $m"
		have media-ctl && media-ctl -p -d "$m" 2>&1
	done
	run v4l2-ctl --list-devices
	dmesg_grep cam 'camss|cci|ov02c10|vd55g|csiphy|csid|v4l2|camera'
} >"$OUT/13-camera.txt" 2>&1

# ---------------- 14 audio ----------------
{
	run aplay -l
	hdr "/proc/asound/cards"; cat /proc/asound/cards 2>&1
	dmesg_grep audio 'snd|asoc|wsa88|wcd93|q6apm|lpass|audioreach|soundwire'
} >"$OUT/14-audio.txt" 2>&1

# ---------------- 15 wifi / bt ----------------
{
	run lspci -nn
	dmesg_grep wifi 'ath12k|rfkill|board-2|bluetooth|hci'
	hdr "rfkill list (read only)"
	if command -v rfkill >/dev/null 2>&1; then
		rfkill list 2>&1
	else
		have rfkill
		for r in /sys/class/rfkill/*; do
			[ -d "$r" ] && printf '%s name=%s type=%s soft=%s hard=%s\n' "${r##*/}" "$(rd "$r/name")" "$(rd "$r/type")" "$(rd "$r/soft")" "$(rd "$r/hard")"
		done
	fi
	hdr "net interfaces (names/state only)"
	for n in /sys/class/net/*; do
		[ -d "$n" ] && printf '%s operstate=%s type=%s\n' "${n##*/}" "$(rd "$n/operstate")" "$(rd "$n/type")"
	done
	hdr "bluetooth"
	ls /sys/class/bluetooth 2>&1
	hdr "ath12k firmware files present"
	ls -l /lib/firmware/ath12k/*/*/ 2>&1 | head -40
} >"$OUT/15-wifi-bt.txt" 2>&1

# ---------------- 16 USB / Type-C ----------------
{
	run lsusb -t
	hdr "typec"
	for t in /sys/class/typec/*; do
		[ -e "$t" ] || continue
		echo "== $t"
		for f in data_role power_role power_operation_mode preferred_role orientation vconn_source supported_accessory_modes; do
			[ -r "$t/$f" ] && printf '  %s=%s\n' "$f" "$(rd "$t/$f")"
		done
	done
	ls /sys/class/typec 2>/dev/null | head -1 | grep -q . || echo "(no typec ports)"
	hdr "usb4 / thunderbolt"
	ls /sys/bus/thunderbolt/devices 2>&1
	dmesg_grep usb 'typec|ucsi|pmic_glink|usb4|qmp|dwc3|xhci'
} >"$OUT/16-usb-typec.txt" 2>&1

# ---------------- 17 thermal ----------------
{
	for z in /sys/class/thermal/thermal_zone*; do
		[ -d "$z" ] || continue
		printf '%s type=%s temp=%s\n' "${z##*/}" "$(rd "$z/type")" "$(rd "$z/temp")"
	done
	ls /sys/class/thermal/thermal_zone* >/dev/null 2>&1 || echo "(no thermal zones)"
	hdr "cooling devices"
	for z in /sys/class/thermal/cooling_device*; do
		[ -d "$z" ] && printf '%s type=%s cur=%s max=%s\n' "${z##*/}" "$(rd "$z/type")" "$(rd "$z/cur_state")" "$(rd "$z/max_state")"
	done
} >"$OUT/17-thermal.txt" 2>&1

# ---------------- 18 kernel config ----------------
{
	CFG=""
	if [ -r /proc/config.gz ]; then
		CFG=/proc/config.gz
	else
		for f in "/boot/config-$(uname -r)" /boot/config-*; do
			[ -r "$f" ] && { CFG="$f"; break; }
		done
	fi
	if [ -z "$CFG" ]; then
		echo "(no kernel config available)"
	else
		echo "source: $CFG"
		case "$CFG" in
		*.gz) if have zcat; then zcat "$CFG"; fi ;;
		*) cat "$CFG" ;;
		esac 2>&1 | grep -E 'SURFACE_|IRIS|SM_VIDEOCC|USB4|SPI_HID|CPU_FREQ_DEFAULT_GOV|FW_LOADER_COMPRESS|QCOM_STATS|ARM_SCMI|PINCTRL_.*X1E|CAMSS|LEDS_QCOM_FLASH|SENSORS_SURFACE|PSTORE' || echo "(no matches)"
	fi
} >"$OUT/18-kernel-config.txt" 2>&1

# ---------------- 19 dmesg / journal / lsmod ----------------
{ [ -s "$OUT/.dmesg" ] && cat "$OUT/.dmesg"; } >"$OUT/19-dmesg-full.txt" 2>&1
{
	if have journalctl; then journalctl -k -b --no-pager 2>&1; fi
} >"$OUT/19-journal-kernel.txt" 2>&1
{ if have lsmod; then lsmod 2>&1; fi; } >"$OUT/19-lsmod.txt" 2>&1

# ---------------- private (serial, MACs, unredacted logs) ----------------
{
	echo "# WARNING: PRIVATE. Contains the device serial number and MAC addresses."
	echo "# Keep on the USB stick. Do NOT post, commit or attach this file."
	echo "product_serial=$(rd /sys/class/dmi/id/product_serial)"
	echo "board_serial=$(rd /sys/class/dmi/id/board_serial)"
	echo "chassis_serial=$(rd /sys/class/dmi/id/chassis_serial)"
	echo "product_uuid=$(rd /sys/class/dmi/id/product_uuid)"
	have dmidecode && dmidecode -s system-serial-number 2>&1
	hdr "net MACs"
	for n in /sys/class/net/*; do
		[ -d "$n" ] && printf '%s %s\n' "${n##*/}" "$(rd "$n/address")"
	done
	hdr "bluetooth addresses"
	if have hciconfig; then hciconfig -a 2>&1 | grep -iE '^hci|BD Address'; fi
	for p in /sys/class/bluetooth/hci*; do [ -e "$p" ] && echo "$p"; done
	grep -ioE 'bluetooth.*([0-9a-f]{2}:){5}[0-9a-f]{2}' "$OUT/.dmesg" 2>/dev/null
	hdr "ath12k / wlan mac lines from dmesg"
	grep -iE 'ath12k.*mac|wlan.*([0-9a-f]{2}:){5}[0-9a-f]{2}' "$OUT/.dmesg" 2>/dev/null
} >"$PRIV/IDENTIFIERS-PRIVATE.txt" 2>&1
cp "$OUT/.dmesg" "$PRIV/dmesg-unredacted.txt" 2>/dev/null
{ cat "$OUT/01-identity.txt"; cat /sys/class/power_supply/*/uevent 2>/dev/null; } >"$PRIV/power-supply-uevent-unredacted.txt" 2>/dev/null

# ---------------- SUMMARY.md ----------------
{
	echo "# SL7 recon summary"
	echo
	echo "Generated: $STAMP (serial and MACs deliberately omitted; see private/)"
	echo
	SKU="$(rd /sys/class/dmi/id/product_sku)"
	echo "- Model: $(rd /sys/class/dmi/id/sys_vendor) / $(rd /sys/class/dmi/id/product_name); SKU: ${SKU:-unknown}"
	echo "- BIOS: $(rd /sys/class/dmi/id/bios_version) ($(rd /sys/class/dmi/id/bios_date)); expected 175.235.235"
	echo "- Kernel: $(uname -r 2>/dev/null); EFI boot: $([ -d /sys/firmware/efi ] && echo yes || echo no)"
	COMPAT=""
	[ -r /sys/firmware/devicetree/base/compatible ] && COMPAT="$(tr '\0' ' ' </sys/firmware/devicetree/base/compatible)"
	case "$COMPAT" in
	*romulus13*) V="OK (romulus13 as expected)" ;;
	*romulus15*) V="WRONG? romulus15 picked" ;;
	"") V="none (ACPI boot or no DT)" ;;
	*) V="unexpected" ;;
	esac
	echo "- DT compatible: ${COMPAT:-none} -> $V"
	echo "- DT model: $(rd /sys/firmware/devicetree/base/model)"
	NPOL=0; PLIST=""
	for p in "$CPUF"/policy*; do [ -d "$p" ] && { NPOL=$((NPOL + 1)); PLIST="$PLIST ${p##*/}"; }; done
	if [ "$NPOL" -eq 1 ] && [ -d "$CPUF/policy0" ]; then
		echo "- cpufreq policies: 1 ($PLIST ) -> SCMI sustained_freq bug present"
	else
		echo "- cpufreq policies: $NPOL ($PLIST ) -> $([ "$NPOL" -ge 3 ] && echo 'OK (3 expected after fix)' || echo 'unexpected count')"
	fi
	ONL="$(rd /sys/devices/system/cpu/online)"
	echo "- CPUs online: $(count_cpulist "$ONL") ($ONL); offline: '$(rd /sys/devices/system/cpu/offline)'; present: $(rd /sys/devices/system/cpu/present)"
	echo "- Governor(s): $(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | tr -s ' \n' ' ')"
	PS="$(grep -i 'psci' "$OUT/.dmesg" 2>/dev/null | grep -iE 'fail|boot CPU' | head -5 | sed 's/^/    /')"
	echo "- Fused-core psci messages: $([ -n "$PS" ] && echo "yes (expect CPU7/CPU11 style -22)" || echo none)"
	[ -n "$PS" ] && echo "$PS"
	echo "- mem_sleep: $(rd /sys/power/mem_sleep); state: $(rd /sys/power/state)"
	MODES=""
	for c in /sys/class/drm/card*-*; do
		[ -r "$c/modes" ] && [ -s "$c/modes" ] && MODES="$MODES $(basename "$c"):[$(tr '\n' ' ' <"$c/modes")]"
	done
	echo "- Panel modes:${MODES:- none read}"
	H60=no; H120=no
	for c in /sys/class/drm/card*-eDP*; do
		[ -r "$c/modes" ] || continue
		:
	done
	if command -v edid-decode >/dev/null 2>&1; then
		for c in /sys/class/drm/card*-eDP*; do
			[ -s "$c/edid" ] || continue
			E="$(edid-decode "$c/edid" 2>/dev/null)"
			echo "$E" | grep -qE ' 60\.0+ Hz| 60 Hz|@ *60' && H60=yes
			echo "$E" | grep -qE ' 120\.0+ Hz| 120 Hz|@ *120' && H120=yes
		done
		echo "- EDID refresh seen (edid-decode): 60 Hz=$H60, 120 Hz=$H120 (confirm in 11-display.txt)"
	else
		echo "- EDID refresh: edid-decode missing; raw EDID copied to edid/, decode off-device"
	fi
	TS=""
	ls /sys/bus/spi/devices/* >/dev/null 2>&1 && TS="spi($(ls /sys/bus/spi/devices | tr '\n' ' '))"
	if ls /sys/bus/i2c/devices/* >/dev/null 2>&1; then
		HID="$(for d in /sys/bus/i2c/devices/*; do rd "$d/name"; done | grep -iE 'hid|touch|gtch|mshw' | tr '\n' ' ')"
		[ -n "$HID" ] && TS="$TS i2c-candidates($HID)"
	fi
	echo "- Touchscreen bus seen: ${TS:-none seen}"
	echo "- pinctrl_ modules loaded: $(lsmod 2>/dev/null | grep -c '^pinctrl_')"
	BAT=""
	for p in /sys/class/power_supply/*; do
		[ "$(rd "$p/type")" = "Battery" ] && BAT="$BAT ${p##*/}"
	done
	echo "- Battery device(s):${BAT:- none (expected on this image: no Windows firmware/ADSP; not a failure)}"
	echo "- platform_profile: $([ -e /sys/firmware/acpi/platform_profile ] && rd /sys/firmware/acpi/platform_profile || echo absent)"
	RUN=""; ALL=0; UP=0
	for r in /sys/class/remoteproc/*; do
		[ -d "$r" ] || continue
		ALL=$((ALL + 1))
		[ "$(rd "$r/state")" = "running" ] && { UP=$((UP + 1)); RUN="$RUN $(rd "$r/name")"; }
	done
	echo "- Remoteprocs running: $UP of $ALL ($RUN ) $([ "$UP" -eq 0 ] && echo '(none expected on this image; not a failure)')"
	echo "- GPU (adreno/zap) lines in dmesg: $(grep -ciE 'adreno|zap' "$OUT/.dmesg" 2>/dev/null) (0 can be expected without firmware)"
	echo "- CHID tool: $(command -v systemd-analyze >/dev/null 2>&1 && echo 'systemd-analyze chid (see 02-chids.txt)' || echo 'systemd-analyze missing')"
	SSN="$(grep -ci 'sync_state() pending' "$OUT/.dmesg" 2>/dev/null)"
	echo "- sync_state pending count: ${SSN:-0}"
	echo "- Firmware load error lines: $(grep -ciE 'direct firmware load|failed to load' "$OUT/.dmesg" 2>/dev/null)"
	echo "- $DEBUGFS_NOTE"
	echo "- $QSTATS_NOTE"
	echo "- Missing tools: $(sort -u "$MISSING" 2>/dev/null | tr '\n' ' ')"
	echo "- Root: $([ "$IS_ROOT" = 1 ] && echo yes || echo 'no (dmesg/debugfs/qcom_stats may be incomplete)')"
} >"$OUT/SUMMARY.md" 2>&1

# ---------------- redact main dir ----------------
MACRE='([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}'
SERIALS=""
for k in product_serial board_serial chassis_serial; do
	v="$(rd /sys/class/dmi/id/$k)"
	[ -n "$v" ] && [ ${#v} -ge 6 ] && SERIALS="$SERIALS $v"
done
for f in "$OUT"/*.txt "$OUT"/SUMMARY.md; do
	[ -f "$f" ] || continue
	sed -E -i "s/$MACRE/xx:xx:xx:xx:xx:xx/g; s/(serial[_ a-z]*[=:] *).*/\1REDACTED/Ig; s/(SERIAL_NUMBER=).*/\1REDACTED/g" "$f" 2>/dev/null
	for s in $SERIALS; do
		sed -i "s/$s/REDACTED/g" "$f" 2>/dev/null
	done
done
# strip trailing whitespace from everything we wrote
for f in "$OUT"/*.txt "$OUT"/SUMMARY.md "$PRIV"/*; do
	[ -f "$f" ] && sed -i 's/[[:space:]]*$//' "$f" 2>/dev/null
done
rm -f "$OUT/.dmesg"
mv "$MISSING" "$OUT/missing-tools.txt" 2>/dev/null

[ "$DEBUGFS_MOUNTED_BY_US" = 1 ] && umount /sys/kernel/debug 2>/dev/null

# ---------------- hand back ownership, tar ----------------
TAR="$BASE/$NAME.tar.gz"
if have tar; then
	tar -C "$BASE" -czf "$TAR" "$NAME" 2>&1
fi
if [ "$IS_ROOT" = 1 ] && [ -n "${SUDO_UID:-}" ]; then
	chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$OUT" "$TAR" 2>/dev/null
fi

echo
echo "Recon directory: $OUT"
[ -f "$TAR" ] && echo "Archive:         $TAR"
echo "Summary:         $OUT/SUMMARY.md"
echo "Serial and MACs: $PRIV/IDENTIFIERS-PRIVATE.txt (keep private; also inside the archive)"
sync 2>/dev/null
if [ "$BASE" = "/tmp" ]; then
	echo
	echo "!! Output is in /tmp (RAM). Copy it to a mounted USB stick NOW, or it is lost. !!"
fi
echo
echo "Done. Unmount the output stick, then run:  poweroff"
echo "(do not use reboot; it is unreliable on the SL7)"
exit 0
