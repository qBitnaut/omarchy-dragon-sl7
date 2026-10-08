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
| 8b3 | bag guard: suspend, then power off, a laptop left awake with the lid closed on battery (section 8) | `/usr/bin/omarchy-sl7-bag-guard`, `omarchy-surface-sl7-bag-guard.service`, `/etc/omarchy-surface-sl7/bag-guard.conf` |
| 8d | optional kernel test boot entries, PSR (known broken) and `clk-unused` (experimental), off by default | `/usr/bin/omarchy-sl7-test-entry`, `/usr/bin/omarchy-sl7-psr-entry` (wrapper), `/etc/boot/hooks/post.d/80-omarchy-sl7-test-entry` |
| 8g | `leds_qcom_flash` kept unloaded (the PMIC IR LED path is retired), read-only `sl7-ir-emitter-test --status` and `sl7-ir-lab` (section 11c) | `/usr/lib/modprobe.d/omarchy-surface-sl7-ir.conf`, `/usr/bin/sl7-ir-emitter-test` |
| 8e | IR/RGB camera Phase A probe, read-only | `/usr/bin/sl7-ir-probe` |
| 8h | opt-in USB runtime PM, one dwc3 controller at a time, off by default (section 8h) | `/usr/bin/sl7-usb-rpm`, `/usr/lib/udev/rules.d/80-omarchy-sl7-usb-rpm.rules`, `/etc/omarchy-surface-sl7/usb-rpm.conf` |
| 8i | real panel refresh rate: vblank loop, or the read-only DPU frame counter as root (section 8i) | `/usr/bin/sl7-vrr-rate` |
| 8j | opt-in cluster parking on battery, off by default (section 8j) | `/usr/bin/sl7-park` |
| 8k | front webcam tuning built on your machine from Microsoft's driver package, and a capture/compare script (section 8k) | `/usr/bin/sl7-camera-tuning`, `/usr/bin/sl7-camera-check` |
| 12e | read-only per-process CPU and wakeup sampler (section 12e) | `/usr/bin/sl7-proftop` |
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
- Wi-Fi power save on battery, on by default with the power mode (`WIFI_PS=yes`). Omarchy
  ships `/etc/NetworkManager/conf.d/omarchy-wifi-powersave.conf` (`wifi.powersave = 2`,
  disable), and NetworkManager applies it every time a connection (re)associates, so a
  bench run on battery (bench v2, 30 min idle) found `wlan0 power save: off` 100% of the time
  although `omarchy-sl7-powermode` had asked for `on`: it only runs at boot (possibly before
  `wlan0` exists), on a battery event and after resume, and NetworkManager undid it at the next
  association. Three parts now cooperate:
  - `/usr/lib/NetworkManager/conf.d/zz-omarchy-sl7-wifi-powersave.conf` sets `wifi.powersave = 3`
    (enable; 0 default, 1 ignore, 2 disable). NetworkManager reads conf.d from every directory
    sorted by file name and later files win, so the name must sort after Omarchy's
    `omarchy-wifi-powersave.conf`; a `50-` name would lose. Run `sudo nmcli general reload conf`
    or reconnect after installing.
  - `/usr/lib/NetworkManager/dispatcher.d/90-omarchy-sl7-wifi-powersave` runs on `up` and
    `dhcp4-change` (also `dhcp6-change`, `reapply`) of a wireless interface and sets
    `iw dev <wlan> set power_save on` on battery and `off` on AC, when `power.conf` has
    `ENABLE=yes` and `WIFI_PS=yes`. NetworkManager applies its own value during activation,
    before `up`, so the dispatcher has the last word. On AC power save is therefore off again
    right after connecting.
  - `sl7-doctor` warns when power save is not on while on battery (`WARN`, not `FAIL`).
  Trade-off: a sleeping radio adds latency, tens of milliseconds on the first packet after the
  link idled (SSH keystrokes, game input, the first request of a page load). Omarchy disables
  power save for that reason and for Intel BE200/BE211 link drops; ath12k (WCN7850) on this laptop
  has the DTIM fix (linux-sl7 patch 0085, DTIM policy stick mode: the station follows the AP's
  DTIM interval), which is what makes power save usable there. Opt out: `WIFI_PS=no` stops the dispatcher and powermode, and
  `sudo ln -sf /dev/null /etc/NetworkManager/conf.d/zz-omarchy-sl7-wifi-powersave.conf` masks the
  drop-in (then Omarchy's 2 applies again). The older opt-in `sudo omarchy-surface-sl7-power
  wifi-powersave enable` still works: it writes `wifi.powersave = 1` (ignore) to `/etc`, which
  sorts after the shipped drop-in and wins, and `power-event` applies `iw` by power source.
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
  blur can optionally be switched off on battery (`DISABLE_*_ON_BATTERY=yes`). When the kernel
  runs with `msm.vrr_enabled=1` (the default, section 11b) it also sets Hyprland's `misc.vrr`
  (`HYPRLAND_VRR`: 1 always, 2 fullscreen only, empty or 0 leaves it alone). Omarchy has no
  hook for its own `omarchy-powerprofiles-set`, which only calls power-profiles-daemon (no
  backend on ARM), so this runs beside it on the same signal and does not change the PPD
  profile. Restart the user part after editing the config:
  `systemctl --user restart omarchy-sl7-powermode`. Check with `omarchy-sl7-powermode status`
  or `sl7-doctor`. Wi-Fi: NetworkManager re-applies its own setting when a connection is
  re-activated; the shipped drop-in and dispatcher script (above) make that setting
  `enable` and put the power-source policy back right after.
- **Bag guard** (`omarchy-sl7-bag-guard`, unit `omarchy-surface-sl7-bag-guard.service`, enabled by
  default, config `/etc/omarchy-surface-sl7/bag-guard.conf`). A backstop for a laptop that is
  awake in a bag: logind normally suspends on lid close, and this acts only when that did not
  happen. It polls every 15 s (sleeping in between, no wake-ups while suspended) and acts only
  while the lid is closed (logind `LidClosed`), no power source is online (any non-battery
  supply in `/sys/class/power_supply` with `online` set) and no external display is connected
  (a non-`eDP` connector with `status` `connected`), so docked or clamshell use is never
  touched. Anything it cannot read counts as "do not act". After `AWAKE_GRACE_S` (120) seconds
  awake in that state it runs `systemctl suspend`. After `MAX_SUSPEND_FAILS` (3) suspend
  attempts in a row that did not complete (`systemctl` error, or `/sys/power/suspend_stats/success`
  did not grow) it logs loudly and runs `systemctl poweroff` (there is no hibernation); a
  thermal zone above `TEMP_LIMIT_C` (60) for `TEMP_GRACE_S` (60) seconds in the same state
  powers off too. `ACTION_ON_FAIL=suspend-only` never powers off. Counters reset when the lid
  opens, a charger or external display appears, or a suspend succeeds. Every action and every
  change of decision is logged, not every poll. Check:
  `omarchy-sl7-bag-guard --check` (lid, power, displays, every thermal zone, the decision; it
  never acts; works as a normal user), `journalctl -t omarchy-sl7-bag-guard`, `sl7-doctor`.
  `ENABLED=0` leaves the service running but idle; `systemctl disable --now
  omarchy-surface-sl7-bag-guard` removes it.

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
sudo sl7-usb-rpm enable a600000 --record --force  # USB-C from boot: see the finding below
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
- `--record` is refused for the USB-C controllers (`a600000`, `a800000`) unless `--force` is also
  given; `--force --record` sets `USB_RPM_FORCE_TYPEC=1` in `usb-rpm.conf`. At boot (the udev rule
  and `enable-all-tested`) a listed USB-C controller is skipped, with a message in the journal,
  unless that variable is 1. Plain `enable` (until reboot) is always allowed.
- `disable` writes `on` (the rollback). `--forget` also drops it from the list. To turn it all off,
  empty `USB_RPM_TESTED_OK` and reboot.

**Warning.** Val Packett's Dell Latitude 7455 (same SoC family) shut the whole machine down with
runtime PM on all four of its controllers and was fine with three (lore
`20260221105245.19328-1-daniel@quora.org`, Linaro arm64-laptops issue 14). Never enable them all
at once to try. Save your work, enable one controller, use it (plug and unplug, a DP alt mode
monitor, charging and USB-C role swaps, wake from suspend by a USB keyboard), then `--record` it
and go on to the next. The SL7 has three dwc3 controllers in use (the fourth, `usb30_tert`, is
unused), which is not the 7455 layout, so nothing here says that all three are safe.

**Finding: USB-C from boot (SL7, kernel 7.2.8-17).** Runtime PM on a USB-C controller enabled at
runtime after boot works: wake on plug, idle and re-suspend were all verified on `a600000`. But
recording it so it applied from boot left both USB-C ports unable to enumerate, and one boot logged
`xHCI host controller not responding, assume dead` / `HC died` on `xhci-hcd.4.auto`. Forgetting it
(`sudo sl7-usb-rpm disable a600000 --forget`) and waking the controller restored both ports. USB-A
(`a400000`) from boot is fine. Hence the `--force` guard above: use plain `enable` for USB-C, or
accept that a forced record may leave the USB-C ports dead until you forget it.

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
the default entry; the "off" comparison needs a boot without `msm.vrr_enabled=1` (see "Turning VRR
off" in section 11b).

1. Boot the normal linux-sl7 entry (VRR is on by default, section 11b). Check that
   `/sys/module/msm/parameters/vrr_enabled` is `Y`, `sl7-doctor` shows `vrr_capable=1`, and
   `hyprctl getoption misc:vrr` reads 1.
2. Kernel: `sudo sl7-vrr-rate --hw -s 10` hands-off. Expect `avr_ctrl` bit 0 = 1, mode 0, ratio
   about 5.0. If AVR is not programmed, the gating chain failed (`crtc_state->vrr_enabled`, the
   EDID monitor range). If it is programmed but idle still reads 120 Hz, look at bit 31 of
   `avr_ctrl` (status) and report it.
3. Live rate with `sl7-vrr-rate` (either method): hands-off, expect about 24 Hz with a blip a
   minute from the bar clock; with the mouse circling, about 120 Hz; `mpv --video-sync=display-resample`
   on a 24 fps file, 24 or 48 Hz; and one run with VRR turned off, 120 Hz.
4. Hyprland VRR on and off at runtime, never written to your config:

   ```
   hyprctl eval 'hl.config({ misc = { vrr = 0 } })'
   hyprctl eval 'hl.config({ misc = { vrr = 1 } })'
   hyprctl getoption misc:vrr -j | jq .int
   ```

   The user service of `omarchy-sl7-powermode` sets `misc.vrr` from `HYPRLAND_VRR` when
   `msm.vrr_enabled=1` is set and re-applies it after a config reload, so for the `vrr 0` legs set `HYPRLAND_VRR=` (empty)
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
   30 minute `sl7-powertest idle` run of the winner against (a). Expect (c) to beat (a) by
   roughly 0.35 to 0.5 W if AVR works (an estimate from the 60 Hz difference, not a measurement).

### 8j. Cluster parking (opt-in): `sl7-park`

Off by default. With `PARK_ON_BATTERY=yes` in `/etc/omarchy-surface-sl7/power.conf`,
`omarchy-sl7-powermode` calls `sl7-park apply battery|ac` on every plug, unplug, boot and resume.
On battery it confines `user.slice` and `system.slice` to the CPUs of cluster 0 with systemd
`AllowedCPUs` (`systemctl set-property --runtime`, so nothing survives a reboot); on AC, or when
the option is `no`, it restores all CPUs. The cluster layout is read from sysfs (each cpufreq
policy's `related_cpus`), never hard-coded: an X1P-64-100 shows 0-3, 4-6 and 8-10 (CPU7 and
CPU11 fused off), an X1E-80-100 shows 0-3, 4-7 and 8-11. Kernel threads, IRQs and anything outside
the two slices keep their affinity.

```
sl7-park status                       # cluster map, park target, state, AllowedCPUs and effective cpuset
sudo sl7-park on                      # park now (manual test; ignores power source and config)
sudo sl7-park off                     # restore, only if sl7-park parked
sudo omarchy-sl7-powermode battery    # the normal path: honours PARK_ON_BATTERY
```

`omarchy-sl7-powermode status` prints a `park:` line. `omarchy-sl7-powermode auto` exits early when
`ENABLE=no` and then does not restore a manual park: run `sudo sl7-park off`.

Expected gain: about 0 at idle (the two idle clusters already sit in their deepest idle state,
RUNTIME-PLAN 4.6), up to about 0.3 W under bursty light load (browsing, chat, a terminal), where
the wakeups of three clusters collapse onto one [estimate]. Risk: latency under bursts. Everything
shares the 4 CPUs of cluster 0, so a build, many busy tabs or a
video call queues behind the rest where it would have spread over 10 cores. Turn it off with
`PARK_ON_BATTERY=no` and `sudo sl7-park off`.

Test (battery, backlight pinned, same Wi-Fi, same fixed light workload such as a looped browser
page or `mpv` of a local file, 10 minutes of warm-up):

```
sl7-powermeter --log unparked-1.jsonl --seconds 180 --label unparked   # three runs each, alternating
sudo sl7-park on
sl7-park status                                   # system.slice and user.slice effective cpuset = cluster 0
sl7-powermeter --log parked-1.jsonl --seconds 180 --label parked
sudo sl7-park off
sl7-powermeter --compare unparked-1.jsonl parked-1.jsonl
```

Compare `SYS` and `CPU_CLUSTER_0/1/2` (clusters 1 and 2 should fall), first at idle (expect no
difference) then under the workload. Also read the idle residency of the clusters in
`/sys/kernel/debug/pm_genpd/power-domain-cpu-cluster{1,2}/idle_states` (root) and watch for
latency: `sl7-proftop` while parked shows where the time goes.

### 8k. Front webcam: `sl7-camera-tuning`, `sl7-camera-check`

The front camera is an OmniVision OV02C10 (ACPI `MSHW0470`), 2 lanes on CSIPHY4, one mode,
1928x1092 at 30 fps, 10-bit Bayer. It reaches applications through libcamera's simple pipeline
and its software ISP (GPU debayer by default since libcamera 0.7.0), then PipeWire.

Out of the box libcamera has no tuning for this sensor, so the picture has no colour correction.
Microsoft ships a tuning for it in the Surface driver package. It is Microsoft's, so it is
never part of this package or this repository; `sl7-camera-tuning` reads it from the driver
package you downloaded and writes a libcamera tuning file on your machine only.

Two parts:

1. **libcamera 0.7.2-4.2 or later from the omarchy-sl7 repository** (package `libcamera-sl7`
   builds the usual `libcamera`, `libcamera-ipa`, `libcamera-tools`, `gst-plugin-libcamera` and
   `python-libcamera`). It adds the OV02C10 camera sensor helper (analogue gain in 1/16 steps,
   10-bit black level 64, from upstream patch 28362), without which AGC does not run. It is a
   plain update: `sudo pacman -Syu`. 4.2 adds a faster AGC start, a statistics window fix for the
   GPU path and reading the contrast and saturation defaults from the tuning file (see
   `pkgs/libcamera-sl7`); 4.1 is enough for colour correction alone.
2. **The tuning file**, built from the Microsoft driver package:

```
omarchy-surface-sl7-firmware --from-msi SurfaceLaptop7_ARM_Win11_26100_26.053.36539.0.msi
                                  # as root; also keeps the camera tuning in /var/lib/omarchy-surface-sl7/camera/
sudo sl7-camera-tuning            # uses that copy (or: --from-msi FILE.msi, --bin FILE)
systemctl --user restart pipewire wireplumber
sl7-camera-check                  # frames, logs and a CPU/power sample into ~/sl7-camera-<time>/
```

`sl7-camera-tuning` options:

| Option | Meaning |
|---|---|
| `--blend X` | Strength of Microsoft's colour matrices, 0 (none) to 1 (full). Default 0.7. Full strength gave a green tint and noise with libcamera's grey-world white balance on a comparable Dell sensor; 70% was the usable setting there. |
| `--set N` | Which illuminant set to use (default 1). `--list` shows what the file holds. |
| `--contrast X` | Default contrast, 0 to 2 (1 = none). Default 1.2. Written to the `Adjust` block; needs libcamera 0.7.2-4.2 or later (older versions ignore it). Applications that set the contrast control still win. |
| `--saturation X` | Default saturation, 0 to 2 (1 = none). Default 1.15. Same rules as `--contrast`. |
| `--black-level N` | Override the black level (16-bit scale, 4096 = 64 of 1023). Default: the sensor helper's (4096). See below before changing it. |
| `--dry-run` | Print the tuning file to your terminal instead of writing it. |
| `--list` | Print the sets found with their colour temperature ranges and matrices. |
| `--status` | What is installed, the blend used, whether libcamera has the sensor helper. |
| `--remove` | Delete the tuning file (libcamera falls back to no correction); `--purge` also deletes the kept copy of Microsoft's file. |

Black level: dark frames from this sensor measured about 66 on the green and blue channels at
10 bits, a little above the helper's 64 (4096). Raising it to 4352 (68) would lift the blacks
slightly, but only do it after you have measured your own unit: run `sl7-camera-check` and cover
the lens with something opaque when it asks (tape works; a partly covered lens measures a scene,
not the black level). It prints the per-site mean of the dark raw frames at 10 bits (the `raw-dark`
lines in its summary). If the dark means sit at 66 or more on every site, then
`sudo sl7-camera-tuning --black-level 4352` is reasonable; otherwise leave the default.

Where it writes: `/etc/libcamera/ipa/simple/ov02c10.yaml`. libcamera 0.7.2 looks for
`<sensor model>.yaml` in `$LIBCAMERA_IPA_CONFIG_PATH`, then `/etc/libcamera/ipa/<ipa>/`, then
`/usr/share/libcamera/ipa/<ipa>/`, with `simple` as the IPA name of the software ISP. The file
lists `BlackLevel`, `Awb`, `Ccm`, `Adjust` and `Agc` (0.7.2 has no other keys for them: grey-world
white balance and the built-in exposure control). The software ISP's colour matrix has a CPU or
GPU cost, which is why libcamera only enables it for a tuned sensor.

How the colour matrices are taken from Microsoft's file: each colour temperature range has one
3x3 matrix; the matrices of a set are stored back to back, the ranges just in front. The tool
accepts a set only if every row sums to 1, the values are sane, the ranges form an increasing
chain from about 1 K to at least 8000 K, and there is one range per matrix, and it refuses to write
anything otherwise. The gaps between ranges are taken to be interpolation zones (the usual Chromatix layout);
the tool reproduces that by emitting each matrix at both ends of its range (flat inside, linear between). A black level and
white balance reference could not be identified in the file, so libcamera's own are used.

Known limits: libcamera's EGL (GPU) debayer has an open bug where the white balance gain does not
fully reach the blue channel on some sensors (libcamera issue 355); if the picture is yellow-green
under the GPU path but fine with `LIBCAMERA_SOFTISP_MODE=cpu`, it is that. To force the CPU path
for PipeWire: `systemctl --user edit wireplumber` and add
`[Service]` / `Environment=LIBCAMERA_SOFTISP_MODE=cpu`.

#### Using the camera in a browser

The camera is a libcamera device behind PipeWire, so a browser has to use the PipeWire camera
portal, which needs `pipewire-libcamera`, `wireplumber` and `xdg-desktop-portal` (all part of an
Omarchy install except `pipewire-libcamera`: `sudo pacman -S pipewire-libcamera`, then
`systemctl --user restart pipewire wireplumber`). These settings were not verified on the SL7 yet.

- **Chromium:** open `chrome://flags/#enable-webrtc-pipewire-camera`, set it to Enabled and relaunch.
  Permanently: add `--enable-features=WebRtcPipeWireCamera` to `~/.config/chromium-flags.conf`.
- **Firefox:** `about:config`, set `media.webrtc.camera.allow-pipewire` to `true`, restart Firefox.
- **Zen** (Firefox based): the same `about:config` setting.

Choose **720p** in the web app's video settings (Meet, Teams, Jitsi and Zoom all have a resolution
or quality setting): the software ISP cost grows with the pixel count, and the sensor's single mode
is 1928x1092, so 720p is a downscale that saves power and CPU/GPU load. `sl7-camera-check` takes a
1920x1080 and a 1280x720 frame next to each other so you can see whether 720p crops or scales.

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
and VRR state (`msm.vrr_enabled` in the running kernel and on the default entry's command line, the
eDP `vrr_capable` property from `modetest`, debugfs `vrr_enabled`, Hyprland's `vrr`; INFO, WARN
when the default entry lacks `msm.vrr_enabled=1`),
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
sudo omarchy-sl7-test-entry enable psr|clk-unused|NAME [PARAMS...]   # add "linux-sl7 (NAME test)"
sudo omarchy-sl7-test-entry disable NAME                      # remove it
omarchy-sl7-test-entry list                                   # presets, state, and what is in limine.conf
sudo omarchy-sl7-test-entry cleanup                           # remove every test entry and its state
omarchy-sl7-test-entry status [NAME]
```

Presets: `psr` = `msm.psr_enabled=1`, `clk-unused` = `-clk_ignore_unused
-pd_ignore_unused clk_unused_defer` (a leading `-` removes the word from the entry's cmdline, see below).
Any other NAME needs PARAMS.
`omarchy-sl7-psr-entry enable|disable|status` still works (it calls the `psr` preset). The old r6
`psr-entry.enabled` state file, hook and block are removed on upgrade (`cleanup --legacy`);
PSR is not carried over. The former `vrr` preset is gone: VRR is on by default now, and an old
"linux-sl7 (VRR test)" entry is removed on upgrade (`cleanup --legacy`, with a copy of `limine.conf`
in `/etc/omarchy-surface-sl7/limine.conf.pre-vrr-entry-removal`). `enable vrr` only prints that. The former `usbc-flip` preset is gone the same way: linux-sl7
7.2.8-18 makes the USB-C reverse-plug fix (patch 0090) the default, and an old "linux-sl7 (USBC-FLIP
test)" entry is removed on upgrade (`cleanup --legacy`, copy of `limine.conf` in
`/etc/omarchy-surface-sl7/limine.conf.pre-usbc-flip-entry-removal`). `enable usbc-flip` only prints that. The former `ir-test` preset (IR emitter test boot) is gone
too: face unlock works on the normal boot (section 11c), and an old "linux-sl7 (IR test)" entry is
removed on upgrade (`cleanup --legacy`, copy of `limine.conf` in
`/etc/omarchy-surface-sl7/limine.conf.pre-ir-test-entry-removal`). `enable ir-test` only prints that.

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

#### VRR: on by default

linux-sl7 patch 0024 (scuggo's `msm-vrr-avr.patch`, rebased) adds eDP variable refresh to the
msm driver: the eDP connector gets `vrr_capable`, the DPU INTF Adaptive Refresh block is
programmed for the EDID range (24-120 Hz) and the DP link sets MSA timing ignore. It is behind
`msm.vrr_enabled`, which the limine drop-in `/etc/limine-entry-tool.d/omarchy-surface-sl7.conf`
adds to the normal entry's command line. Needs linux-sl7 `7.2.8-2` or later. Measured on the SL7:
the panel runs at 24 Hz idle and about 116 Hz under motion with no flicker. Chip-rail power is
unchanged; battery power is not measurable yet.

Checks:

1. `sl7-doctor` shows `msm.vrr_enabled=1` (running kernel, command line and default entry) and
   `eDP vrr_capable=1`. With `vrr_capable=0` or missing, the kernel did not expose VRR
   (`dmesg | grep -i -E 'dp|dpu|msm'`).
2. Hyprland needs `misc.vrr` at runtime (0 off, 1 always, 2 fullscreen only). The power mode user
   service sets it (`HYPRLAND_VRR=1` in `power.conf`; 2 for fullscreen only, empty or 0 to leave
   Hyprland alone). By hand: `hyprctl eval 'hl.config({ misc = { vrr = 1 } })'` (back:
   `vrr = 0`). It is a runtime setting, never written to your config.
3. Observe: `hyprctl monitors -j | jq '.[] | {name, vrr, refreshRate}'` (`refreshRate` is the mode
   rate, not the instantaneous VRR rate), as root `grep -r vrr_enabled /sys/kernel/debug/dri/*/state`,
   and `sl7-vrr-rate` for the real rate (section 8i).
4. Look for flicker or brightness pulsing at low rates, black frames or blanking (check `dmesg`),
   cursor lag, resume failures.

Upgrade: the new command line reaches the normal entry when the package regenerates the UKI and
`limine.conf` (post-upgrade `limine-mkinitcpio`); reboot to use it. An unmodified drop-in is
replaced by pacman; if you had edited it, merge the `.pacnew` (`sl7-doctor` warns when the default
entry lacks `msm.vrr_enabled=1`).

Turning VRR off: delete the `msm.vrr_enabled=1` line in
`/etc/limine-entry-tool.d/omarchy-surface-sl7.conf`, run `sudo limine-mkinitcpio` and reboot. Also
set `HYPRLAND_VRR=` in `power.conf` only if Hyprland's own `misc.vrr` should stay untouched with
the parameter present.

#### Unused clocks and domains (`clk-unused`): EXPERIMENTAL

```
sudo omarchy-sl7-test-entry enable clk-unused     # entry "linux-sl7 (CLK-UNUSED test)"
```

Boots linux-sl7 without `clk_ignore_unused pd_ignore_unused` and with `clk_unused_defer`.
Omarchy's `qualcomm-snapdragon.conf` drop-in puts the two ignore flags on every Snapdragon
cmdline (we do not set them, section 3); they stay on the normal entry. With the flag, linux-sl7
patches 0087 and 0088 (Johan Hovold's deferred disabling, see the linux-sl7 README) wait 30 s
before they disable unused clocks and power domains, so dispcc, gpucc and msm can claim theirs
first. Without `clk_unused_defer` the kernel behaves as before, so the normal entry is unchanged.

The preset's PARAMS contain two words that start with `-`: such a word **removes** that word from
the copied entry's `cmdline:` (limine-entry-tool offers no per-entry removal, so the script edits
its own copy; the normal entry and the regeneration hook are untouched). `omarchy-sl7-test-entry
status clk-unused` checks the running `/proc/cmdline` for the added word and the absence of the
removed ones.

RISK (medium): the Dell XPS 13 owner saw one boot in five freeze without the deferral
(#12441 in the plan's notes). The deferral is meant to fix that, but it is not proven on the SL7. A
frozen or garbled boot is the failure mode; the fallback is choosing the normal `linux-sl7` entry
in the Limine menu (the default entry and `BOOT_ORDER` are never changed). Needs linux-sl7
7.2.8-15 or newer: on an older kernel the unknown `clk_unused_defer` is ignored, and the entry
just has no ignore flags and no deferral, which is the risky case, so check `dmesg | grep -E
'clk: |genpd: '` for "Deferring" before trusting it.

Test: boot the entry; `cat /proc/cmdline` (no ignore flags, `clk_unused_defer` present); after 30
s `dmesg | grep -E 'clk: |genpd: '` shows "Disabling unused clocks" and "Disabling unused power
domains"; the screen stays up. A/B: three `sl7-powermeter --log FILE --seconds 180` runs on each
entry after 10 minutes idle, alternating, then `sl7-powermeter --compare`; expected 10 to 50 mW
awake [estimate]. `sl7-sleepstats --suspend-test` covers the suspend side. Done: `sudo
omarchy-sl7-test-entry disable clk-unused`.

### 11c. IR camera and emitter: `sl7-ir-lab`, `sl7-ir-emitter-test --status`

Face unlock works on the **normal boot**; there is no IR test boot entry any more. The IR emitter
is lit by the `vd55g` sensor's GPIO 1 strobe, driven through `sl7-ir-bridge` for every camera
session at Windows' timing (linux-sl7 7.2.8-22, patch 0098: exposure at most 100 lines, frame
length at least 1750 lines, whatever user space asks; the `illuminator` module parameter defaults
to 1). The earlier PMIC flash LED path (`leds-qcom-flash`, `ir:flash-14` / `ir:flash-23`) proved
to have no load (open circuit) and is retired.

- **`sl7-ir-lab`** (Omarchy launcher "SL7 IR Lab", run as your normal user): a simple live view of
  the IR camera through the bridge loopback, with the frame mean and maximum, `LIT` or `dark`
  (frame maximum), the bridge's own report for the session (`emitter ON: led_mode=flash
  exposure=100 ...`, read from its journal when your user may read it), a 10 s graph of the mean,
  Snapshot (PNG under `~/sl7-ir-lab/<timestamp>/`) and Status. Needs v4l-utils, gtk4,
  python-gobject and python-cairo (optional dependencies).
- **`sl7-ir-emitter-test --status`**: read-only, no root: the bridge state, the `vd55g`
  `illuminator` parameter, whether `leds_qcom_flash` is loaded and how many `ir:flash-*` LEDs exist
  (expected 0). Every other option exits 2: the PMIC emitter tests (`--led ir`, `--channel`,
  `--stage`, `--watch`, `--remove-snapshot`) are retired together with the approval file
  `/etc/omarchy-surface-sl7/ir-stage-b-approved` (delete it if you created it).
- **`/usr/lib/modprobe.d/omarchy-surface-sl7-ir.conf`**: keeps `leds_qcom_flash` unloaded on every
  boot (`install leds_qcom_flash /bin/true`), as before, so the IR LEDs never bind. The driver also
  refuses the IR LED nodes by itself unless its `ir_test` parameter is set.
- **Upgrading**: a leftover "linux-sl7 (IR test)" entry is removed by the package upgrade
  (`omarchy-sl7-test-entry cleanup --legacy`), with a copy of `limine.conf` in
  `/etc/omarchy-surface-sl7/limine.conf.pre-ir-test-entry-removal`. `enable ir-test` only prints
  that the entry is no longer needed.

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

**What the gauge does, measured on the SL7.** `qcom_battmgr` has no cache: every sysfs read is a
live `BATTMGR_BAT_STATUS` request. The firmware now reports `energy_now` quantized to whole
percent of `energy_full` (49590000 uWh full, so one step is about 496 mWh; at 2.4 W idle a step
comes every 12 minutes). `power_now` is not quantized: it varies continuously and is fresh on
every read. Two 25-minute idle runs both reported exactly 2.380 W, which is one step over 25
minutes, an artifact of the quantization and not a measurement. Earlier firmware (7.2.8-5) stepped
in about 10 mWh and the old method (start and stop the clock on a gauge step) relied on that.

**The method.** The headline watts are the time integral of `power_now` (absolute value,
trapezoid over the samples, one every 2 s), reported as the mean with its standard error. The
error is the sample spread over the square root of the effective sample count (reduced by the
lag-1 autocorrelation, so slow drift is not counted as many independent samples). It covers
sampling noise only; it cannot see a bias in the gauge's `power_now`. The clock starts
immediately and stops at the end of the window, with a closing sample; nothing waits for a gauge
step and nothing aborts on a stale gauge.

The `energy_now` delta is the cross-check, the only reading that does not depend on
`power_now`. The step size is detected from the run (the smallest nonzero change; snapped to
`energy_full`/100 when it matches whole percent). The gauge figure is printed with its true bound,
+/- one step over the window: about +/-1.5 W for 20 minutes at 496 mWh. With fewer than 3 steps
seen (a 20-minute idle run sees one or two) it is labelled "too coarse for this window" and is
left out of the verdict. Use a run of 40 minutes or more (3 steps at 2.4 W) when you want the
cross-check to mean something; the bound is then still about +/-0.75 W, so it only catches gross
disagreement. `--gauge-sync` restores the old start-and-stop-on-a-step mode for
firmware with small steps; with whole-percent steps it can wait up to 300 s and abort.

**Accuracy.** For A/B work, the standard error of the `power_now` integral (typically a few mW over
20 minutes, depending on how much the load moves) sets the resolution; `compare` calls a
difference real when it exceeds twice the combined standard error. Run-to-run variation
(temperature, background activity) is larger than that, so keep repeating each setting three times.

`power_now` is the gauge's own instantaneous reading, so a gain error in it is not caught by this
method; the long-window gauge cross-check, and the overnight `sl7-sleepstats --suspend-test`,
are the independent checks. Each sample records `energy_now`, `power_now`, capacity, per-policy
`scaling_cur_freq`, cpuidle time and entry deltas, GPU devfreq `cur_freq` and the eDP mode; once a
minute the top 5 CPU processes and Wi-Fi power save. The first record is the configuration (refresh
rate, governor and caps, Wi-Fi power save, brightness, kernel command line, monitors, Bluetooth,
power mode) with a hash; `compare` lists what differs, shows the gauge cross-check per run and
reads the summary's `gauge_step_mwh`, `gauge_steps`, `gauge_watts` and `gauge_error_w` fields.
Output goes to `~/.local/state/sl7-powertest/` (JSONL plus a `.summary.json`). Summaries from the
older gauge-only method still load in `compare` and are marked as legacy.

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
The gauge gives watts from the integral of `power_now` over 20 to 30 minutes (its `energy_now`
is only whole-percent, see section 12); the meter gives firmware power each second. The loaded driver already refreshes its cache once a second whether or not
anything reads it, so reading adds nothing there, but a live `sl7-powermeter` wakes a CPU every
second and can raise an idle reading. For gauge runs use `sl7-powertest idle --rails` instead: it
adds `rails_w` to each 2 s record and `rails_mean_w` to the summary (shown by `compare`), with no
extra process. The watts in the summary stay the gauge's `power_now` integral.

### 12e. Who uses CPU and wakes up at idle: `sl7-proftop`

Read-only, no root, like `pidstat`. It reads `/proc/<pid>/task/<tid>/stat` (user and system ticks)
twice, N seconds apart, and reports CPU% per process, plus the wakeups of each: `runs/s` from
`schedstat` (how often the task was put on a CPU) and `vcsw/s` (voluntary context switches, how
often it blocked by itself). It also prints per-CPU busy percent and the busiest interrupt lines of
the window.

```
sl7-proftop                               # 30 s, top 15 by CPU and the top wakers
sl7-proftop -n 60 -t 25 --group           # 60 s, merge same-named processes (two iptsd@ instances)
sl7-proftop --threads                     # per thread (Hyprland's and quickshell's threads)
sl7-proftop --watch 'iptsd|Hyprland|quickshell'   # always listed, even outside the top rows
sl7-proftop --json
```

At idle the CPU% column is near zero for everything, and the waker table is the interesting one: a
daemon that polls, a compositor frame callback or a shell animation timer shows up as thousands of
`runs/s` for almost no CPU, and every wakeup can pull a cluster out of its idle state. The SPI
lines in the interrupt list (`88c000.spi`, `a88000.spi`) show whether the touch sensors stream
while nobody touches them (RUNTIME-PLAN 4.7).

With the power meter, to attribute watts (idle desktop, battery, backlight pinned):

```
sl7-powermeter --log idle.jsonl --seconds 60 --label idle &
sl7-proftop -n 60 --group
wait
```

Repeat while scrolling on the touchpad to see iptsd under touch. A process that exits during the
window is not counted; one that starts counts from its birth. `sl7-proftop` itself uses some CPU
while it samples (not measured), which is part of the idle reading: do not run it during a
gauge-grade A/B (section 12d), only next to it for attribution.

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

`sudo sl7-sleepstats --suspend-test` runs one measured suspend: snapshot, `systemctl suspend`, wake
it with the power button, then counter deltas, hours asleep and watts. `power_now` cannot be sampled
while suspended, so watts come from the `energy_now` delta, and the SL7 firmware quantizes that to
whole percent of `energy_full` (about 496 mWh per step; see section 12). The clock therefore starts
on the current reading and stops on the first reading after the resume, with no waiting for a gauge
step. The tool checks that both readings sit on the whole-percent grid, takes the step from
`energy_full`/100 (assuming 10 mWh when they do not), and prints the bound: one step over the
window, about +/-0.05 W over 9 h and +/-0.25 W over 2 h. Under 2 h it warns that the window is too
short for the step. Use an overnight run. `--gauge-sync` restores the old start and stop on a gauge step (small-step firmware
only, waits up to 300 s per end); `--no-sync` is still accepted and is now the default.

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
- The power rule and the Wi-Fi power save policy (latency impact unmeasured).
- `sl7-powermeter` and `sl7-powertest --rails`: syntax-checked only, never run. Not exercised: the hwmon
  device itself (the kernel patches 0082-0083 are compile-checked only), the live view, `--log` and
  `--compare` on real data.
- `sl7-usb-rpm` and its udev rule: shellchecked only, never run (not on the SL7, and the rule never
  applied). `sl7-vrr-rate`: syntax-checked only; the DRM ioctl layouts and register offsets are from
  the kernel headers and `dpu_hw_intf.c`, not exercised on the panel.
- `omarchy-sl7-powermode`, `sl7-powertest`: logic exercised against fake sysfs trees with
  stubbed `iw`, `hyprctl`, `brightnessctl`, `gdbus` and `mpv` (caps, idempotency, restore,
  display switch and restore, watcher events, gauge sync, Ctrl-C restore, compare; that was the
  earlier gauge-delta `sl7-powertest`: the `power_now` integral, step detection and immediate-start
  rewrite of pkgrel 31 is syntax-checked only, as is the `sl7-sleepstats` step bound). Not run on
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
