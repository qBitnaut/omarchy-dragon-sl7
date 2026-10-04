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
| 8 | power | `/usr/lib/udev/rules.d/99-omarchy-surface-sl7-power.rules`, `/usr/lib/omarchy-surface-sl7/power-event`, `/usr/bin/omarchy-surface-sl7-power`, `/usr/bin/omarchy-sl7-powermode`, `omarchy-surface-sl7-powermode.service`, `/usr/lib/systemd/user/omarchy-sl7-powermode.service`, `/etc/omarchy-surface-sl7/power.conf`, `/usr/bin/sl7-powertest` |
| 8d | optional kernel test boot entries, PSR (known broken) and VRR (experimental), off by default | `/usr/bin/omarchy-sl7-test-entry`, `/usr/bin/omarchy-sl7-psr-entry` (wrapper), `/etc/boot/hooks/post.d/80-omarchy-sl7-test-entry` |
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
adsp_dtbs.elf,qccdsp8380.mbn,cdsp_dtbs.elf}` (required) and `Romulus/*.jsn` (optional).
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
  re-applies after a config reload, which would otherwise undo the 60 Hz mode. Animations and
  blur can optionally be switched off on battery (`DISABLE_*_ON_BATTERY=yes`). Only when
  booted through the VRR test entry (section 11b) it also sets Hyprland's `misc.vrr`
  (`HYPRLAND_VRR`). Omarchy has no
  hook for its own `omarchy-powerprofiles-set`, which only calls power-profiles-daemon (no
  backend on ARM), so this runs beside it on the same signal and does not change the PPD
  profile. Restart the user part after editing the config:
  `systemctl --user restart omarchy-sl7-powermode`. Check with `omarchy-sl7-powermode status`
  or `sl7-doctor`. Wi-Fi: NetworkManager re-applies its own setting (off) when a connection is
  re-activated; run `sudo omarchy-surface-sl7-power wifi-powersave enable` to stop that.

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

### 11. `sl7-doctor`

Read-only check (`/usr/bin/sl7-doctor`): running kernel and DT, 3 cpufreq policies, SAM
modules in the initramfs, firmware, iptsd units, `BOOT_ORDER`, uki.conf, no active
`surface_device_modules.conf`, Pro Audio guard, and the power mode (current source, caps
applied, whether they match the source), PSR state (`msm.psr_enabled`, whether this boot
used the PSR test entry, PSR debugfs nodes and dmesg lines when readable; informational only)
and VRR state (`msm.vrr_enabled`, whether this boot used the VRR test entry, the eDP
`vrr_capable` property from `modetest`, debugfs `vrr_enabled`, Hyprland's `vrr`; read-only).
Exit 1 on any failure.

### 11b. Optional kernel test entries (`omarchy-sl7-test-entry`)

Extra Limine entries that boot the same UKI with extra kernel parameters, for experiments that
must not be in the normal command line. The default entry, `default_entry` and `BOOT_ORDER` are
never touched. All are disabled by default.

```
sudo omarchy-sl7-test-entry enable psr|vrr|NAME [PARAMS...]   # add "linux-sl7 (NAME test)"
sudo omarchy-sl7-test-entry disable NAME                      # remove it
omarchy-sl7-test-entry list                                   # presets and entries
omarchy-sl7-test-entry status [NAME]
```

Presets: `psr` = `msm.psr_enabled=1`, `vrr` = `msm.vrr_enabled=1`. Any other NAME needs PARAMS.
`omarchy-sl7-psr-entry enable|disable|status` still works (it calls the `psr` preset, and the
old `psr-entry.enabled` state file is honoured).

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
5. Look for: flicker or brightness pulsing at low rates (the panel can drop to 24 Hz), black
   frames or blanking (link problems; check `dmesg`), cursor lag, resume failures.
6. Power: on battery, `sl7-powertest idle --minutes 20 --label vrr`, then the same from the
   normal entry with `--label normal`, then `sl7-powertest compare ...-normal.jsonl ...-vrr.jsonl`
   (VRR does not lower an idle desktop's refresh by itself; the gain is for varying content).
7. Done: `sudo omarchy-sl7-test-entry disable vrr` and boot the normal entry.

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
- `omarchy-sl7-powermode`, `sl7-powertest`: logic exercised against fake sysfs trees with
  stubbed `iw`, `hyprctl`, `brightnessctl`, `gdbus` and `mpv` (caps, idempotency, restore,
  display switch and restore, watcher events, gauge sync, Ctrl-C restore, compare). Not run on
  the SL7: that the udev change events arrive on plug/unplug and after resume, that the SCMI
  firmware honours `scaling_max_freq` below the sustained frequency on all three clusters,
  the GPU devfreq node name and OPP list, the real UPower signal and the `hl.monitor`
  refresh switch on the 2304x1536 panel (other monitor attributes such as bit depth are not
  carried over), and the gauge's real update cadence.
- Not covered by this package: the ADSP late-start service, board-2 for Wi-Fi, the romulus13
  cpu fusing DTB hook.
