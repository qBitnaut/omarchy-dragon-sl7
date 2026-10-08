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
| Touchpad | Works | `iptsd-sl7` (a fork with Surface Laptop 7 fixes). Tap-to-click is off by default (it caused false clicks while scrolling; set `tap_to_click = true` in `~/.config/hypr/input.lua` to bring it back). Drag latch keeps click-and-drag held, and lift-and-continue works: the drag stays while the physical click is held (iptsd-sl7 patch 0008, verified on the SL7). Disable-while-typing is active. A watchdog re-enables multitouch if the pad falls back to mouse mode. Haptic strength and click force follow Windows' settings (see [Touchpad settings](#touchpad-settings)). Gestures are your own Hyprland (Lua) config. |
| Touchscreen | Partial | SPI touch modules only (the 13.8" unit here). Units with the I2C module are not covered. Pen is untested. |
| Display | Works | Native 2304x1536 at 120 Hz. |
| Variable refresh (VRR) | Works | 24-120 Hz, on by default (`msm.vrr_enabled=1`; Hyprland `misc.vrr` set by the power mode service). Panel measured at 24 Hz idle, about 116 Hz under motion, no flicker. No chip-rail power change; battery power not measurable yet. Off: remove the `msm.vrr_enabled=1` line from `/etc/limine-entry-tool.d/omarchy-surface-sl7.conf`, `sudo limine-mkinitcpio`, reboot. |
| Panel self refresh (PSR) | Not yet | Known broken: the panel goes black when idle. Keep it off. |
| GPU acceleration | Works | Adreno via `msm`; the zap shader comes from the Microsoft MSI. |
| Hardware video (Iris) | Works | Enabled in the device tree with the Microsoft signed firmware from the MSI (`omarchy-surface-sl7-firmware`). Verified on the SL7: decode in mpv (`--hwdec=v4l2m2m-copy`), and H.264 encode with ffmpeg (`-pix_fmt nv12 -c:v h264_v4l2m2m`; 1080p30 at 19x real time). V4L2 decode (H.264, HEVC, VP9, AV1) and encode (H.264, HEVC) for mpv, ffmpeg and GStreamer; the encoder takes NV12 input only. Firefox-based browsers (Zen 157) try V4L2 decode and fall back to software. |
| Wi-Fi | Works | WCN7850 with a board-file fix and the factory MAC restored. |
| Bluetooth | Partial | Works with the factory address restored (it does not work at all without it); less tested than Wi-Fi. |
| Audio | Partial | Speakers and microphones work with the kernel volume caps. The Pro Audio profile is deliberately blocked to protect the speakers. Headphone jack quality is unverified. |
| Battery percentage and charging | Works | `qcom_battmgr` patch for capacity; Omarchy's battery scripts are patched to see the Qualcomm gauge. |
| USB-C charging and USB 3 | Works | Both ports charge and run USB 3 (10 Gb/s), in either plug orientation (SuperSpeed on the reversed orientation fixed by ps883x patch 0090, on by default since linux-sl7 7.2.8-18), with DisplayPort alt mode and docks. USB4 and Thunderbolt bandwidth is not available yet. |
| Suspend and resume | Works | Deep suspend (`deep`), touch restarted after resume, about 0.35 W overnight. See [power results](#power-and-performance-results-so-far) for the drain. |
| Front webcam | Works | OV02C10 through libcamera's GPU software ISP (Adreno, EGL); the hardware ISP is not used, because CAMSS delivers raw frames only. Our `libcamera-sl7` build (0.7.2-4.2) adds the sensor helper, a fast auto-exposure start, a fix for GPU-mode 720p metering and Adjust defaults read from the tuning file. Colour tuning is generated at install from your own Surface driver package and never redistributed; defaults chosen on the SL7: set 1, blend 0.6, contrast 1.2, saturation 1.05 (`sl7-camera-tuning` adjusts them, `sl7-camera-check` collects diagnostics). Verified on the SL7: much better colour, no grey start. The sensor runs from a 12 MHz clock; `linux-sl7` 7.2.8-23 (patches 0099/0100) fixes the frame rate from 18.8 to 30 fps and the exposure timing (published, the on-device 30 fps check is pending). See the [webcam section](pkgs/omarchy-surface-sl7/README.md#8k-front-webcam-sl7-camera-tuning-sl7-camera-check) for browser setup. |
| IR camera | Works | ST VD55G0, 644x604 greyscale, through `sl7-ir-bridge`, lit by the built-in IR emitter (verified 2026-10-07: self-test frames brighter than unlit, no black frames). Known issue: libcamera/PipeWire can grab the IR camera and block face unlock; workaround `systemctl --user restart pipewire wireplumber && sudo systemctl restart sl7-ir-bridge`. A package update that hides the IR camera from libcamera and PipeWire is in progress (not yet published). |
| Face unlock | Works | Verified on the SL7 (2026-10-07), on the normal boot (there is no IR test boot entry): face registered in the setup app, lock screen and `sudo` unlocked by face, no external IR source needed. howdy-next plus a setup app (Omarchy menu: Setup > Security > Face Unlock). The built-in IR emitter is driven by the sensor's own strobe (stage C found that GPIO 1 lights it), held by the kernel (linux-sl7 7.2.8-22) to Windows Hello's 100-line exposure and frame time, whatever user space asks: on the SL7 sensor clock that is 0.8 ms of light per 27.8 ms frame (2.9 % duty, Windows 5.7 %). `sl7-ir-bridge` lights it only while a scan streams, 10 s at most per session, with analog gain 24 as the default; `howdy-next` 2 silences a harmless OpenCV warning; `IR_EMITTER=off` in `/etc/sl7-ir-bridge.conf` keeps it dark. |
| CPU frequency scaling | Works | All three clusters, `schedutil`, with the SCMI sustained-frequency fix. |
| Power mode on AC/battery | Works | Caps CPU and GPU frequency and enables Wi-Fi power save on battery; restores everything on AC. 60 Hz switching on battery is opt-in. |
| Firmware | Works | Fetched from Microsoft's Surface Laptop 7 driver MSI, never shipped here. |
| Hibernation | Not yet | The image write hangs, and the RTC alarm is owned by the ADSP. |

### Touchpad settings

Set in `/etc/iptsd.d/94-local.conf` (restart `iptsd` after editing). Full list in the
[iptsd-sl7 README](pkgs/iptsd-sl7/README.md).

| Setting | Values | Status |
|---|---|---|
| `[Touchpad] HapticIntensity` | 0 to 100 (Windows semantics) | Applied on the SL7 (patch 0009, iptsd-sl7 16) |
| `[Touchpad] ClickForce` | `low`, `medium`, `high` (Windows semantics) | Applied on the SL7 (patch 0009, iptsd-sl7 16) |
| `[Touchpad] PalmMode` | `windows` (default), `freeze` | Published, not yet verified (patch 0010, iptsd-sl7 17) |

`PalmMode = windows` ignores a resting palm while the other fingers and the click keep
working; `freeze` is the older behaviour. It is published, and the feel test on the SL7 is
pending.

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
| `sl7-camera-tuning` | Builds the front webcam's libcamera tuning file from Microsoft's driver package, on your machine (`--blend`, `--dry-run`, `--status`, `--remove`). |
| `sl7-camera-check` | Captures GPU and CPU frames at 1080p and 720p, raw and dark frames, logs and a CPU/power sample into `~/sl7-camera-<time>/` and tars it. |
| `omarchy-sl7-powermode` | Applies or shows the AC or battery power mode (frequency caps, Wi-Fi power save). |
| `omarchy-sl7-bag-guard` | Service (on by default): suspends, then powers off, a laptop left awake with the lid closed on battery and no external display, or too hot; `--check` shows the decision without acting. |
| `omarchy-sl7-test-entry` | Adds optional boot entries for experiments (`psr`, `clk-unused`); off by default. |
| `omarchy-sl7-faceunlock` | Face Unlock setup and face manager (Omarchy menu: Setup > Security > Face Unlock). Package `omarchy-sl7-faceunlock`. |
| `sl7-ir-bridge` | On-demand bridge from the IR camera to a stable V4L2 device, `/dev/v4l/by-id/sl7-ir-camera`. Package `sl7-ir-bridge`. |

## Power and performance results so far

Measured on the 13.8" X1P-64-100 (16 GB). Numbers are from `sl7-powertest` and the
battery gauge. For a while the gauge reported `energy_now` in whole percent (about 496 mWh),
so idle watts were taken as the integral of `power_now`. It now reports fine-grained energy
again; each figure below says which method it used.

### Idle

About **2.9 W** at 30% brightness with the browser closed, on battery, measured over
20 minutes with the battery gauge. An earlier bug in the measuring tool overstated
the savings; these are the corrected numbers.

### Awake, against Windows 11 (preliminary)

Same-spec Surface Laptop 7 13.8" (X1P-64-100) pair, on battery, 50% brightness locked,
30 minute idle desktop, average discharge power. **Preliminary: a re-run with the latest
fixes (kernel and packages) is pending.**

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
| Suspend power (overnight) | 0.8-0.9 W (8 h 25 min, 16% of 48.6 Wh, 7.2.8-4) | **about 0.35 W average** (0.31-0.42 W range; 7.2.8-13 and -22) |
| Battery life asleep, full charge | about 2.4 days | **about 6 days** |

To our knowledge, this is the first published DDR self-refresh in suspend on a
shipping Snapdragon X (X1E/X1P) laptop under Linux, with all DSPs running. The only
earlier CX/DDR collapse we found was on Qualcomm's reference CRD with an experimental
branch that disables the ADSP. Reports from the Dell Inspiron 7441, Latitude 7455,
Yoga Slim 7x and IdeaPad Slim 5x show `ddr` at 0.

Latest overnight, 7.2.8-22, 7-8 October (charger unplugged): the whole night, 20:24 to
07:37 (11.2 h), took the battery from 75% to 67%, about **0.35 W** on average, roughly 6
days of standby on a full charge. A 5.1 h stretch of it was measured precisely at **0.42
W**, because the gauge now reports fine-grained energy; the whole-night figure comes from
whole-percent readings. DDR was in self-refresh for about 94% of the time asleep.

The earlier night on 7.2.8-13 (`sl7-sleepstats --suspend-test`) gave 2948 mWh over 9 h 20
min, **0.31 W**, but was measured with whole-percent quantisation (about 0.05 W of
uncertainty), so read the range as 0.31 to 0.42 W rather than a single figure. Both are about half or less of
the Windows figure of 0.8 to 0.9 W. CX power collapse is not reached yet
because one XO prepare still holds.

One harmless stray wake happened about 5 h into the suspend (about 26 s awake, then it
suspended again). Wake-source logging is now on: `journalctl -t omarchy-surface-sl7 | grep wake`.

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

### Bag guard and USB power

- **Bag guard** (`omarchy-sl7-bag-guard`, on by default): lid closed, on battery and no
  external display, and still awake after 120 s, so it suspends again. After 3 failed
  suspends, or more than 60 degC for 60 s, it powers off. `omarchy-sl7-bag-guard --check`
  shows the decision without acting.
- **USB-A** runtime power management is on by default. **USB-C** stays always on, because
  of a wake-on-plug issue (future research).
- **USB-C reverse orientation** now runs at SuperSpeed (ps883x patch 0090, on by default).

### Known

- VRR: no chip-rail power change measured; battery-gauge power is not measurable yet.
- PSR blanks the panel, so it stays off.

## Roadmap

- **IR camera and face unlock:** working (lock screen and `sudo` verified). Still to do: stop
  libcamera/PipeWire from grabbing the IR camera (package update in progress), check
  recognition in daylight and darkness, the bridge delivering 18 of the sensor's 36 fps, and
  Windows' runtime gain (not decoded).
- **Front webcam:** confirm 30 fps on the device after `linux-sl7` 7.2.8-23.
- **Touchpad:** feel test of `PalmMode = windows`.
- **Awake power:** re-run the Windows comparison with the latest fixes.
- **USB-C runtime power management** (wake-on-plug issue) and **hibernation**.
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
