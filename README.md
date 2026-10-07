```text
                 ▄▄▄
 ▄█████▄    ▄███████████▄    ▄███████   ▄███████   ▄███████   ▄█   █▄    ▄█   █▄
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   █▀   ███   ███  ███   ███
███   ███  ███   ███   ███ ▄███▄▄▄███ ▄███▄▄▄██▀  ███       ▄███▄▄▄███▄ ███▄▄▄███
███   ███  ███   ███   ███ ▀███▀▀▀███ ▀███▀▀▀▀    ███      ▀▀███▀▀▀███  ▀▀▀▀▀▀███
███   ███  ███   ███   ███  ███   ███ ██████████  ███   █▄   ███   ███  ▄██   ███
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███
 ▀█████▀    ▀█   ███   █▀   ███   █▀   ███   ███  ███████▀   ███   █▀    ▀█████▀
                                       ███   █▀
```

# omarchy-dragon-sl7

**Omarchy for the Microsoft Surface Laptop 7 (Snapdragon X)**

> Unofficial community port. Not affiliated with or endorsed by Omarchy/Basecamp, Microsoft or Qualcomm.

The logo above is Omarchy's (MIT licensed).

This project is a thin overlay on upstream omacom/omarchy and omarchy-iso (dragon
branches). It ships its own `linux-sl7` kernel, a touchpad daemon, an add-on package
with the device glue, and a signed package repository. Firmware is fetched at install
time and never redistributed.

## Status

