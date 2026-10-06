# omarchy-surface-sl7

Omarchy add-on package for the Microsoft Surface Laptop 7 (Snapdragon X Plus/Elite,
DT `x1e80100-microsoft-romulus13` and `-romulus15`) on Arch Linux ARM.

It is made only of files, pacman hooks and drop-ins. It depends on `omarchy`,
`linux-sl7`, `iptsd-sl7` and `linux-firmware-qcom`, is in the group
`omarchy-platform-qualcomm`, and works when installed by pacman at any point
(pacstrap or later). It does not depend on how the installer or ISO is built and
needs no change to Omarchy. License: MIT for our files (see `LICENSE`);
the bundled `sl7-mac` pieces are MIT too (`LICENSE.sl7-mac`).

**No firmware is in this package.** The Microsoft/Qualcomm files are installed on the
target by `qcom-firmware-extract` (a dependency, used by the installer) or by
`omarchy-surface-sl7-firmware` (item 7, manual fallback).

## What it installs

| # | What | Files |
|---|---|---|
| 1 | initramfs modules and firmware hook | `/etc/mkinitcpio.conf.d/zz-omarchy-surface-sl7.conf`, `/usr/lib/initcpio/install/sl7-firmware` |
| 2 | neutralise upstream `fix-surface-keyboard.sh` | `/usr/share/libalpm/hooks/70-omarchy-surface-sl7-keyboard.hook`, `/usr/lib/omarchy-surface-sl7/neutralize-surface-keyboard` |
| 3 | kernel command line, `ENABLE_UKI`, UKI device trees | `/etc/limine-entry-tool.d/omarchy-surface-sl7.conf`, `85-omarchy-surface-sl7-dtbs.hook`, `/usr/lib/omarchy-surface-sl7/update-uki-dtbs`, `/usr/lib/omarchy-surface-sl7/set-boot-order` |
| 4 | touch resume | `/usr/lib/systemd/system-sleep/omarchy-surface-sl7`, `/usr/lib/omarchy-surface-sl7/restart-iptsd` |
| 5 | factory Wi-Fi/BT MAC | `/usr/bin/sl7-mac`, `sl7-wifi-mac.service`, `sl7-bt-mac.service`, `99-sl7-bt-mac.rules` |
| 6 | no Pro Audio on the speaker card | `/usr/share/wireplumber/wireplumber.conf.d/50-omarchy-surface-sl7.conf`, `.../scripts/omarchy-surface-sl7/guard-pro-audio.lua` |
| 7 | firmware installer | `/usr/bin/omarchy-surface-sl7-firmware` |
| 8 | power | `/usr/lib/udev/rules.d/99-omarchy-surface-sl7-power.rules`, `/usr/lib/omarchy-surface-sl7/power-event`, `/usr/bin/omarchy-surface-sl7-power`, `/usr/bin/omarchy-sl7-powermode`, `omarchy-surface-sl7-powermode.service`, `/usr/lib/systemd/user/omarchy-sl7-powermode.service`, `/etc/omarchy-surface-sl7/power.conf`, `/usr/bin/sl7-powertest`, `/usr/bin/sl7-powermeter` |
| 8d | optional kernel test boot entries, PSR (known broken), VRR (experimental) and the IR emitter test boot (`ir-test`), off by default | `/usr/bin/omarchy-sl7-test-entry`, `/usr/bin/omarchy-sl7-psr-entry` (wrapper), `/etc/boot/hooks/post.d/80-omarchy-sl7-test-entry` |
| 8g | IR emitter load gate and the disabled Stage B channel test tool (section 11c) | `/usr/lib/modprobe.d/omarchy-surface-sl7-ir.conf`, `/usr/bin/sl7-ir-emitter-test` |
| 8e | IR/RGB camera Phase A probe, read-only | `/usr/bin/sl7-ir-probe` |
| 8h | opt-in USB runtime PM, one dwc3 controller at a time, off by default (section 8h) | `/usr/bin/sl7-usb-rpm`, `/usr/lib/udev/rules.d/80-omarchy-sl7-usb-rpm.rules`, `/etc/omarchy-surface-sl7/usb-rpm.conf` |
| 8i | real panel refresh rate: vblank loop, or the read-only DPU frame counter as root (section 8i) | `/usr/bin/sl7-vrr-rate` |
| 9 | Omarchy leaf script, reference only | `/usr/share/doc/omarchy-surface-sl7/upstream/install/hardware/microsoft/surface-laptop-7.sh` |
| 10 | `.install` scriptlet | `omarchy-surface-sl7.install` |

### 1. initramfs

`MODULES+=` adds `surface_aggregator surface_aggregator_registry surface_aggregator_hub
surface_hid_core surface_hid msm dispcc-x1e80100 gpucc-x1e80100 phy-qcom-edp panel-edp
ps883x pmic_glink pmic_glink_altmode ucsi_glink qrtr i2c-hid-of leds_qcom_lpg`, every
entry suffixed `?` (optional) so the stock `linux-aarch64` rescue UKI still builds.
All were checked against `linux-sl7-7.2.8-1` (modules, none built in). `ath12k` is kept
out: it probes before its firmware is reachable and does not retry (runs 4/5).

The GPU firmware goes in through the `sl7-firmware` mkinitcpio hook (appended with
`HOOKS+=`), not `FILES+=`. `FILES` fails the build when a file is missing or only exists
as `.zst`/`.xz`. The hook looks for `qcom/gen70500_sqe.fw`, `qcom/gen70500_gmu.bin` and
`qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn` in `/usr/lib/firmware/updates` then
`/usr/lib/firmware`, as plain, `.zst` or `.xz`, adds whichever exists, and only warns
for the rest. A missing zap shader warns loudly: the panel stays black.

### 2. `fix-surface-keyboard.sh` (upstream PR #8151)

Omarchy's script runs when `omarchy-hw-surface` matches (it does on the SL7, vendor
"Microsoft Corporation"). If `lsmod` shows a `pinctrl_*` module (ALARM-style kernels
build the LPASS pinctrl as modules), it writes
`/etc/mkinitcpio.conf.d/surface_device_modules.conf` with
`MODULES=(... surface_kbd intel_lpss_pci 8250_dw)`. That assignment resets `MODULES` and
names modules that do not exist on arm64, so mkinitcpio fails. PR #8151 is the open
upstream change; until it merges (and a Qualcomm guard is added) we defend in layers:

1. **The drop-in filters.** `zz-omarchy-surface-sl7.conf` sorts after
   `surface_device_modules.conf` (`s` before `z`), appends our modules, then removes
   `surface_kbd`, `intel_lpss_pci`, `8250_dw`, every `pinctrl_*` and duplicates from `MODULES`. This is the
   protection that works even if Omarchy regenerates the file later.
2. **The pacman hook moves the file aside.** `70-omarchy-surface-sl7-keyboard.hook`
   (PostTransaction, Install/Upgrade) fires when the `omarchy` package replaces
   `usr/share/omarchy/install/hardware/fix-surface-keyboard.sh`, or when our drop-in is
   installed, and renames the generated file to
   `surface_device_modules.conf.disabled-by-omarchy-surface-sl7` when
   `omarchy-hw-qualcomm-soc` is true (or the device tree is not visible, as in a chroot).
   A pacman hook cannot trigger on the generated file itself: pacman only matches
   files that packages ship. The `.install` scriptlet also runs it.
3. The script itself is never modified.

The upstream fix is a guard `omarchy-hw-qualcomm-soc && return 0` at the top of the
script; `surface-laptop-7.sh` shows the leaf that would replace this package's work.

### 3. Command line, UKI, device trees

