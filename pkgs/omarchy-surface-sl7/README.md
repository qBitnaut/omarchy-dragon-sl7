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
| 8 | power | `/usr/lib/udev/rules.d/99-omarchy-surface-sl7-power.rules`, `/usr/lib/omarchy-surface-sl7/power-event`, `/usr/bin/omarchy-surface-sl7-power` |
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
`surface_device_modules.conf`, Pro Audio guard. Exit 1 on any failure.

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
- Not covered by this package: CPU/GPU frequency caps, the ADSP late-start service,
  `sl7-doctor`, board-2 for Wi-Fi, the romulus13 cpu fusing DTB hook.
