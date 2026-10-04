#!/usr/bin/env bash
# sl7-guide.sh - guided hardware recon for the Surface Laptop 7 13.8" (model 2036)
#
# Runs on the SL7 live system (dwhinham archlinux-sp11 ISO) as root, started by
# the autostart hook from the SL7DATA partition mounted at /sl7.
#
#   a. welcome + safety   b. identity check   c. baseline recon
#   d. firmware into RAM  e. recon again      f. interactive checks
#   g. optional suspend   h. summary + poweroff
#
# Safety: never touches the internal disk, never writes EFI variables, never
# touches regulators, LEDs or rfkill. Firmware goes to /lib/firmware/updates on
# the live tmpfs root only. Serial numbers and MAC addresses are never printed.
#
# Resumable: progress lives in /sl7/results/.progress. Run it again and it
# offers to continue. Everything is logged to /sl7/results/<ts>/guide.log.
#
# Test hooks (not needed on the SL7): SL7_DATA=/some/dir, SL7_UI=plain, SL7_RAMDIR=dir.

set -u

# ---------------------------------------------------------------- relocation
# The boot stick can drop off the bus when the ADSP starts (USB-C reset), so run
# from RAM, never from the stick.
RAMDIR="${SL7_RAMDIR:-/run/sl7}"
if [ "${SL7_RELOCATED:-0}" != 1 ]; then
	SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
	mkdir -p "$RAMDIR"
	cp "$0" "$RAMDIR/sl7-guide.sh"
	[ -f "$SRC_DIR/sl7-recon.sh" ] && cp "$SRC_DIR/sl7-recon.sh" "$RAMDIR/sl7-recon.sh"
	SL7_RELOCATED=1 SL7_RAMDIR="$RAMDIR" SL7_DATA="${SL7_DATA:-$SRC_DIR}" exec bash "$RAMDIR/sl7-guide.sh" "$@"
fi

DATA="${SL7_DATA:-/sl7}"
RES="$DATA/results"
PROGRESS="$RES/.progress"
LOG="$RAMDIR/guide.log"
FWSRC="$DATA/firmware"
FWDST=/lib/firmware/updates
EXPECT_SKU=2036
EXPECT_DT="microsoft,romulus13"
TS=""
SESS=""

# ---------------------------------------------------------------- basics
if [ "$(id -u)" != 0 ]; then
	echo "sl7-guide.sh must run as root (try: sudo bash $0)" >&2
	[ -z "${SL7_UI:-}" ] && exit 1
	echo "(continuing anyway: SL7_UI test mode)" >&2
fi

if [ "${TERM:-linux}" = linux ] || ! locale charmap 2>/dev/null | grep -qi 'utf-8'; then
	OK="[OK]"
	BAD="[!!]"
else
	OK="✓"
	BAD="✗"
fi

UI=plain
if [ "${SL7_UI:-}" != plain ] && command -v whiptail >/dev/null 2>&1 && [ -t 0 ] && [ "${TERM:-dumb}" != dumb ]; then
	UI=whiptail
fi

now() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
	printf '%s %s\n' "$(now)" "$*" >>"$LOG"
}

say() {
	log "$*"
	printf '%s\n' "$*"
}

flush_log() {
	[ -n "$SESS" ] && [ -d "$SESS" ] && cp "$LOG" "$SESS/guide.log" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------- UI helpers
ui_msg() { # title text
	log "DIALOG [$1] $2"
	if [ "$UI" = whiptail ]; then
		whiptail --title "$1" --scrolltext --msgbox "$2" 22 76
	else
		printf '\n=== %s ===\n%s\n' "$1" "$2"
		read -r -p "[Enter to continue] " _
	fi
}

ui_yesno() { # title text default(y|n)  -> 0 yes, 1 no
	local rc ans
	log "QUESTION [$1] $2"
	if [ "$UI" = whiptail ]; then
		if [ "${3:-y}" = n ]; then
			whiptail --title "$1" --defaultno --scrolltext --yesno "$2" 22 76
		else
			whiptail --title "$1" --scrolltext --yesno "$2" 22 76
		fi
		rc=$?
	else
		printf '\n=== %s ===\n%s\n' "$1" "$2"
		while :; do
			read -r -p "[y/n, default ${3:-y}] " ans
			ans="${ans:-${3:-y}}"
			case "$ans" in
			y | Y | yes) rc=0; break ;;
			n | N | no) rc=1; break ;;
			esac
		done
	fi
	log "ANSWER rc=$rc"
	return "$rc"
}