- `/etc/limine-entry-tool.d/omarchy-surface-sl7.conf` appends
  `cpufreq.default_governor=schedutil fw_devlink.sync_state=timeout console=tty0` and sets
  `ENABLE_UKI=yes`. Omarchy's own drop-ins keep supplying quiet boot and
  `clk_ignore_unused pd_ignore_unused arm64.nopauth systemd.tpm2_wait=0`; we do not
  duplicate them. If `/etc/default/limine` explicitly sets `ENABLE_UKI=no`, the
  scriptlet warns.
- `/etc/default/limine` is read after the drop-ins, so a drop-in cannot change
  `BOOT_ORDER`; `set-boot-order` (run from the scriptlet, idempotent) prepends
  `linux-sl7` to it and keeps `linux-aarch64` as a later rescue entry.
- **Device trees.** `linux-sl7` keeps its DTBs in `/usr/lib/modules/<kver>/dtbs/qcom`;
  Omarchy's `qualcomm/dtb-uki.sh` reads `/boot/dtbs/qcom`, where `linux-aarch64`'s
  romulus DTBs lack the touchpad/touchscreen nodes. `update-uki-dtbs` copies the newest
  linux-sl7 romulus13/15 DTBs over those two files (the original is kept once as
  `.dtb.alarm-orig`, which the `*.dtb` glob ignores) and writes the DeviceTreeAuto block
  from `/boot/dtbs/qcom` with dtb-uki.sh's exact markers (`# BEGIN/END OMARCHY QUALCOMM
  DEVICE TREES`, verified against omarchy@dragon 4a7fc751). dtb-uki.sh lists every x1*
  tree there, a superset that contains the same romulus files, so whichever runs last is
  correct. `85-omarchy-surface-sl7-dtbs.hook` fires on `linux-sl7` or `linux-aarch64`
  install/upgrade, before `90-mkinitcpio-install`. `update-uki-dtbs --print` is a dry run.

### 4. Touch

`iptsd-sl7` already ships `iptsd@.service` and `50-iptsd.rules`, which start
`iptsd@<hidraw>` for both devices (touchpad `045E:0C77`, touchscreen `045E:0C6E`) via
`iptsd-check-device`, so nothing needs enabling. Missing was the resume fix (run 5:
after resume the virtual touchpad went static while the raw HID node kept sending).
iptsd's own `system-sleep` script only re-triggers udev `add`, which does not restart a
running unit. Our hook, on `post`, schedules (`systemd-run --on-active=2`, so spi-hid has
re-initialised) `restart-iptsd`, which finds the hidraw nodes by `HID_ID` (vendor
`045E`, product `0C77`/`0C6E`) and restarts their `iptsd@dev-hidrawN.service`.

### 5. Wi-Fi/Bluetooth MAC

Ships [valeronm/sl7-mac](https://github.com/valeronm/sl7-mac) (MIT) at a pinned commit,
fetched at build time with a checksum (license permits redistribution, we keep its
LICENSE). The WCN7850 has no burned-in address: ath12k invents a random MAC each boot and
Bluetooth comes up as `00:00:00:00:5A:AD`, unconfigured and ignored by BlueZ. The Surface
UEFI variable `MacAddressEmulationAddress-b7f95555-...` (read-only via efivarfs) holds
the factory Ethernet address (base+2); Wi-Fi is base+0, Bluetooth base+1.
`sl7-wifi-mac.service` (enabled via a `sysinit.target.wants` link) stages a runtime
systemd `.link` before udev coldplug; `sl7-bt-mac.service` is pulled in by udev when
`hci0` appears and sets the public address over the BlueZ management socket. Evidence for
the -2/-1 scheme: the author's unit plus one more SL7 13.8" X Plus owner
(bryce-hoehn/linux-surface-laptop-7#21). **Decision: enabled by default**, because without
it Bluetooth does not work at all; both units skip themselves (`ConditionPathExists`)
when the variable is absent. Opt out: `systemctl mask sl7-wifi-mac.service sl7-bt-mac.service`.
Manual: `sl7-mac status`, or `ETH_MAC=` in `/etc/default/sl7-mac`.
It replaces the planned separate `sl7-mac-fixup` package.

### 6. Audio safety

WirePlumber never auto-selects `pro-audio`, but a stored or clicked selection is honoured
and Pro Audio bypasses the UCM mixer setup (a pre-7.1 kernel lost an owner's right
speakers this way, linux-surface#1590). WirePlumber 0.5 has no property to hide a
profile, so `guard-pro-audio.lua` (loaded from the conf.d snippet) matches the card by
`X1E80100` or `Romulus` in its names and (a) replaces a selected `pro-audio` with the
best other profile before it is applied, which also defeats a stored Pro Audio choice at
boot, and (b) reverts it if something sets Pro Audio on a running card. The profile still
appears in a mixer UI; selecting it is undone at once (a momentary switch is possible).
This is a belt and braces measure; never run a kernel without the 7.1 volume cap.

### 7. Firmware installer

```
sudo omarchy-surface-sl7-firmware --from-msi SurfaceLaptop7_ARM_Win11_26100_26.053.36539.0.msi
sudo omarchy-surface-sl7-firmware --from /path/to/stage      # stage/qcom/x1e80100/microsoft/...
omarchy-surface-sl7-firmware --status
```

Installs uncompressed into `/usr/lib/firmware/updates/qcom/x1e80100/microsoft/`: the zap
shader `qcdxkmsuc8380.mbn` (in `microsoft/`, not `Romulus/`), `Romulus/{qcadsp8380.mbn,
adsp_dtbs.elf,qccdsp8380.mbn,cdsp_dtbs.elf}` (required) and `Romulus/*.jsn` plus the Iris video
firmware `Romulus/qcvss8380.mbn` (optional, see 7b). `updates/` is searched before
`/usr/lib/firmware`, so the kernel finds it at `qcom/x1e80100/microsoft/Romulus/qcvss8380.mbn`.
Each file is checked against an embedded sha256 list for MSI 26.053.36539.0 before
anything is installed (all-or-nothing); `--allow-unverified` overrides for a newer MSI.
`--from-msi` needs `msiextract` (msitools); pymsi is not supported. Afterwards it runs
`limine-mkinitcpio`, or `mkinitcpio -P`, unless `--no-rebuild`. Omarchy's own
`qcom-firmware-extract` puts the zap shader in `Romulus/`, where mainline does not look;
use this tool for the SL7.

### 8. Power (small, safe, partly opt-in)

- `99-omarchy-surface-sl7-power.rules`: on `change` of `qcom-battmgr-bat`, `power-event`
  runs `udevadm trigger --action=change` on `qcom-battmgr-usb` and `qcom-battmgr-ac`
  (those that exist), because the firmware sends no event for charger plug/unplug and
  UPower's OnBattery otherwise goes stale (Omarchy's shell never switches profiles).
  Root-owned paths only.
- **Opt-in** Wi-Fi power save (Omarchy forces it off): `sudo omarchy-surface-sl7-power
  wifi-powersave enable` writes a NetworkManager drop-in (`wifi.powersave = 1`, ignore) and a
  flag file; `power-event` then runs `iw dev <wlan> set power_save on|off` by power
  source. Needs `iw`. `disable` reverts. Not enabled by default.
- **AC/battery power mode** (`omarchy-sl7-powermode`, config
  `/etc/omarchy-surface-sl7/power.conf`, enabled by default; `ENABLE=no` turns it off).
  `power-event` runs it as root on every battery change event, at boot
  (`omarchy-surface-sl7-powermode.service`) and shortly after resume. On battery it caps every
  cpufreq policy's `scaling_max_freq` (2188800 kHz), caps the GPU devfreq `max_freq` at the
  middle entry of `available_frequencies`, turns Wi-Fi power save on and sets the platform
  profile to `low-power` if the kernel has one (linux-sl7 does not build the Surface driver, so
  that is normally a no-op). On AC all of it returns to hardware maximum, Wi-Fi power save off,
  profile `balanced`. Writes are idempotent. The user part, a user service
  (`omarchy-sl7-powermode.service`, enabled globally for `graphical-session.target`) subscribes
  to UPower's `OnBattery` over D-Bus and to Hyprland's socket, and switches `eDP-1` to 60 Hz on
  battery and back to the original rate on AC with `hyprctl eval hl.monitor(...)`
  (`hyprctl keyword` does not work with the Lua parser). It never edits `monitors.lua`. It
  re-applies after a config reload, which would otherwise undo the 60 Hz mode. The refresh
  switch is opt-in (`REFRESH_ON_BATTERY=60`): on the SL7 a rate change is a full modeset and the
  panel blanks for a few seconds on every plug/unplug, so the default leaves it alone. Animations and
  blur can optionally be switched off on battery (`DISABLE_*_ON_BATTERY=yes`). Only when
  booted through the VRR test entry (section 11b) it also sets Hyprland's `misc.vrr`
  (`HYPRLAND_VRR`). Omarchy has no
  hook for its own `omarchy-powerprofiles-set`, which only calls power-profiles-daemon (no
  backend on ARM), so this runs beside it on the same signal and does not change the PPD
  profile. Restart the user part after editing the config:
  `systemctl --user restart omarchy-sl7-powermode`. Check with `omarchy-sl7-powermode status`
  or `sl7-doctor`. Wi-Fi: NetworkManager re-applies its own setting (off) when a connection is
  re-activated; run `sudo omarchy-surface-sl7-power wifi-powersave enable` to stop that.

### 8f. Touchpad defaults (tap-to-click off)

Hyprland's default tap-to-click gave false left clicks and repeated right clicks (a
two-finger tap) during two-finger scrolls on the SL7. Omarchy's defaults
(`default/hypr/input.lua`) belong to `omarchy-settings` and `~/.config/hypr/input.lua` is the
user's own file, so there was no existing mechanism: `omarchy-sl7-touchpad-defaults` (run by
`omarchy-sl7-touchpad-defaults.service`, a user unit wanted by `graphical-session.target`, so
it covers new installs at first login and existing ones at the next login after the update)
appends

```
hl.config({ input = { touchpad = { tap_to_click = false } } })
```

to `~/.config/hypr/input.lua` under a comment, once, and applies it to the running Hyprland
with `hyprctl eval` (never a config reload). It does nothing while `input.lua` is missing
(retried at the next login) or when `input.lua` already sets `tap_to_click` itself, and after
the first run a state file (`~/.local/state/omarchy-surface-sl7/touchpad-defaults`) stops it
from ever editing the file again, so removing the block or setting `true` sticks. The block is
Lua in the user's file, so anything below it wins. Run it by hand with
`omarchy-sl7-touchpad-defaults`, preview with `--check`. `sl7-doctor` warns while it is pending.

### 8h. USB runtime PM (opt-in): `sl7-usb-rpm`

Off by default. The dwc3 core calls `pm_runtime_forbid()` at probe, so the three controllers sit
at `power/control = on` and never suspend. Awake that keeps their interconnect votes (the
`a400000` and `a800000` controllers each vote 1 GB/s average, 2.5 GB/s peak on DDR), their
GDSCs and their PHY and master clocks on. Setting `auto` lets `dwc3-qcom` runtime-suspend them
when nothing is attached or busy (its suspend path drops those votes and has wake IRQs on the
DP/DM/SS lines). The estimated gain is 50 to 200 mW for all three; not measured on the SL7.

```
sl7-usb-rpm status
sudo sl7-usb-rpm enable a400000 [--record]    # runtime only, until reboot
sudo sl7-usb-rpm disable a400000 [--forget]   # write power/control=on again
sudo sl7-usb-rpm enable-all-tested            # what the udev rule does at boot
```

Controllers: `a400000.usb` is `usb_mp`, the USB-A port behind the PTN3222 repeater;
`a600000.usb` and `a800000.usb` are the two USB-C ports. Put a stick in each port and look at
`lsusb -t` to confirm which is which. The `.usb` suffix is optional.

- `enable` writes `power/control = auto` and `power/autosuspend_delay_ms` (default 2000, from
  `usb-rpm.conf`) for the controller and its xHCI child, one controller per call, after a
  `sync`. It changes nothing on disk.
- `--record` adds the controller to `USB_RPM_TESTED_OK` in `/etc/omarchy-surface-sl7/usb-rpm.conf`
  (a pacman backup file). Only listed controllers get `auto` at boot: the udev rule
  `80-omarchy-sl7-usb-rpm.rules` runs `sl7-usb-rpm udev-env` on the controller and xHCI platform
  devices (`add` and `bind`; `bind` comes after the probe that forbids runtime PM) and sets the
  attributes only when that prints a match. The shipped list is empty, so the rule does nothing
  until you opt in.
- `disable` writes `on` (the rollback). `--forget` also drops it from the list. To turn it all off,
  empty `USB_RPM_TESTED_OK` and reboot.

**Warning.** Val Packett's Dell Latitude 7455 (same SoC family) shut the whole machine down with
runtime PM on all four of its controllers and was fine with three (lore
`20260221105245.19328-1-daniel@quora.org`, Linaro arm64-laptops issue 14). Never enable them all
at once to try. Save your work, enable one controller, use it (plug and unplug, a DP alt mode
monitor, charging and USB-C role swaps, wake from suspend by a USB keyboard), then `--record` it
and go on to the next. The SL7 has three dwc3 controllers in use (the fourth, `usb30_tert`, is
unused), which is not the 7455 layout, so nothing here says that all three are safe.

Measuring one controller with `sl7-powermeter` (SYS rail, battery, same Wi-Fi, backlight pinned at
30%, nothing plugged into the ports being tested):

```
sl7-powermeter --log usb-a1.jsonl --seconds 180 --label usb-on     # baseline, control=on
sudo sl7-usb-rpm enable a400000
sleep 30                                                           # let it suspend
sl7-usb-rpm status                                                 # runtime_status must be suspended
sl7-powermeter --log usb-b1.jsonl --seconds 180 --label usb-auto
sudo sl7-usb-rpm disable a400000
sl7-powermeter --log usb-a2.jsonl --seconds 180 --label usb-on
sl7-powermeter --compare usb-a1.jsonl usb-b1.jsonl                 # then a2 against b1
```

Alternate A B A B for three rounds and treat a difference below about twice the run-to-run spread
as no change. If `runtime_status` stays `active`, something is holding the controller (a plugged
device that does not autosuspend, or a hub): unplug everything from that port and retry. Next
controller only after this one looks fine.

### 8i. Real refresh rate: `sl7-vrr-rate`

`hyprctl monitors` shows the mode rate (120) whether or not VRR works, and the kernel's vblank
counters stop when nobody holds a vblank reference. `sl7-vrr-rate` measures the rate at the panel
side of the pipe.

```
sl7-vrr-rate -s 10                 # vblank wait loop, no root
sudo sl7-vrr-rate --hw -s 10       # DPU hardware frame counter, read-only
sl7-vrr-rate --json -s 10          # one JSON object, for logs
```

- **vblank (default).** Loops `DRM_IOCTL_WAIT_VBLANK` (relative 1) on the eDP card and timestamps
  each return in userspace. The kernel's vblank timestamps assume the fixed mode rate, so only the
  userspace clock is used. It holds a vblank reference (the vsync IRQ stays on) but causes no
  commits. It finds the CRTC of eDP with read-only mode ioctls (`--crtc N` overrides). Output is
  the effective rate over the window plus the interval spread.
- **`--hw` (root).** Maps the eDP INTF block (INTF_5, physical `0x0AE3A000`) through `/dev/mem`
  with `PROT_READ` only and reads `INTF_FRAME_COUNT` (offset `0x0AC`) once a second; it also
  prints `INTF_AVR_CONTROL`, `INTF_AVR_MODE` and the AVR VTOTAL to VSYNC period ratio (about 5.0
  with AVR programmed). It never writes. It refuses to run unless the device tree has the DPU at
  `0x0ae01000` and an enabled eDP controller with an aux-bus panel at `0x0aea0000`, the DPU and
  its parent are runtime-active, eDP is connected and enabled, `INTF_VSYNC_PERIOD_F0` is non zero
  and the frame counter is enabled. Run it with the screen on: reading a powered-down DPU can
  hang the SoC. It needs `CONFIG_STRICT_DEVMEM` without `IO_STRICT_DEVMEM` (the ALARM config).

#### VRR test procedure

Plan: three readings of the refresh rate, an eyes-on flicker check, then a power A/B. All legs on
the VRR entry so the kernel is the same.

1. Boot "linux-sl7 (VRR test)" (`sudo omarchy-sl7-test-entry enable vrr`, section 11b). Check that
   `/sys/module/msm/parameters/vrr_enabled` is `Y`, `sl7-doctor` shows `vrr_capable=1`, and
   `hyprctl getoption misc:vrr` reads 1.
2. Kernel: `sudo sl7-vrr-rate --hw -s 10` hands-off. Expect `avr_ctrl` bit 0 = 1, mode 0, ratio
   about 5.0. If AVR is not programmed, the gating chain failed (`crtc_state->vrr_enabled`, the
   EDID monitor range). If it is programmed but idle still reads 120 Hz, look at bit 31 of
   `avr_ctrl` (status) and report it.
3. Live rate with `sl7-vrr-rate` (either method): hands-off, expect about 24 Hz with a blip a
   minute from the bar clock; with the mouse circling, about 120 Hz; `mpv --video-sync=display-resample`
   on a 24 fps file, 24 or 48 Hz; and one run on the normal entry, 120 Hz.
4. Hyprland VRR on and off at runtime, never written to your config:

   ```
   hyprctl eval 'hl.config({ misc = { vrr = 0 } })'
   hyprctl eval 'hl.config({ misc = { vrr = 1 } })'
   hyprctl getoption misc:vrr -j | jq .int
   ```

   The user service of `omarchy-sl7-powermode` sets `misc.vrr` from `HYPRLAND_VRR` on this entry
   and re-applies it after a config reload, so for the `vrr 0` legs set `HYPRLAND_VRR=` (empty)
   in `/etc/omarchy-surface-sl7/power.conf`, restart it (`systemctl --user restart
   omarchy-sl7-powermode`) and switch by hand. Use `vrr = 1` only: a VRR change is a full modeset
   (the panel blanks for a few seconds), and `vrr = 2` would modeset on every fullscreen toggle.
5. Flicker check at the low rate (eyes on the panel, the 24 Hz floor of an LCD can pulse in dark
   grey): with `vrr = 1`, hands-off, show a static dark grey full screen and a grey gradient, for
   example `mpv --fs --no-osc --keep-open=always 'av://lavfi:color=c=0x303030:s=2304x1536:d=0.1'`
   and the same with `gradients=s=2304x1536:speed=0`. While it is up, confirm with
   `sl7-vrr-rate` from another terminal that the rate really is low (move nothing). Look for
   flicker or brightness pulsing, black frames, cursor lag. If it flickers, the minimum rate
   needs raising (a kernel parameter clamp or an EDID override with a 30 or 40 Hz range; not
   part of this package yet).
6. Power A/B with `sl7-powermeter`, battery, backlight 30%, same Wi-Fi, nothing playing, three
   alternating rounds, the live rate logged next to each run:

   ```
   sl7-powermeter --log vrr-a1.jsonl --seconds 180 --label vrr0-120hz   # (a) misc.vrr 0, 120 Hz
   sl7-powermeter --log vrr-b1.jsonl --seconds 180 --label vrr0-60hz    # (b) misc.vrr 0, 60 Hz mode
   sl7-powermeter --log vrr-c1.jsonl --seconds 180 --label vrr1-120hz   # (c) misc.vrr 1, 120 Hz
   sl7-vrr-rate -s 20                                                   # beside each run
   sl7-powermeter --compare vrr-a1.jsonl vrr-c1.jsonl
   ```

   The 60 Hz leg is a modeset: use `REFRESH_ON_BATTERY=60` in `power.conf` with the machine on
   battery (the powermode service does the switch), and set it back to empty afterwards. Then one
   leg of (a) on the normal entry to check that patch 0024 costs nothing when off, then a
   30 minute `sl7-powertest idle` gauge run of the winner against (a). Expect (c) to beat (a) by
   roughly 0.35 to 0.5 W if AVR works (an estimate from the 60 Hz difference, not a measurement).

### 9. Upstream leaf

`surface-laptop-7.sh` (installed under `/usr/share/doc`) is an Omarchy-style
`install/hardware/microsoft/surface-laptop-7.sh` doing the same via drop-ins, for
upstreaming. The package does not run it.

### 10b. Battery for Omarchy (TEMPORARY, omacom/omarchy#13029)

Omarchy's `omarchy-battery-status`/`-present` match only `BAT*`; the SL7 battery is
`qcom-battmgr-bat`. The bar reads UPower (works); the panel detail comes from
`omarchy-battery-status`. Omarchy puts its own bin dir first in PATH, so a PATH override is
impossible; `82-omarchy-sl7-battery.hook` runs `omarchy-sl7-battery-patch` after each
`omarchy` install/upgrade (idempotent, no-op once upstream fixes the line). Also makes the
negative `power_now` absolute. Remove both files and their PKGBUILD lines when #13029 lands.

### 7b. Hardware video (Iris)

linux-sl7 7.2.8-13 enables the Iris codec (patch 0086) with the Microsoft signed
`qcom/x1e80100/microsoft/Romulus/qcvss8380.mbn`. Get it with `omarchy-surface-sl7-firmware`
(the file is optional there, so a staging directory made before it existed still installs); the
installer kit stages it too. It is not in the initramfs hook on purpose: `iris` is a module that
loads after the root filesystem is mounted, like the ADSP and CDSP images that the hook also
leaves out. Generic Qualcomm images (`qcom/vpu/vpu30_p4.mbn` and friends) may exist in
`linux-firmware-qcom`; they are signed for other boards and the SL7 uses the OEM signed file, as
Surface firmware is OEM signed.

The result is two V4L2 stateful (memory-to-memory) devices, `qcom-iris-decoder` and
`qcom-iris-encoder`. Decode: H.264, HEVC, VP9, AV1. Encode: H.264, HEVC. It is not VA-API, so
apps need a V4L2 path. Examples (copy mode, because the frames go back to system memory):

```
mpv --hwdec=v4l2m2m-copy clip.mp4
ffmpeg -c:v h264_v4l2m2m -i clip.mp4 -f null -          # decode (also hevc_v4l2m2m)
ffmpeg -i clip.mp4 -c:v h264_v4l2m2m -b:v 8M out.mp4    # encode (also hevc_v4l2m2m)
gst-launch-1.0 filesrc location=clip.mp4 ! qtdemux ! h264parse ! v4l2h264dec ! fakesink
gst-launch-1.0 videotestsrc num-buffers=300 ! video/x-raw,format=NV12 ! v4l2h264enc ! h264parse ! fakesink
```

(`h264_v4l2m2m` and `hevc_v4l2m2m` need an ffmpeg built with `--enable-v4l2-m2m`; Arch Linux ARM's
is. Use `v4l2h265dec` and `v4l2h265enc` for HEVC in GStreamer. AV1 and VP9 decode need a
GStreamer or ffmpeg build whose V4L2 decoder lists those formats.) Browsers: Firefox has an
ffmpeg V4L2-M2M decode path (since 116, written for the Raspberry Pi); Mozilla bug 1852765
reports it listed as supported but not used with the Qualcomm Venus decoder, so assume software
decode in Firefox until `about:support` shows otherwise. Chromium's V4L2 video decoder is
a ChromeOS feature: on ARM Linux it is not officially supported and needs your own build with
`use_v4l2_codec=true`. Do not expect browser hardware decode on the SL7 today; mpv, ffmpeg and
GStreamer are the way to use it. Status: untested on hardware.

### 11. `sl7-doctor`

Read-only check (`/usr/bin/sl7-doctor`): running kernel and DT, 3 cpufreq policies, SAM
modules in the initramfs, firmware, iptsd units, `BOOT_ORDER`, uki.conf, no active
`surface_device_modules.conf`, Pro Audio guard, and the power mode (current source, caps
applied, whether they match the source), PSR state (`msm.psr_enabled`, whether this boot
used the PSR test entry, PSR debugfs nodes and dmesg lines when readable; informational only)
and VRR state (`msm.vrr_enabled`, whether this boot used the VRR test entry, the eDP
`vrr_capable` property from `modetest`, debugfs `vrr_enabled`, Hyprland's `vrr`; read-only),
the Iris firmware file, the video-codec node status and the iris V4L2 decoder/encoder devices
(INFO, or WARN when the firmware is missing or the devices fail to appear; never a failure),
the pending tap-to-click default (8f) and, from the journal, how often iptsd's mode watchdog had to
re-enable touchpad multitouch this boot (warn only).
Exit 1 on any failure.

### 11b. Optional kernel test entries (`omarchy-sl7-test-entry`)

Extra Limine entries that boot the same UKI with extra kernel parameters, for experiments that
must not be in the normal command line. The default entry, `default_entry` and `BOOT_ORDER` are
never touched. All are disabled by default.

```
sudo omarchy-sl7-test-entry enable psr|vrr|ir-test|NAME [PARAMS...]   # add "linux-sl7 (NAME test)"
sudo omarchy-sl7-test-entry disable NAME                      # remove it
omarchy-sl7-test-entry list                                   # presets, state, and what is in limine.conf
sudo omarchy-sl7-test-entry cleanup                           # remove every test entry and its state
omarchy-sl7-test-entry status [NAME]
```

Presets: `psr` = `msm.psr_enabled=1`, `vrr` = `msm.vrr_enabled=1`, `ir-test` = `sl7.ir_test=1 panic=5`
(entry "linux-sl7 (IR test)", fixed parameters, section 11c). Any other NAME needs PARAMS.
`omarchy-sl7-psr-entry enable|disable|status` still works (it calls the `psr` preset). The old r6
`psr-entry.enabled` state file, hook and block are removed on upgrade (`cleanup --legacy`);
PSR is not carried over.

How it works: limine-entry-tool has no per-entry command line variants, and it rewrites
`limine.conf` on every UKI rebuild. So `omarchy-sl7-test-entry` copies the live linux-sl7 entry
(same UKI path and hash, same `cmdline:`) into marked blocks
(`### BEGIN/END omarchy-sl7-test-entry NAME`) directly after it, with the parameters appended.
`/etc/boot/hooks/post.d/80-omarchy-sl7-test-entry` (a limine-entry-tool post hook; it runs
before `90-limine-enroll-config`) re-creates the blocks after every regeneration, so the hash
and cmdline stay in sync. The `cmdline:` line overrides the UKI's embedded command line
through systemd-stub load options, which it honours while Secure Boot is off (the SL7 setup).
If the override were ignored, `sl7-doctor` shows "normal boot entry" after choosing a test
entry. If `ENABLE_ENROLL_LIMINE_CONFIG=yes`, `enable`/`disable` re-enroll the config.

Fallback if an entry misbehaves: in the Limine menu press `e` on the normal entry and append
the parameter to the cmdline for one boot (the editor is disabled when a config hash is
enrolled).

#### PSR (`psr`): KNOWN BROKEN

The Sharp LQ138P1JX61 reports PSR1 support (eDP DPCD 0x070 = 01), but with `msm.psr_enabled=1`
the panel turns off (black) when the screen is idle and comes back only when something paints.
Tested on real hardware via the "linux-sl7 (PSR test)" entry. Do not enable PSR in the normal
command line. The entry stays only to retest after a kernel update.

#### VRR (`vrr`): EXPERIMENTAL

linux-sl7 patch 0024 (scuggo's `msm-vrr-avr.patch`, rebased) adds eDP variable refresh to the
msm driver: the eDP connector gets `vrr_capable`, the DPU INTF Adaptive Refresh block is
programmed for the EDID range (24-120 Hz) and the DP link sets MSA timing ignore. All of it is
behind `msm.vrr_enabled`, default 0, so a normal boot behaves exactly as before. Needs
linux-sl7 `7.2.8-2` or later.

Test steps:

1. `sudo omarchy-sl7-test-entry enable vrr`, reboot, pick "linux-sl7 (VRR test)".
2. `sl7-doctor` must show `msm.vrr_enabled=1` (running kernel), "booted via the VRR test
   entry" and `eDP vrr_capable=1`. With `vrr_capable=0` or missing, stop: the kernel did not
   expose VRR (check `dmesg | grep -i -E 'dp|dpu|msm'`).
3. Hyprland needs VRR on at runtime (`misc.vrr`: 0 off, 1 always, 2 fullscreen only). The
   power mode user service does this by itself on this entry (`HYPRLAND_VRR=1` in `power.conf`;
   empty or 0 to disable). By hand:
   `hyprctl eval 'hl.config({ misc = { vrr = 1 } })'` (back: `vrr = 0`). It is a runtime
   setting, never written to your config.
4. Observe: `hyprctl monitors -j | jq '.[] | {name, vrr, refreshRate}'` (`vrr` is true while
   active; `refreshRate` is the current mode rate, so it does not show the instantaneous VRR
   rate), and as root `grep -r vrr_enabled /sys/kernel/debug/dri/*/state`. Run something that
   renders at a varying rate (a game, `mpv` video, `glxgears` unthrottled) and watch for
   tearing-free, steady output. `sl7-doctor` prints all of these.
   For the real instantaneous rate use `sl7-vrr-rate` (section 8i).
5. Look for: flicker or brightness pulsing at low rates (the panel can drop to 24 Hz), black
   frames or blanking (link problems; check `dmesg`), cursor lag, resume failures.
6. Power: on battery, `sl7-powertest idle --minutes 20 --label vrr`, then the same from the
   normal entry with `--label normal`, then `sl7-powertest compare ...-normal.jsonl ...-vrr.jsonl`
   (VRR does not lower an idle desktop's refresh by itself; the gain is for varying content).
7. Done: `sudo omarchy-sl7-test-entry disable vrr` and boot the normal entry.

### 11c. IR emitter test boot and `sl7-ir-emitter-test` (Stage A and B of the IR emitter plan)

Plan: `research/omarchy-dragon-sl7/ir/EMITTER-PLAN.md`. The IR illuminator is a PM8550 flash LED on
an unknown channel. This is the build-only part: **nothing in this package fires the emitter.**

**What exists.** linux-sl7 patch 0080 (leds-qcom-flash IR safety) and 0081 (romulus13 DT) describe
four IR LEDs, `ir:flash-1` to `ir:flash-4`, one per PM8550 flash channel, each limited to 12.5 mA
flash and a 10 ms hardware timer, torch refused. They are in the DTB of every boot entry but can
bind only on the IR test boot entry.

**The gate (two independent layers).**

1. `/usr/lib/modprobe.d/omarchy-surface-sl7-ir.conf` has an `install leds_qcom_flash` rule. Without
   `sl7.ir_test=1` on `/proc/cmdline` it exits 0 without loading the module (quiet for udev's alias
   load, nothing binds). With it, it loads the module with `ir_test=1`.
2. The driver itself refuses to bind to a node set that holds an IR LED unless its module
   parameter `ir_test` is set (read-only at run time), before touching any register. So an
   `insmod` or `modprobe --ignore-install` on a normal boot still binds nothing.

The command line token comes from the entry: `sudo omarchy-sl7-test-entry enable ir-test` adds
"linux-sl7 (IR test)" with `sl7.ir_test=1 panic=5` appended (`disable ir-test` and `cleanup` remove
it). The normal entry never carries it. Kill switch at the Limine menu: `module_blacklist=leds_qcom_flash`.
If the module was already loaded before the rule applied (initramfs), `modprobe -r leds_qcom_flash`
then `modprobe leds_qcom_flash` on the test entry.

**Stage A check (read-only, no approval needed).**

```
sl7-ir-emitter-test --status
```

Normal boot: approval absent, `sl7.ir_test=1: no`, `leds_qcom_flash: not loaded`, 0 `ir:flash-*`
LEDs, and `ls /sys/class/leds | grep ir:` empty. IR test boot: `ir_test=Y` and 4 LEDs, each with
`max_flash_brightness=12500` and `max_flash_timeout=10000`. `dmesg | grep 'SL7 snapshot'` shows the
read-only PMIC register snapshot taken at probe. Note: `echo 255 > .../ir:flash-N/brightness`
returns success (the LED core queues brightness writes), but the driver refuses it ("SL7: torch
refused on the IR emitter LED") and the channel stays off.

**Stage B tool, disabled.** `sl7-ir-emitter-test --i-have-read-the-plan --channel N [--repeat R]`
fires one 12.5 mA x 10 ms pulse (R = 1..3, 1 s apart) on one channel through the LED class sysfs
(`flash_strobe=0`, `flash_brightness=12500`, `flash_timeout=10000`, `flash_strobe=1`, 50 ms,
`flash_strobe=0`, then `flash_fault`). It refuses unless **all** of these hold, checked in this
order:

1. **`/etc/omarchy-surface-sl7/ir-stage-b-approved` exists** (regular file, root-owned, not
   writable by group or others, not a symlink). No package ships it, nothing creates it and the
   tool never removes it. Only Chris creates it by hand, after reading the plan:
   `sudo mkdir -p /etc/omarchy-surface-sl7 && echo "approved by Chris $(date -I)" | sudo tee /etc/omarchy-surface-sl7/ir-stage-b-approved`
   and removes it when Stage B is done.
2. It runs as root on the IR test entry (`sl7.ir_test=1` and `panic=5` on the command line,
   `leds_qcom_flash` loaded with `ir_test=Y`), with `ir:flash-N` present and every `ir:flash-*`
   at `flash_strobe=0`, `max_flash_brightness <= 12500`, `max_flash_timeout <= 10000` and no fault
   other than `flash-timeout-exceeded`.
3. It is the only run (lock), at most 12 pulses this boot (counter in `/run`), on an interactive
   terminal, and the typed phrase `FIRE CHANNEL N` is entered after the safety checklist.

Every action (each write, read back and fault read) is logged to
`/var/log/sl7-ir-emitter-test.log` and the journal (tag `sl7-ir-emitter-test`). On any error,
signal or exit it writes `flash_strobe=0` to every `ir:flash-*` LED. The limits are constants in
the script: no option raises them. Without the approval file, as shipped, the tool exits 3 and
touches nothing.

**`--watch` (IR camera detector).** `sudo sl7-ir-emitter-test --i-have-read-the-plan --channel N
--repeat 3 --watch` adds the VD55G0 as a detector to the same run (every gate, the 3 pulses per run,
the 12 per boot and the typed phrase are unchanged). It needs `sl7-ir-bridge` active (checked, clear
error otherwise), `v4l-utils` and `python3`. After the confirmation it captures from
`/dev/v4l/by-id/sl7-ir-camera` with `v4l2-ctl` into a private directory under `/run`, waits for the
black frame and 35 real frames (about 1 s, auto-exposure settling), fires, keeps capturing 1 s, then
computes the mean and 99th percentile of every frame (frame 0 is the bridge's black frame and is
skipped). The baseline is the median of the lead frames; a frame is flagged when its mean or p99 is
more than 5 robust SDs (MAD) above it, and flags are matched to the logged FIRE times (window from
35 ms before to 150 ms after, since the loopback frame arrives after the exposure). Verdict per
channel: `DETECTED` (every pulse spiked, 3 of 3), `WEAK` (some) or `NONE`. Setup: white paper about
5 cm in front of the camera, angled so light from beside the lens bounces back, dim room, do not
move. A 10 ms pulse can fall between exposures, so `NONE` is not proof that a channel is dark.
No image is ever saved: only the per-frame statistics (a CSV next to the log, plus the summary lines
in the log and journal) are kept, and the raw capture is deleted on exit. `--watch-only-test`
captures with no pulses to check that the baseline is stable (`STABLE`/`UNSTABLE`); it touches no
LED and needs no approval file, but still the root, IR test entry and bridge. Exit code 8 is a
`--watch` problem (bridge, capture or analysis).

**IR stage A safety fix (omarchy-surface-sl7 26, with linux-sl7 7.2.8-14).** The PMIC safety timer
very likely counts (n + 1) x 10 ms while the stock driver writes n = timeout / 10, so a requested
10 ms would have run about 20 ms. Patch 0080 now programs n - 1 for IR LEDs, so the hardware pulse
equals the requested 10 ms. The tool's comments and confirmation text now state the effective
charge: one pulse is 12.5 mA x 10 ms = 0.125 mC, about 11 % of Windows' 700 mA x 1.59 ms = 1.11 mC
per lit frame (the old "1.8 %" is the current only). Limits (12.5 mA, 10 ms, 3 pulses per run, 12
per boot) are unchanged. Needs linux-sl7 7.2.8-14 or later for the encoding fix; on 7.2.8-13 the
same run is about 20 ms, 0.25 mC.

### 12b. Camera probe: `sl7-ir-probe` (Phase A of IR face unlock)

Read-only check of the camera stack on a `linux-sl7` 7.2.8-3 or later kernel on the 13.8 inch
model (`romulus13`): CAMSS, CCI0/1, CSIPHY0/4 and camcc probe state, the IR sensor (ST VD55G0,
i2c `0x10` on CCI0: the driver reads model id `0x53354730` and applies the firmware patch before
it binds), the front RGB OV02C10 (i2c `0x36` on CCI1), the kernel messages about both,
`media-ctl -p`, and then a 30 frame IR capture (Y8/GREY 644x604 when the sensor offers `Y8_1X8`, else
Y10/Y10P; the codes come from the sensor subdev) with per-frame statistics, followed by a 10 frame
raw RGB capture through CSID1 and VFE1 RDI0 (`/dev/video4`, OV02C10 `SGRBG10_1X10` 1928x1092 as
`pgAA`) that is reported as INFO only, since libcamera already drives the RGB camera. Everything
goes to `~/sl7-ir-test/` (`probe-*.txt`, `media-ctl-p.txt`, `dmesg.txt`, `ir.raw`) and ends with
a `SUMMARY` of PASS/FAIL/INFO lines. It never writes to an LED class device, a flash strobe or a
sensor GPIO: the illuminator is not described in this release and is not touched. It needs
`v4l-utils` (optdepends) and re-runs itself with `sudo` for `dmesg`.

```
sl7-ir-probe                       # probe, topology, capture 30 frames
sl7-ir-probe --no-capture          # probe state and topology only
sl7-ir-probe --frames 100 --out ~/ir
sudo sl7-ir-probe --sweep-mclk     # also look for the camera master clock (see below)
sudo sl7-ir-probe --mclk-hz 24000000   # rebind the sensor with another MCLK rate, then capture
sl7-ir-probe --y10                 # force the 10 bit IR format (Y10_1X10 / Y10P)
sudo sl7-ir-probe --debug          # dynamic debug, vb2 debug=2 and interrupt deltas around the captures
```

The capture builds on `media-ctl -r` (reset links), sets the format pad by pad and checks it on the
RDI source pad before streaming. It reads the real `bytesperline` and `sizeimage` from `v4l2-ctl
--get-fmt-video`, and counts a capture as PASS only when `v4l2-ctl` printed no `returned -1`,
`timeout` or `VIDIOC_` error and the file holds at least frames x sizeimage bytes. The kernel log
shown is only what appeared since the capture began, with the media graph walk and pipeline debug
lines (`walk:` and friends) filtered out; they stay in the raw `dmesg.txt`. The IR section also
prints the `vd55g` clock tree line (linux-sl7 7.2.8-7 and later, logged at each stream start) and
every `vd55g` error from the capture (`enable streams: <step> failed`, `poll reg ... timed out`,
`s_ctrl ... failed`). `--debug` enables dynamic debug for
`qcom_camss`, `phy_qcom_mipi_csi2`, `vd55g`, `mc-entity.c` and `v4l2-subdev.c`, sets
`videobuf2_common` debug=2, lists the `csid|vfe|csiphy|ace4000` interrupt counter deltas in the
report and turns everything off again. If frames time out, the next MCLK to try is 24 MHz (Windows
says 24 MHz): `sudo sl7-ir-probe --mclk-hz 24000000`. `--mclk-hz` keeps `mclk_index=-1` (the device tree
clock), writes the `mclk_hz` module parameter and rebinds the sensor; with linux-sl7 7.2.8-7 and
later the driver then retunes the device tree clock to that rate (the parameter is read at probe,
no module reload). `mclk_hz=0`, the default, leaves the device tree rate alone.

The IR module's master clock is not named by any Windows resource. The device tree starts with
MCLK0 (gpio96) at 19.2 MHz. `--sweep-mclk` is the only mode that changes anything: it sets the
`vd55g` module parameters `mclk_index` (0 to 3 for MCLK0..3 on gpio96..99, -2 for no clock) and
`mclk_hz`, rebinds the sensor for each candidate and stops at the first that answers; if none does
it restores `mclk_index=-1`. By hand: `echo 1 | sudo tee /sys/module/vd55g/parameters/mclk_index`,
then unbind and bind `/sys/bus/i2c/drivers/vd55g/<bus>-0010`. Nothing is persistent: a reboot
returns to the device tree values.

### 12. Measuring power: `sl7-powertest`

Run as your user, on battery, charger unplugged, battery between 30% and 90%. It only reads
sysfs. For the run it pins the backlight (`brightnessctl`, default 30%, `--brightness PCT`)
and holds an idle/sleep inhibitor so hypridle does not dim or lock; both are restored on exit
and on Ctrl-C.

```
sl7-powertest idle --minutes 20 --label before
sl7-powertest video clip.mp4 --minutes 30 --hwdec no --label sw
sl7-powertest suspend            # prints the procedure, changes nothing
sl7-powertest compare A.jsonl B.jsonl
```

Watts come from the `energy_now` delta between two gauge updates: the tool waits for a fresh
update before starting and before stopping the clock (the gauge goes stale), so the error is
one 10 mWh step over the window (about +/-0.03 W at 20 minutes, +/-0.02 W at 30). `power_now`
(absolute value) is logged as a cross-check. Every 5 s it records `energy_now`, `power_now`,
capacity, per-policy `scaling_cur_freq`, cpuidle time and entry deltas, GPU devfreq `cur_freq`
and the eDP mode; once a minute the top 5 CPU processes and Wi-Fi power save. The first record
is the configuration (refresh rate, governor and caps, Wi-Fi power save, brightness, kernel
command line, monitors, Bluetooth, power mode) with a hash; `compare` lists what differs.
Output goes to `~/.local/state/sl7-powertest/` (JSONL plus a `.summary.json`).

Before/after a change (for example the power mode):

```
# 1. baseline: ENABLE=no in power.conf, then: sudo omarchy-sl7-powermode ac
sl7-powertest idle --minutes 20 --label before
# 2. change one thing (ENABLE=yes, then: sudo omarchy-sl7-powermode battery)
sl7-powertest idle --minutes 20 --label after
sl7-powertest compare ~/.local/state/sl7-powertest/*-before.jsonl ~/.local/state/sl7-powertest/*-after.jsonl
```

Change one variable per run, repeat each setting three times in alternating order, and keep
the same Wi-Fi network. While the power mode is enabled, plug/unplug events and resume re-apply it by themselves;
that is why the baseline sets `ENABLE=no` first. The user part also holds 60 Hz: for a
"before" run at 120 Hz, `systemctl --user stop omarchy-sl7-powermode` as well and run
`omarchy-sl7-powermode ac`.

### 12d. Live power rails: `sl7-powermeter`

Needs linux-sl7 7.2.8-12 or newer. Runs as your user, no root, and only reads the hwmon device
`qcom_pld_power`: a read-only view of the SoC firmware's power ring (the region Windows feeds to
its Energy Meter). The kernel driver is ItsLucas's, carried as linux-sl7 patches 0082 and 0083
(see the linux-sl7 README).

```
sl7-powermeter                               # live view, refreshed every second like watch
sl7-powermeter --once                        # one snapshot
sl7-powermeter --log idle-a.jsonl --seconds 120 --label a
sl7-powermeter --log idle-b.jsonl --seconds 120 --label b
sl7-powermeter --compare idle-a.jsonl idle-b.jsonl
sl7-powermeter --describe                    # the rails and the accuracy limits
```

`--log` samples once a second (`-n S`, at least 0.5) and prints mean, standard deviation, min and
max per rail; `--compare` prints the difference per rail with a noise threshold (twice the standard
error, floored at 0.01 W) and the configuration differences. It also records the battery gauge's
`power_now` while on battery, so SYS can be checked against the gauge. A log file is never
overwritten.

The rails, as the source defines them:

| Rail | What it is |
|---|---|
| `CPU_CLUSTER_0`, `_1`, `_2` | CPUs 0-3, 4-7 and 8-11, mapped by affinity loads on a 15 inch X1E-80-100. On an X1P-64-100 cluster 2 should be the 3-core one (unconfirmed) |
| `GPU` | Adreno GPU. In the Windows metadata; response under a dedicated GPU load not yet validated |
| `PSU_USB` | Power input side. Semantics unverified; equalled SYS on external power with the battery not charging |
| `USBC_TOTAL` | USB-C ports total. Semantics unverified |
| `SYS` | The firmware's system power figure, the nearest thing to a whole-machine number |
| `CPU_SUM` | Derived by the tool: the three clusters added. Nothing else is summed |

There is no DDR, CX or MX rail: the ring has exactly these seven channels. SYS overlaps the others
in unknown ways, so do not add rails to it or to each other.

What the readings mean and how far to trust them:

- The values are the firmware's one-second averages in 10 mW steps (the driver does not expose the
  firmware's 100 ms ring). Nothing faster than one second is visible, and sampling faster than
  that only repeats values.
- Absolute accuracy is not known: it is not established whether the firmware measures the rails or
  models them, and nobody has compared them with an external meter. Treat them as relative, good
  for an A/B of a setting in one to two minutes, and calibrate SYS against the gauge on battery.
- In the source's test the one-second values matched its 100 ms ring to about 0.02 W mean error.
  Cluster mapping and the SYS = PSU_USB observation come from one 15 inch machine (BIOS 175.235.235);
  the 13.8 inch is expected to match because the region belongs to the SoC firmware, not the board,
  but that is unproven until a Romulus13 capture exists.
- Reads fail with `ENODATA` until the firmware counter advances, for a few seconds after load and
  after resume, and with `EIO` on a torn read; the tool shows `n/a` or skips those samples. Whether
  the ring is populated on a cold Linux-only boot is unknown.

Next to the battery gauge (`sl7-powertest`): the two are independent readers and can run together.
The gauge gives watts from the `energy_now` delta over 20 to 30 minutes; the meter gives firmware
power each second. The loaded driver already refreshes its cache once a second whether or not
anything reads it, so reading adds nothing there, but a live `sl7-powermeter` wakes a CPU every
second and can raise an idle reading. For gauge runs use `sl7-powertest idle --rails` instead: it
adds `rails_w` to each 5 s record and `rails_mean_w` to the summary (shown by `compare`), with no
extra process. The watts in the summary stay the gauge's.

### 12c. Finding what blocks SoC sleep: `sl7-sleepstats --trace`

`sudo sl7-sleepstats` prints the `qcom_stats` counters (`cxsd`, `ddr` and `aosd` should count in
a deep suspend). When they stay at 0, run the guided capture on battery:

```
sudo sl7-sleepstats --trace --minutes 10
sudo sl7-sleepstats --trace --unload-suspects      # same, with the cheap holders removed
```

It writes `~/sl7-sleeptrace-<date>/` (owned by you, not root): an awake snapshot (cmd-db,
`qcom_stats` including `ddr_stats`, `interconnect_summary` and its ALWAYS/untagged-with-bandwidth
filter, `clk_summary` and its enabled filter, regulators, power domains, runtime-PM and
wakeup-enabled devices, remoteprocs, `lspci -tv`), then arms the `rpmh`, `interconnect`, `clk`,
`rpm` and `power:suspend_resume` tracepoints plus dynamic debug on `rpmh.c` and runs
`systemctl suspend`. Keep the lid closed for N minutes (default 8) and wake it with the power
button or lid. Afterwards the tracing state is restored (also on Ctrl-C) and `ANALYSIS.txt` is
printed: (a) the final RPMh sleep set with BCM votes decoded (nonzero `MC0`/`SH0`/`ACV` means DDR
is held), (b) `skipping RPMH req` addresses (`xo.lvl`/`cx.lvl` flagged), (c) `qcom_stats` and
`ddr_stats` deltas with the ADSP and CDSP wake rates, (d) ALWAYS interconnect votes that never
dropped to 0, (e) whether the two UARTs runtime-suspended, (f) whether PCIe re-initialised.

`--unload-suspects` (also valid with `--suspend-test`) stops `bluetooth.service`, removes
`qcrypto`, `hci_uart`, `btqca`, `ath12k_wifi7` and `ath12k`, and disables USB wakeup for the run, then
reloads `ath12k_wifi7` and `hci_uart`, starts Bluetooth again if it was running, and restores the
wakeup values, also after a failure. Wi-Fi and Bluetooth are off, and USB devices cannot wake the
laptop, until it finishes. `lspci` comes from the optional `pciutils`.

### 10. Scriptlet

`post_install`/`post_upgrade`: move the x86 module list aside, update the DTBs and UKI
block, put linux-sl7 first in BOOT_ORDER, warn about `ENABLE_UKI=no`, print the firmware instructions when the zap
shader is absent, then rebuild with `limine-mkinitcpio` (or `mkinitcpio -P`). The rebuild
is skipped in a chroot (pacstrap/mkarchiso; the installer builds the image) and when
`OMARCHY_SL7_SKIP_REBUILD` is set. Failures never fail the transaction.

## The omarchy-sl7 package repository

`/etc/pacman.d/omarchy-sl7.conf` defines `[omarchy-sl7]` (GitHub Release `repo-aarch64`,
`SigLevel = Required DatabaseOptional`). `/etc/pacman.conf` carries
`Include = /etc/pacman.d/omarchy-sl7.conf` above `[core]`, so `linux-sl7`, `iptsd-sl7` and
this package win over `[alarm]` and `[omarchy]`. Keeping that line is automated:

- `omarchy-sl7-repo-ensure` (idempotent; `--check` reports only) inserts or repairs it, but only
  once the signing key is trusted: a signed database from an unknown key breaks `pacman -Sy`.
- `80-omarchy-sl7-repo.hook` runs it after `omarchy`, `omarchy-settings` and `pacman` change.
- `omarchy-sl7-repo.service` runs it at boot. This is what enables the repository on a clean
  install: Omarchy's installer replaces the offline pacman.conf (which defines `[omarchy-sl7]`
  as a local directory) with its online one after our package is installed.
- `omarchy refresh pacman`: at the pinned dragon commit its aarch64 path only rewrites the
  `[omarchy]` Server line in place, so the Include survives. Omarchy has no system-wide hook
  location (`omarchy-hook` reads only `~/.config/omarchy/hooks/<name>.d/`), so as a safety net
  the package ships `10-omarchy-sl7-repo` in `/etc/skel` and the ensure script provisions it
  for existing users (`--provision-users`, run at install/upgrade and boot).
- Opt out with `touch /etc/pacman.d/omarchy-sl7.disabled`.

`sl7-doctor` checks that the repository is configured and first in order, and that the key is
trusted.

## Order for an installer

`pacstrap` with `linux-sl7`, this package (pulls `iptsd-sl7`, `linux-firmware-qcom`),
then Omarchy's hardware stage, then firmware (`omarchy-surface-sl7-firmware`), then one
initramfs/UKI build.

## Verified vs untested

Verified here (x86 host, no SL7):
- Every module in item 1 exists in the `linux-sl7-7.2.8-1` package, as a module.
- `omarchy-surface-sl7-firmware`: `--from` and `--from-msi` (stubbed `msiextract` over the
  real extracted MSI tree), checksum pass/fail, all-or-nothing install, against the real
  hashes.
- `update-uki-dtbs` (block replacement, idempotent, header handling), the neutraliser,
  `restart-iptsd` hidraw matching, the `sl7-firmware` hook's file selection, and the
  `zz` drop-in's module filtering, all against fake trees.
- `shellcheck` on all scripts; `luac -p` on the WirePlumber script; PKGBUILD packaging.

Untested on hardware:
- That `limine-mkinitcpio`/ukify turns `DeviceTreeAuto` plus the SMBIOS hwids into a UKI
  that boots (ukify's automatic `.hwids` embedding is assumed, as in Omarchy's own path).
- Hook ordering against `90-mkinitcpio-install` and the limine hook on a real upgrade.
- The resume restart actually fixing the static touchpad (timing, 2 s delay).
- `sl7-mac` on this machine (Bluetooth was not checked in run 5), and its interplay with
  Omarchy's iwd/NetworkManager MAC settings.
- The WirePlumber guard script (no SL7 card here; syntax only).
- The power rule and the opt-in Wi-Fi power save (latency impact unmeasured).
- `sl7-powermeter` and `sl7-powertest --rails`: syntax-checked only, never run. Not exercised: the hwmon
  device itself (the kernel patches 0082-0083 are compile-checked only), the live view, `--log` and
  `--compare` on real data.
- `sl7-usb-rpm` and its udev rule: shellchecked only, never run (not on the SL7, and the rule never
  applied). `sl7-vrr-rate`: syntax-checked only; the DRM ioctl layouts and register offsets are from
  the kernel headers and `dpu_hw_intf.c`, not exercised on the panel.
- `omarchy-sl7-powermode`, `sl7-powertest`: logic exercised against fake sysfs trees with
  stubbed `iw`, `hyprctl`, `brightnessctl`, `gdbus` and `mpv` (caps, idempotency, restore,
  display switch and restore, watcher events, gauge sync, Ctrl-C restore, compare). Not run on
  the SL7: that the udev change events arrive on plug/unplug and after resume, that the SCMI
  firmware honours `scaling_max_freq` below the sustained frequency on all three clusters,
  the GPU devfreq node name and OPP list, the real UPower signal and the `hl.monitor`
  refresh switch on the 2304x1536 panel (other monitor attributes such as bit depth are not
  carried over), and the gauge's real update cadence.
- Iris hardware video (patch 0086, firmware `qcvss8380.mbn`, the `sl7-doctor` Iris lines, the
  installer-kit staging): syntax and shellcheck only. Whether the Microsoft image loads and
  authenticates, and each codec, is unknown until run on the SL7.
- Not covered by this package: the ADSP late-start service, board-2 for Wi-Fi, the romulus13
  cpu fusing DTB hook.