**Alpha.** In daily use on a 13.8" Surface Laptop 7 with a Snapdragon X Plus
(X1P-64-100, 16 GB). The X Elite models and the 15" model are untested and
best-effort: the device trees and packages cover them, but nobody has booted them.
Expect rough edges, and read [What works](#what-works) before you wipe a disk. See
[PLAN.md](PLAN.md) for the longer plan and research notes.

## What works

Measured on the 13.8" X1P. "Works" means used daily without known problems;
"Partial" means it runs with a documented gap or has not been checked as thoroughly.

| Feature | Status | Notes |
|---|---|---|
| Keyboard | Works | Surface Aggregator modules in the initramfs, so it also works at the LUKS prompt. The prompt can be blank for the first boots: type blind. |
| Touchpad | Works | `iptsd-sl7` (a fork with Surface Laptop 7 fixes). Tap-to-click is off by default (it caused false clicks while scrolling; set `tap_to_click = true` in `~/.config/hypr/input.lua` to bring it back). Drag latch keeps click-and-drag held, lift-and-continue bridges brief lifts, and a watchdog re-enables multitouch if the pad falls back to mouse mode. |
| Touchscreen | Partial | SPI touch modules only (the 13.8" unit here). Units with the I2C module are not covered. Pen is untested. |
| Display | Works | Native 2304x1536 at 120 Hz. |
| Variable refresh (VRR) | Works | 24-120 Hz, on by default (`msm.vrr_enabled=1`; Hyprland `misc.vrr` set by the power mode service). Panel measured at 24 Hz idle, about 116 Hz under motion, no flicker. No chip-rail power change; battery power not measurable yet. Off: remove the `msm.vrr_enabled=1` line from `/etc/limine-entry-tool.d/omarchy-surface-sl7.conf`, `sudo limine-mkinitcpio`, reboot. |
| Panel self refresh (PSR) | Not yet | Known broken: the panel goes black when idle. Keep it off. |
| GPU acceleration | Works | Adreno via `msm`; the zap shader comes from the Microsoft MSI. |
| Hardware video (Iris) | Experimental | Enabled in the device tree with the Microsoft signed firmware from the MSI (`omarchy-surface-sl7-firmware`); untested on hardware. V4L2 decode (H.264, HEVC, VP9, AV1) and encode (H.264, HEVC) for mpv `--hwdec=v4l2m2m-copy`, ffmpeg and GStreamer. Browsers are not expected to use it. |
| Wi-Fi | Works | WCN7850 with a board-file fix and the factory MAC restored. |
| Bluetooth | Partial | Works with the factory address restored (it does not work at all without it); less tested than Wi-Fi. |
| Audio | Partial | Speakers and microphones work with the kernel volume caps. The Pro Audio profile is deliberately blocked to protect the speakers. Headphone jack quality is unverified. |
| Battery percentage and charging | Works | `qcom_battmgr` patch for capacity; Omarchy's battery scripts are patched to see the Qualcomm gauge. |
| USB-C charging and USB 3 | Works | Both ports charge and run USB 3 (10 Gb/s), in either plug orientation (linux-sl7 7.2.8-18 or later), with DisplayPort alt mode and docks. USB4 and Thunderbolt bandwidth is not available yet. |
| Suspend and resume | Works | Deep suspend (`deep`), touch restarted after resume. See [power results](#power-and-performance-results-so-far) for the drain. |
| Front webcam | Partial | OV02C10 through libcamera's software ISP. No tuning yet, so expect poor colour. |
| IR camera | Partial | Raw capture works (ST VD55G0, 644x604 greyscale) through `sl7-ir-bridge`. |
| Face unlock | Experimental | howdy-next plus a setup app. The IR emitter is not enabled yet, so recognition needs daylight or an external IR source. |
| CPU frequency scaling | Works | All three clusters, `schedutil`, with the SCMI sustained-frequency fix. |
| Power mode on AC/battery | Works | Caps CPU and GPU frequency and enables Wi-Fi power save on battery; restores everything on AC. 60 Hz switching on battery is opt-in. |
| Firmware | Works | Fetched from Microsoft's Surface Laptop 7 driver MSI, never shipped here. |
| Hibernation | Not yet | Blocked upstream. |

## Install

### Before you start (if Windows is still installed)

Nothing needs to be captured from Windows. The firmware comes from Microsoft's public
driver MSI (step 2 below) and the Wi-Fi and Bluetooth MAC addresses are read from the
UEFI at every boot. `tools/windows/Prepare-SL7.ps1` is an optional read-only check: it
confirms the model and CPU, shows the BitLocker status (and can save the recovery key to
a USB stick), and reports the UEFI version and Secure Boot state. It uploads nothing and
changes no setting. Read the script first, then in an administrator PowerShell:

```
Set-ExecutionPolicy -Scope Process Bypass; .\Prepare-SL7.ps1          # add -WhatIf for a dry run
```

### Fresh install from the installer ISO

> The ISO is the least-tested path. The kit's own README records a full ISO build
> and a boot on the SL7 as not yet verified. If you already run Omarchy on the
> machine, [update in place](#updating-an-existing-install) instead.

The installer **wipes the disk you pick** and does not keep Windows.

1. **Get the ISO.** It is not published as a release asset (it is larger than
   GitHub's 2 GiB asset limit). Build it with the `installer-iso` workflow: push a
   change under `installer/` or `upstream.lock` to your fork, or run
   `gh workflow run installer-iso.yml`. The artifact `omarchy-sl7-installer-iso`
   holds the ISO and its `.sha256` and expires after 14 days. It consumes the
   `linux-sl7` build named in `upstream.lock`, which also expires: re-run
   `linux-sl7.yml` and update `LINUX_SL7_RUN_ID` if the download step fails.
2. **Get the firmware.** On any Linux machine (x86 or arm) or macOS, run
   `tools/installer-kit/get-sl7-firmware.sh`. It downloads Microsoft's Surface Laptop 7
   driver MSI, checks its pinned sha256, extracts it with `msiextract` (`msitools`) and
   writes `./sl7-msi` (or `$SL7_MSI`) in the layout the kit reads
   (`extracted/ProgramFiles64Folder/SurfaceUpdate` and `SHA256SUMS.extracted`). Pass
   `--msi FILE` to use an MSI you already have. The stick carries firmware for your own
   device: do not share it. Skip this step with `--no-firmware` only if you accept that the
   installer then looks for a Windows driver store, which is gone after the wipe. On a
   system that is already installed, the add-on's own `omarchy-surface-sl7-firmware`
   does the same job (`--from-msi FILE`).
3. **Write the stick** (16 GB or larger) from an Arch-based host:
   ```
   sudo pacman -S --needed dosfstools mtools util-linux python github-cli
   tools/installer-kit/make-install-usb.sh --device /dev/sdX --from-ci latest
   tools/installer-kit/make-install-usb.sh --device /dev/sdX --iso FILE   # FILE.sha256 next to it
   ```
   Check the device with `lsblk -o NAME,MODEL,SIZE,TRAN,RM`. Run it as yourself, not
   with `sudo`. It verifies the checksum, refuses non-removable devices, and makes you
   type the device path. It adds a small `SL7DATA` partition with the firmware.
4. **Secure Boot off.** Power off, hold Volume Up and press Power to enter the Surface
   UEFI, then Security > Secure Boot: None.
5. **Boot the stick.** Plug it into the **USB-A port** (the live image keeps the DSP
   driver off because starting it resets USB-C) and stay on AC power. Hold Volume Down
   while pressing Power, or pick the stick in the UEFI boot menu. Expect a black screen
   for a minute or two.
6. **Run the installer.** Choose the **internal NVMe, not the stick**, and set a LUKS
   passphrase. The unlock prompt may be blank on early boots: type the passphrase
   blind and press Enter.
7. **First boot.** Reboot without the stick. The machine should land in `linux-sl7`
   (the stock `linux-aarch64` entry stays as a rescue kernel and has no internal
   keyboard). Check with `uname -r` (contains `sl7`) and `sl7-doctor`.

Troubleshooting and the layout of the stick are in
[tools/installer-kit/README.md](tools/installer-kit/README.md).

### Updating an existing install

For an Omarchy install on a Surface Laptop 7 that was not installed from our ISO. Download,
read, then run (`curl ... | bash` also works):

```
curl -fsSLO https://github.com/qBitnaut/omarchy-dragon-sl7/raw/main/tools/bootstrap/omarchy-sl7-bootstrap.sh
less omarchy-sl7-bootstrap.sh
bash omarchy-sl7-bootstrap.sh --dry-run    # read-only preview
bash omarchy-sl7-bootstrap.sh
```

It checks the machine, fetches the repository public key and requires its fingerprint to be
`6387C619EF246F6F20C536B72C3331C78353BA04` (embedded in the script), trusts it in pacman's
keyring, adds `Include = /etc/pacman.d/omarchy-sl7.conf` above `[core]`, installs
`omarchy-sl7-keyring omarchy-surface-sl7 linux-sl7 linux-sl7-headers iptsd-sl7` in one
`pacman -Syu` transaction through Omarchy's own wrapper (so the raw-pacman update guard is
satisfied), and runs `sl7-doctor`. Every step is idempotent. `--no-install` stops before the
transaction. From then on `omarchy update` carries our packages. Clean installs from our ISO
need none of this: the installer includes `omarchy-sl7-keyring` and `omarchy-surface-sl7`
enables the repository at first boot.

If a later Omarchy change drops the repository, `sudo omarchy-sl7-repo-ensure` puts it back
(it also runs after `omarchy`/`omarchy-settings` upgrades, at boot, and from an
`omarchy refresh pacman` hook). `sl7-doctor` reports the state.

### Day to day

- `omarchy update` carries our packages (`linux-sl7`, `iptsd-sl7`, `omarchy-surface-sl7`
  and the face unlock packages), because the repository sits above Omarchy's in
  `pacman.conf`.
- After a kernel update, **power off and on** rather than rebooting. A warm reboot
  can leave some devices in a state a full power cycle clears.
- Run `sl7-doctor` after updates to check the kernel, firmware, repository and power
  state.

## Tools

All ship in `omarchy-surface-sl7` unless noted.

| Tool | What it does |
|---|---|
| `sl7-doctor` | Read-only health check: kernel and device tree, cpufreq, initramfs modules, firmware, touch, boot order, repository, power mode, PSR and VRR state. Exits 1 on failure. |
| `sl7-powertest` | Measures idle or video power from the battery gauge with a pinned brightness, and compares two runs. |
| `sl7-sleepstats` | Prints SoC sleep counters (`cxsd`, `ddr`, `aosd`); `--trace` finds what blocks deep sleep, `--suspend-test` runs a measured suspend. |
| `sl7-ir-probe` | Read-only camera probe: sensor binding, media topology and a 30-frame IR capture. |
| `omarchy-sl7-powermode` | Applies or shows the AC or battery power mode (frequency caps, Wi-Fi power save). |
| `omarchy-sl7-test-entry` | Adds optional boot entries for experiments (`psr`, `ir-test`, `clk-unused`); off by default. |
| `omarchy-sl7-faceunlock` | Face Unlock setup and face manager (Omarchy menu: Setup > Security > Face Unlock). Package `omarchy-sl7-faceunlock`. |
| `sl7-ir-bridge` | On-demand bridge from the IR camera to a stable V4L2 device, `/dev/v4l/by-id/sl7-ir-camera`. Package `sl7-ir-bridge`. |

## Power and performance results so far

Measured on the 13.8" X1P-64-100 (16 GB). Numbers are from `sl7-powertest` and the
battery gauge. The gauge reports `energy_now` in whole percent (about 496 mWh), so idle
watts are now the integral of `power_now`; the older numbers below were taken with the
earlier, finer-stepped gauge.

### Idle

About **2.9 W** at 30% brightness with the browser closed, on battery, measured over
20 minutes with the battery gauge. An earlier bug in the measuring tool overstated
the savings; these are the corrected numbers.

### Awake, against Windows 11 (preliminary)

Same-spec Surface Laptop 7 13.8" (X1P-64-100) pair, on battery, 50% brightness locked,
30 minute idle desktop, average discharge power. **Preliminary: to be re-run and updated
after the 2026-10-07 run.**

| Bench | Windows 11 | Linux (7.2.8-15) |
|---|---|---|
| v1 (first scripts; Linux gauge in whole percent steps) | 3.19 W | 3.27 W |
| v2 (fixed scripts, `power_now` integrated on Linux) | 3.08 W | **2.95 W** (about 4% lower) |

The Linux v2 run predates the DPU per-mixer clock fix (7.2.8-16) and the Wi-Fi power-save
fix (`omarchy-surface-sl7` 32), so a re-run with both is pending. Windows had its background
services (search indexer and similar) active. One run per cell, so treat differences of a
few percent as indicative only.

### Suspend

Deep suspend, 8 to 10 minute traces with `sl7-sleepstats --trace`:

| Metric (8-10 min deep suspend) | 7.2.8-7/-9 (before) | 7.2.8-11 (after) |
|---|---|---|
| **DDR self-refresh** (qcom_stats `ddr`, `lpm-0xd4`) | 0% of suspend, 0 entries | **~95% of suspend** (419 of 442 s; 584 of 615 s) |
| DDR bandwidth votes in the RPMh sleep set | MC0/SH0/SH1 held | all released |
| PCIe links (NVMe, Wi-Fi) | kept up through suspend | powered off, relinked on resume (Gen4 x4, Gen3 x2) |
| ADSP wakeups | ~104/s | ~11.5/s |
| XO (crystal) | held | still held (one prepare) |
| CX power collapse (`cxsd`) | no | not yet |
| Suspend power (overnight) | 0.8-0.9 W (8 h 25 min, 16% of 48.6 Wh, 7.2.8-4) | **0.31 W** (9 h 20 min, 2948 mWh, 7.2.8-13) |
| Battery life asleep, full charge | about 2.4 days | **about 6.5 days** |

To our knowledge, this is the first published DDR self-refresh in suspend on a
shipping Snapdragon X (X1E/X1P) laptop under Linux, with all DSPs running. The only
earlier CX/DDR collapse we found was on Qualcomm's reference CRD with an experimental
branch that disables the ADSP. Reports from the Dell Inspiron 7441, Latitude 7455,
Yoga Slim 7x and IdeaPad Slim 5x show `ddr` at 0.

Overnight on 7.2.8-13 (`sl7-sleepstats --suspend-test`, charger unplugged): 2948 mWh
over 9 h 20 min, **0.31 W**, about 63% less than before the power work. DDR was in
self-refresh for 94% of the time asleep and the ADSP woke about 10 times a second.
The night included one spurious wake (02:04, re-suspended by logind after 26 s), so
the pure suspend figure is at most this. CX power collapse is not reached yet
because one XO prepare still holds.

### What made the difference

From the `linux-sl7` README (Power sections):

- The 7.3 PDC pass-through and `domain_ss3` deepest-idle backport.
- The 7.4 pmdomain and cpuidle-psci backport (cores that never come online no longer
  pin their cluster).
- qcom-geni serial force suspend, so the Surface Aggregator UART stops holding clocks.
- The ps883x retimer releasing its XO clock while in reset.
- PCIe root ports reaching D3hot (`d4c79b63d82d`), so the NVMe and Wi-Fi links power
  off.
- The Qualcomm Crypto Engine driver disabled (it held a permanent DDR vote).
- `schedutil` with the SCMI sustained-frequency fix for cpufreq.

### Known

- VRR: no chip-rail power change measured; battery-gauge power is not measurable yet.
- PSR blanks the panel, so it stays off.

## Roadmap

- **IR emitter:** staged and safety-gated. Stage A (nothing fires) is in; the channel
  test stays disabled until reviewed.
- **Runtime power tuning** with a per-rail power meter.
- **Rebase on Linux 7.3** when it is released, dropping the patches that land in it.
- **USB4** once a host-router driver is posted upstream.

## Repository

Packages are published as assets of the rolling GitHub Release `repo-aarch64`:

```
[omarchy-sl7]
SigLevel = Required DatabaseOptional
Server = https://github.com/qBitnaut/omarchy-dragon-sl7/releases/download/repo-aarch64
```

- `.github/workflows/publish-repo.yml` runs after linux-sl7, iptsd-sl7, omarchy-surface-sl7,
  omarchy-sl7-keyring, howdy-next, sl7-ir-bridge and omarchy-sl7-faceunlock succeed on main (and on manual dispatch). It takes their latest artifacts
  plus the packages already on the release, refuses firmware files, signs every package
  (`gpg --detach-sign`), runs `repo-add --sign`, keeps the current and previous version of each
  package, and replaces the assets. Concurrent runs queue.
- Releases cannot hold symlinks, so `omarchy-sl7.db` and `omarchy-sl7.files` are real copies of
  the `.tar.gz` files, each with a `.sig`. `omarchy-sl7.pub.asc` is the public key.
- pacman follows GitHub's redirect from `github.com/.../releases/download/...` to its object
  storage (libcurl follows redirects; the same scheme serves other Arch repositories).
- Signing uses the repository secrets `REPO_SIGNING_KEY` (ASCII-armored private key, no
  passphrase) and `REPO_SIGNING_KEY_ID`. Without them the workflow still runs and warns that
  the repository is unsigned. The key must match `pkgs/omarchy-sl7-keyring`; rotate with
  `tools/repo/make-keyring-files.sh`.
- Immutable releases must stay disabled for this repository.

## Firmware and licensing

Microsoft and Qualcomm firmware is never committed to or distributed from this
repository. It is fetched on the target machine from Microsoft's public
Surface Laptop 7 driver MSI. The .gitignore blocks firmware and captures.

## License

- Scripts and packaging are MIT licensed (see LICENSE).
- Kernel patches under pkgs/linux-sl7/patches are GPL-2.0, like the Linux kernel they modify.
- iptsd-sl7 (the iptsd fork) is GPL-2.0-or-later; howdy-next is GPL-3.0-or-later.
- Microsoft/Qualcomm firmware is never included and remains under its own license.
- The Omarchy logo is Omarchy's, under the MIT license.

## Credits

Built on the work of the community:

- **Omarchy** (omacom/omarchy, omarchy-iso, omarchy-pkgs) and its dragon branches.
- **Surface Laptop 7 ports:** denislopt/omarchy-surface-laptop7, bryce-hoehn/linux-surface-laptop-7
  (touchpad calibration by Oliver White), ProgrammerIn-wonderland/ELLX-Kernel,
  ItsLucas/surface-laptop-7-ubuntu-kernel, dwhinham/linux-sp11, and linux-surface.
- **alex-lentz/iptsd:** the iptsd fork with Surface Laptop 7 touchpad support.
- **valeronm/sl7-mac:** factory Wi-Fi and Bluetooth addresses.
- **nathawat/howdy-next:** face authentication; the AUR package it builds on.
- **nate8199/omarchy-plugin-howdy-face:** the lock screen overlay we patch.
- **v4l2loopback:** the virtual camera device behind `sl7-ir-bridge`.
- **petm5/vd55g** (and ST's GPL firmware arrays): the VD55G0 IR sensor driver.
- **scuggo** (and Nikkuss): the msm variable refresh patch and QSPI work.
- **Kernel patch authors** credited in each patch: Maulik Shah, Ulf Hansson, Abel Vesa,
  Manivannan Sadhasivam, Bryan O'Donoghue, Jens Glathe, Liviu Nicoara, Jiajie Chen
  and rafaelguariento, among others.