# ui_menu TITLE TEXT TAG ITEM [TAG ITEM...]  -> chosen tag in $REPLY
ui_menu() {
	local title="$1" text="$2" n i
	shift 2
	log "MENU [$title] $text"
	if [ "$UI" = whiptail ]; then
		REPLY="$(whiptail --title "$title" --menu "$text" 20 76 "$(($# / 2))" "$@" 3>&1 1>&2 2>&3)" || REPLY=skip
	else
		printf '\n=== %s ===\n%s\n' "$title" "$text"
		i=1
		local tags=("$@")
		for ((n = 0; n < ${#tags[@]}; n += 2)); do
			printf '  %d) %s\n' "$i" "${tags[n + 1]}"
			i=$((i + 1))
		done
		while :; do
			read -r -p "choice number: " n
			if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $((${#tags[@]} / 2)) ]; then
				REPLY="${tags[$(((n - 1) * 2))]}"
				break
			fi
		done
	fi
	log "CHOICE $REPLY"
}

# ---------------------------------------------------------------- progress
step_done() { echo "step_$1=done" >>"$PROGRESS" 2>/dev/null; }
is_done() { grep -qx "step_$1=done" "$PROGRESS" 2>/dev/null; }
prog_set() { echo "$1=$2" >>"$PROGRESS" 2>/dev/null; }
prog_get() { grep "^$1=" "$PROGRESS" 2>/dev/null | tail -1 | cut -d= -f2-; }

answer() { # key answer detail
	printf '%s | %s | %s | %s\n' "$(now)" "$1" "$2" "$3" >>"$RES/answers.txt"
	log "ANSWER-RECORDED $1 = $2 ($3)"
}

# ---------------------------------------------------------------- stick access
data_ok() {
	local t="$RES/.rwtest.$$"
	{ : >"$t"; } 2>/dev/null && rm -f "$t"
}

find_data_partition() {
	[ -e /dev/disk/by-label/SL7DATA ] && readlink -f /dev/disk/by-label/SL7DATA
}

# mount_data DEV: plain rw mount, else loop-with-offset on the parent disk (archiso may
# hold the whole disk, which blocks opening its partitions).
mount_data() {
	local b="${1##*/}" p lo
	mount -o rw "$1" "$DATA" 2>/dev/null && return 0
	[ -r "/sys/class/block/$b/start" ] || return 1
	p="$(basename "$(readlink -f "/sys/class/block/$b/..")")"
	lo="$(losetup -f --show -o $(($(cat "/sys/class/block/$b/start") * 512)) \
		--sizelimit $(($(cat "/sys/class/block/$b/size") * 512)) "/dev/$p")" || return 1
	mount -o rw "$lo" "$DATA" || { losetup -d "$lo"; return 1; }
}

# release_data: clean unmount + detach loops on the data partition (called before poweroff).
release_data() {
	sync
	mountpoint -q "$DATA" && umount "$DATA" 2>/dev/null
	losetup -nl -O NAME,BACK-FILE 2>/dev/null | awk '$2 ~ /^\/dev\/sd|^\/dev\/nvme|^\/dev\/mmc/ {print $1}' | while read -r l; do
		losetup -d "$l" 2>/dev/null
	done
	sync
}

# ensure_data: make sure the stick is writable, remounting it if the USB bus
# dropped and came back (this happens when the ADSP starts).
ensure_data() {
	local i dev
	data_ok && return 0
	say "The SL7DATA stick is not writable. Waiting for it to come back..."
	mountpoint -q "$DATA" && umount -l "$DATA" 2>/dev/null
	for _ in 1 2 3; do
		for ((i = 0; i < 30; i++)); do
			dev="$(find_data_partition)"
			if [ -n "$dev" ] && mount_data "$dev"; then
				mkdir -p "$RES"
				if data_ok; then
					say "SL7DATA is back on $dev."
					flush_log
					return 0
				fi
			fi
			sleep 2
		done
		ui_msg "Stick disconnected" "The SL7DATA stick dropped off the USB bus.

Unplug it, wait 5 seconds, plug it into a USB-A port (or the same port) and press Enter. Do not power off."
	done
	say "WARNING: SL7DATA never came back. Results are kept in RAM only: $LOG"
	return 1
}

# ---------------------------------------------------------------- small readers
dmi() {
	local v
	v="$(cat "/sys/class/dmi/id/$1" 2>/dev/null)"
	echo "${v:-unknown}"
}

dt_compat() {
	if [ -r /proc/device-tree/compatible ]; then
		tr '\0' '\n' </proc/device-tree/compatible | head -4 | tr '\n' ' '
	else
		echo "none (no device tree)"
	fi
}

check_line() { # ok(0|1) label value
	if [ "$1" = 0 ]; then
		say "  $OK $2: $3"
	else
		say "  $BAD $2: $3"
	fi
}

battery_report() {
	local p t found=0
	for p in /sys/class/power_supply/*; do
		[ -d "$p" ] || continue
		t="$(cat "$p/type" 2>/dev/null)"
		[ "$t" = Battery ] || continue
		found=1
		echo "  battery ${p##*/}: status=$(cat "$p/status" 2>/dev/null) capacity=$(cat "$p/capacity" 2>/dev/null)% energy_now=$(cat "$p/energy_now" 2>/dev/null) energy_full=$(cat "$p/energy_full" 2>/dev/null) charge_now=$(cat "$p/charge_now" 2>/dev/null)"
	done
	[ "$found" = 1 ] || echo "  no battery power_supply device"
}

battery_energy() { # prints "<unit> <value>" of the first battery, or "none 0"
	local p
	for p in /sys/class/power_supply/*; do
		[ "$(cat "$p/type" 2>/dev/null)" = Battery ] || continue
		if [ -r "$p/energy_now" ]; then
			echo "uWh $(cat "$p/energy_now")"
			return
		elif [ -r "$p/charge_now" ]; then
			echo "uAh $(cat "$p/charge_now")"
			return
		fi
	done
	echo "none 0"
}

rproc_report() {
	local r
	for r in /sys/class/remoteproc/remoteproc*; do
		[ -d "$r" ] || continue
		echo "  ${r##*/}: name=$(cat "$r/name" 2>/dev/null) state=$(cat "$r/state" 2>/dev/null) firmware=$(cat "$r/firmware" 2>/dev/null)"
	done
}

stats_dump() { # dest
	local f
	{
		for f in /sys/kernel/debug/qcom_stats/*; do
			[ -r "$f" ] && printf '== %s\n%s\n' "$f" "$(cat "$f")"
		done
	} >"$1" 2>&1
}

suspended_secs() {
	python3 -c 'import time;print(time.clock_gettime(time.CLOCK_BOOTTIME)-time.clock_gettime(time.CLOCK_MONOTONIC))'
}

# ---------------------------------------------------------------- input helper
write_evwatch() {
	cat >"$RAMDIR/evwatch.py" <<'PYEOF'
#!/usr/bin/env python3
"""evwatch.py MODE SECONDS - passive input event watcher (never grabs devices).

MODE: key | touchpad | touchscreen | lid
Prints one line per interesting device:  RESULT|<device name>|<detail>
"""
import os
import re
import select
import struct
import sys
import time

EV_KEY, EV_REL, EV_ABS, EV_SW = 1, 2, 3, 5
FMT = "llHHi"
SIZE = struct.calcsize(FMT)
BTN_LEFT, BTN_TOUCH = 0x110, 0x14A


def devices():
    out = {}
    with open("/proc/bus/input/devices") as fh:
        blocks = fh.read().split("\n\n")
    for blk in blocks:
        name = re.search(r'N: Name="(.*)"', blk)
        hand = re.search(r"H: Handlers=(.*)", blk)
        prop = re.search(r"B: PROP=(\S+)", blk)
        if name and hand:
            for ev in re.findall(r"event\d+", hand.group(1)):
                out[ev] = (name.group(1), int(prop.group(1), 16) if prop else 0)
    return out


def interesting(mode, props, etype, code, value):
    direct = bool(props & 0x2)
    if mode == "key":
        return etype == EV_KEY and code < 0x100 and value == 1
    if mode == "touchpad":
        if direct:
            return False
        return etype in (EV_REL, EV_ABS) or (etype == EV_KEY and code in (BTN_LEFT, BTN_TOUCH))
    if mode == "touchscreen":
        return direct and (etype == EV_ABS or (etype == EV_KEY and code == BTN_TOUCH))
    if mode == "lid":
        return etype == EV_SW and code == 0
    return False


def main():
    mode, secs = sys.argv[1], float(sys.argv[2])
    devs = devices()
    fds = {}
    for ev in devs:
        try:
            fds[os.open("/dev/input/" + ev, os.O_RDONLY | os.O_NONBLOCK)] = ev
        except OSError:
            pass
    counts = {}
    lid = []
    end = time.time() + secs
    first = None
    while time.time() < end:
        if first and time.time() > first + 2.5 and mode != "lid":
            break
        ready, _, _ = select.select(list(fds), [], [], 0.25)
        for fd in ready:
            try:
                data = os.read(fd, SIZE * 64)
            except OSError:
                continue
            for off in range(0, len(data) - SIZE + 1, SIZE):
                _, _, etype, code, value = struct.unpack(FMT, data[off:off + SIZE])
                name, props = devs[fds[fd]]
                if interesting(mode, props, etype, code, value):
                    counts[name] = counts.get(name, 0) + 1
                    first = first or time.time()
                    if mode == "lid":
                        lid.append("closed" if value else "open")
    for name, n in sorted(counts.items()):
        detail = (" ".join(lid)) if mode == "lid" else "%d events" % n
        print("RESULT|%s|%s" % (name, detail))
    sys.exit(0 if counts else 1)


main()
PYEOF
}

# ---------------------------------------------------------------- steps
step_welcome() {
	ui_msg "Surface Laptop 7 recon" "Welcome, Chris.

This guide collects hardware facts for the omarchy-dragon-sl7 port. It takes about 15-25 minutes.

Safety:
 - The internal disk is not touched. Nothing is installed.
 - Stay on AC power (charger plugged in) for the whole run.
 - Firmware is loaded into RAM only and vanishes at poweroff.
 - At the end you will be told to run 'poweroff'.

Results are written to the SL7DATA stick: $RES"
}

step_identity() {
	local sku product bios vendor dt rc
	vendor="$(dmi sys_vendor)"
	product="$(dmi product_name)"
	sku="$(dmi product_sku)"
	bios="$(dmi bios_version)"
	dt="$(dt_compat)"
	say "Identity check (serial number and MACs are never shown):"
	check_line 0 "Vendor" "$vendor"
	check_line 0 "Product" "$product"
	case "$sku" in *"$EXPECT_SKU"*) rc=0 ;; *) rc=1 ;; esac
	check_line "$rc" "SKU (expect *$EXPECT_SKU)" "$sku"
	check_line 0 "BIOS" "$bios"
	case "$dt" in *"$EXPECT_DT"*) rc=0 ;; *) rc=1 ;; esac
	check_line "$rc" "DT compatible (expect $EXPECT_DT)" "$dt"
	if ! ui_yesno "Identity" "Vendor:  $vendor
Product: $product
SKU:     $sku   (expected: *$EXPECT_SKU)
BIOS:    $bios
DT:      $dt
         (expected: $EXPECT_DT)

$OK = matches expectation, $BAD = differs (see the lines printed before this dialog).

Continue?" y; then
		say "Stopped at identity check by request."
		return 1
	fi
	return 0
}

run_recon() { # label
	local dir="$RES/$TS-$1"
	mkdir -p "$dir"
	say "Running sl7-recon.sh -> $dir (this takes a minute or two)..."
	if [ -f "$RAMDIR/sl7-recon.sh" ]; then
		bash "$RAMDIR/sl7-recon.sh" "$dir" 2>&1 | tee -a "$LOG" | tail -n 6
	else
		say "ERROR: sl7-recon.sh not found on the stick."
		return 1
	fi
	sync
	say "Recon '$1' finished."
}

step_baseline() {
	ensure_data
	run_recon baseline
}

step_firmware() {
	local src_sz avail r fw any_running=0 started=0 i
	if [ ! -d "$FWSRC" ] || [ -z "$(ls -A "$FWSRC" 2>/dev/null)" ]; then
		ui_msg "Firmware" "No firmware directory on the stick (built with --no-firmware?). Skipping the firmware step."
		prog_set fw_result skipped
		return 0
	fi
	if ! ui_yesno "Load firmware into RAM?" "This copies the Microsoft firmware from the stick into /lib/firmware/updates (live RAM disk), then starts the ADSP and CDSP remote processors so we can see battery, audio DSP and compute state.

WARNING: starting the ADSP can reset the USB-C ports. The screen may flicker and the boot stick may disconnect for a few seconds. Do NOT unplug anything unless this guide says so. Allow up to 2 minutes.

Skipping is fine; the with-firmware recon and suspend test are then skipped too.

Load firmware now?" y; then
		prog_set fw_result skipped
		return 0
	fi

	# Keep the compressed root image in the page cache so the live system survives a USB reset.
	if [ -f /run/archiso/bootmnt/arch/aarch64/airootfs.sfs ]; then
		say "Caching the live system image in RAM (about a minute)..."
		dd if=/run/archiso/bootmnt/arch/aarch64/airootfs.sfs of=/dev/null bs=4M 2>&1 | tail -n 1 | tee -a "$LOG"
	fi

	src_sz="$(du -sk "$FWSRC" | cut -f1)"
	mkdir -p "$FWDST"
	avail="$(df -Pk "$FWDST" | awk 'NR==2 {print $4}')"
	if [ "${avail:-0}" -lt $((src_sz + 8192)) ]; then
		say "Not enough RAM-disk space for firmware (${src_sz} KB needed, ${avail} KB free). Skipping."
		prog_set fw_result failed-space
		return 0
	fi
	say "Copying firmware (${src_sz} KB) to $FWDST ..."
	cp -a "$FWSRC"/. "$FWDST"/
	find "$FWDST" -type f | sed "s#^$FWDST/##" >>"$LOG"
	dmesg >"$RAMDIR/dmesg-before-fw.txt" 2>/dev/null

	say "Remote processors before:"
	rproc_report | tee -a "$LOG"
	for r in /sys/class/remoteproc/remoteproc*; do
		[ -d "$r" ] || continue
		fw="$(cat "$r/firmware" 2>/dev/null)"
		if [ -z "$fw" ] || { [ ! -e "$FWDST/$fw" ] && [ ! -e "/lib/firmware/$fw" ]; }; then
			say "  ${r##*/}: wants '$fw' which is not available - not started."
			continue
		fi
		if [ "$(cat "$r/state" 2>/dev/null)" = running ]; then
			say "  ${r##*/}: already running."
			any_running=1
			continue
		fi
		say "  ${r##*/}: starting ($fw) ..."
		echo start >"$r/state" 2>>"$LOG" || say "    start request failed: see dmesg"
		started=1
	done
	if [ "$started" = 1 ]; then
		say "Waiting up to 40 s for remote processors..."
		for ((i = 0; i < 20; i++)); do
			sleep 2
			if [ "$i" -ge 3 ] && grep -qx running /sys/class/remoteproc/remoteproc*/state 2>/dev/null; then
				break
			fi
		done
	fi
	grep -qx running /sys/class/remoteproc/remoteproc*/state 2>/dev/null && any_running=1

	say "Giving the battery manager 20 s to appear..."
	for ((i = 0; i < 10; i++)); do
		battery_report | grep -q 'no battery' || break
		sleep 2
	done

	ensure_data
	say "Remote processors after:"
	rproc_report | tee -a "$LOG"
	say "Battery:"
	battery_report | tee -a "$LOG"
	dmesg >"$RAMDIR/dmesg-after-fw.txt" 2>/dev/null
	diff "$RAMDIR/dmesg-before-fw.txt" "$RAMDIR/dmesg-after-fw.txt" | grep '^>' | grep -iE 'remoteproc|adsp|cdsp|battmgr|pmic_glink|qcom_|firmware|adreno|gpu' | tail -n 40 | tee -a "$LOG"

	say "GPU note: the GPU needs the zap firmware present at boot; that is tested in a later build. (No driver is unbound here: on X1E the display and GPU are one msm DRM aggregate.)"

	if [ "$any_running" = 1 ]; then
		prog_set fw_result ok
	else
		prog_set fw_result loaded-no-rproc
		say "No remote processor reached 'running'. See the with-firmware recon and dmesg for why."
	fi
	flush_log
}

step_withfw() {
	local fwr
	fwr="$(prog_get fw_result)"
	if [ "$fwr" != ok ] && [ "$fwr" != loaded-no-rproc ]; then
		say "No firmware was loaded; skipping the with-firmware recon."
		return 0
	fi
	ensure_data
	run_recon with-firmware
}

record_check() { # key question hint watcher-mode seconds
	local key="$1" question="$2" hint="$3" mode="${4:-}" secs="${5:-15}" det="" out=""
	ui_msg "$question" "$hint

Press Enter, then do it within $secs seconds."
	if [ -n "$mode" ]; then
		say "Watching input events ($mode) for $secs s..."
		out="$(python3 "$RAMDIR/evwatch.py" "$mode" "$secs" 2>/dev/null)"
		det="$(echo "$out" | sed -n 's/^RESULT|//p' | tr '\n' ';')"
		[ -n "$det" ] || det="no events seen"
		say "  detected: $det"
	fi
	ui_menu "$question" "Detected: $det

What did you observe?" yes "Yes, it worked" no "No / nothing happened" skip "Skip / not applicable"
	answer "$key" "$REPLY" "$det"
}

ps_snapshot() {
	local p
	for p in /sys/class/power_supply/*; do
		[ -d "$p" ] && printf '%s online=%s status=%s\n' "${p##*/}" "$(cat "$p/online" 2>/dev/null)" "$(cat "$p/status" 2>/dev/null)"
	done
}

drm_snapshot() {
	local c
	for c in /sys/class/drm/card*-*; do
		[ -e "$c/status" ] && printf '%s=%s\n' "${c##*/}" "$(cat "$c/status" 2>/dev/null)"
	done
}

step_checks() {
	local before after ev out start
	mkdir -p "$RES"
	write_evwatch
	{
		echo "# /proc/bus/input/devices names"
		grep -E '^(N: Name|H: Handlers)' /proc/bus/input/devices
		if command -v libinput >/dev/null 2>&1; then
			libinput list-devices 2>&1 | grep -E '^(Device|Kernel|Capabilities)'
		fi
	} >"$RES/$TS-input-devices.txt" 2>&1

	record_check builtin_keyboard "Built-in keyboard" "Type a few keys on the BUILT-IN keyboard (not an external one)." key 15
	record_check touchpad "Touchpad" "Move a finger on the touchpad and click it." touchpad 15
	record_check touchscreen "Touchscreen" "Touch and drag on the screen with a finger." touchscreen 15

	# lid: block logind from suspending while we watch
	ui_msg "Lid switch" "Next: close the lid, wait 2 seconds, then open it again.

The guide blocks suspend while it watches (20 s). The screen may go dark while closed."
	say "Watching SW_LID for 20 s..."
	if command -v systemd-inhibit >/dev/null 2>&1; then
		out="$(systemd-inhibit --what=handle-lid-switch --who=sl7-guide --why="lid test" --mode=block python3 "$RAMDIR/evwatch.py" lid 20 2>/dev/null)"
	else
		out="$(python3 "$RAMDIR/evwatch.py" lid 20 2>/dev/null)"
	fi
	out="$(echo "$out" | sed -n 's/^RESULT|//p' | tr '\n' ';')"
	[ -n "$out" ] || out="no SW_LID events"
	say "  detected: $out"
	ui_menu "Lid" "Detected: $out

Did the screen react to the lid (or did you see lid events above)?" yes "Yes" no "No" skip "Skip"
	answer lid "$REPLY" "$out"

	ui_msg "Keyboard backlight" "Press the keyboard backlight key (Fn + the backlight key, or the dedicated key) a few times.

Nothing is written to any LED by this guide."
	ui_menu "Keyboard backlight" "Did the keyboard backlight change?" yes "Yes" no "No" skip "Skip / no key"
	answer kbd_backlight "$REPLY" "key pressed by user; no LED writes"

	# charger
	ui_msg "Charger" "Next: UNPLUG the charger, wait 5 seconds, then PLUG it back in. We watch for 30 s.

Stay on battery only briefly."
	before="$(ps_snapshot)"
	say "Charger watch (30 s)..."
	start="$(date +%s)"
	ev="$(timeout 30 udevadm monitor --kernel --subsystem-match=power_supply 2>/dev/null | grep -c change)"
	after="$(ps_snapshot)"
	ensure_data
	{
		echo "before:"
		echo "$before"
		echo "after:"
		echo "$after"
		echo "power_supply change events: $ev over $(($(date +%s) - start)) s"
	} | tee -a "$LOG" >"$RES/$TS-charger.txt"
	ui_menu "Charger" "power_supply change events seen: $ev

Did the plug/unplug show up (events > 0)?" yes "Yes, I did it and events appeared" no "I did it, but no events" skip "Skip"
	answer charger "$REPLY" "events=$ev"

	# USB-C display
	if ui_yesno "USB-C display" "Do you have a USB-C / DisplayPort display or dock you can plug in now?" n; then
		before="$(drm_snapshot)"
		ui_msg "USB-C display" "Plug the display into a USB-C port, wait about 15 seconds, then press Enter."
		after="$(drm_snapshot)"
		{
			echo "before:"
			echo "$before"
			echo "after:"
			echo "$after"
		} | tee -a "$LOG" >"$RES/$TS-drm-connectors.txt"
		if [ "$before" != "$after" ]; then
			answer usbc_display yes "connector status changed"
		else
			answer usbc_display no "no drm connector status change"
		fi
	else
		answer usbc_display skip "no display available"
	fi
	flush_log
}

step_suspend() {
	local fwr ms b0 b1 u0 u1 s0 s1 dir
	fwr="$(prog_get fw_result)"
	ms="$(cat /sys/power/mem_sleep 2>/dev/null)"
	if [ -z "$ms" ]; then
		say "Suspend test skipped: /sys/power/mem_sleep does not exist."
		return 0
	fi
	if [ "$fwr" != ok ]; then
		say "Suspend test skipped: firmware step did not succeed (fw_result=${fwr:-none})."
		return 0
	fi
	if ! ui_yesno "Suspend test (optional)" "A short suspend test. mem_sleep = $ms

This system has no RTC alarm, so it cannot wake itself. The guide will:
 1. save counters, then run 'systemctl suspend'
 2. the screen goes dark
 3. wait about 2 minutes, then press the POWER BUTTON (or open the lid)
 4. the guide records qcom_stats and the battery energy delta

RISKS: resume on this machine is experimental. If it does not wake after 5 minutes, hold the power button 10 s; everything already saved on the stick stays.

Run the suspend test?" n; then
		answer suspend skip "declined"
		return 0
	fi
	ensure_data
	dir="$RES/$TS-suspend"
	mkdir -p "$dir"
	if ! mountpoint -q /sys/kernel/debug 2>/dev/null; then
		mount -t debugfs nodev /sys/kernel/debug 2>/dev/null && echo "debugfs mounted by guide" >>"$LOG"
	fi
	stats_dump "$dir/qcom_stats-before.txt"
	b0="$(battery_energy)"
	s0="$(date +%s)"
	u0="$(suspended_secs)"
	echo "$b0" >"$dir/battery-before.txt"
	sync
	say "Suspending now. Press the power button (or open the lid) after about 2 minutes."
	sleep 2
	systemctl suspend
	sleep 3
	s1="$(date +%s)"
	b1="$(battery_energy)"
	u1="$(suspended_secs)"
	ensure_data
	echo "$b1" >"$dir/battery-after.txt"
	stats_dump "$dir/qcom_stats-after.txt"
	dmesg | tail -n 200 >"$dir/dmesg-tail.txt" 2>&1
	diff "$dir/qcom_stats-before.txt" "$dir/qcom_stats-after.txt" >"$dir/qcom_stats.diff" 2>&1
	{
		echo "wall seconds across suspend: $((s1 - s0))"
		echo "kernel-reported suspended seconds: $(python3 -c "print(round($u1 - $u0, 1))")"
		echo "battery before: $b0"
		echo "battery after:  $b1"
		echo "battery delta:  $(($(echo "$b1" | cut -d' ' -f2) - $(echo "$b0" | cut -d' ' -f2))) $(echo "$b1" | cut -d' ' -f1)"
		echo "qcom_stats diff lines: $(wc -l <"$dir/qcom_stats.diff")"
	} | tee -a "$LOG" >"$dir/summary.txt"
	ui_menu "Resume" "Resume finished. Wall time across suspend: $((s1 - s0)) s.

Did the screen, keyboard and touchpad all come back?" yes "Yes, everything came back" no "Something did not" skip "Skip"
	answer suspend_resume "$REPLY" "wall=$((s1 - s0))s"
	flush_log
}

step_summary() {
	local txt s
	sync
	flush_log
	txt="Results: $RES
Session:  $TS

Step status:"
	for s in identity baseline firmware withfw checks suspend; do
		if is_done "$s"; then
			txt="$txt
  $OK $s"
		else
			txt="$txt
  $BAD $s (not done)"
		fi
	done
	txt="$txt
Firmware result: $(prog_get fw_result)

Answers:
$(cut -d'|' -f2-3 "$RES/answers.txt" 2>/dev/null)

NEXT:
 1. Type  poweroff  and press Enter. (Do not use reboot.)
 2. Wait until the screen is dark, then unplug the stick.
 3. Bring the stick back to ramius.

Do not share this stick if it holds Microsoft firmware."
	ui_msg "All done" "$txt"
	flush_log
	release_data
	say "Finished (stick unmounted). Run 'poweroff' now."
}

# ---------------------------------------------------------------- main
main() {
	local last="" resumed=no
	if ! mkdir -p "$RES" 2>/dev/null || ! data_ok; then
		echo "Cannot write to $RES. Is SL7DATA mounted read-write at $DATA?" >&2
		exit 1
	fi

	if [ -f "$PROGRESS" ] && [ -n "$(prog_get ts)" ]; then
		last="$(prog_get ts)"
		if ui_yesno "Previous run found" "An earlier run ($last) did not finish all steps:
$(grep '^step_' "$PROGRESS" | tr '\n' ' ')

Yes = resume and skip the finished steps.
No  = start a fresh run (old results stay on the stick)." y; then
			TS="$last"
			resumed=yes
		fi
	fi
	if [ -z "$TS" ]; then
		TS="$(date +%Y%m%d-%H%M%S)"
		: >"$PROGRESS"
		prog_set ts "$TS"
	fi
	SESS="$RES/$TS"
	mkdir -p "$SESS"
	[ -f "$SESS/guide.log" ] && cp "$SESS/guide.log" "$LOG"
	log "sl7-guide start session=$TS ui=$UI resumed=$resumed"

	is_done welcome || { step_welcome; step_done welcome; }
	if ! is_done identity; then
		step_identity || { flush_log; exit 0; }
		step_done identity
	fi
	is_done baseline || { step_baseline && step_done baseline; flush_log; }
	is_done firmware || { step_firmware; step_done firmware; flush_log; }
	is_done withfw || { step_withfw; step_done withfw; flush_log; }
	is_done checks || { step_checks; step_done checks; flush_log; }
	is_done suspend || { step_suspend; step_done suspend; flush_log; }
	step_summary
}

main "$@"
