# iptsd-sl7

iptsd (userspace touch daemon) with Surface Laptop 7 13.8" touchpad support, for
Arch Linux ARM (aarch64).

## Why

The SL7 touchpad (HID-over-SPI `045E:0C77`, ACPI `MSHW0238`, Sensel-based) sends
raw heatmaps, not finished HID touchpad reports. iptsd turns them into a uinput
touchpad. Upstream `linux-surface/iptsd` v3.1.0 (2025-12-29) lacks the SL7 fixes
(physical click on the Sensel haptic pad, button debounce, palm-suppression click
leak, recovery after sleep when hidraw persists), which live in the
`alex-lentz/iptsd` fork. Arch/ALARM ship upstream `iptsd` only, so this package
provides and conflicts with `iptsd`.

## Fork pin

| | |
|---|---|
| Repo | https://github.com/alex-lentz/iptsd |
| Commit | `3663e96e758145801c3cb1ce7c72f362d0d4a5f5` |
| Commit date | 2026-07-17 00:26 UTC (2026-07-16 20:26 -0400), "Merge pull request #2 ..." |
| Tarball sha256 | `ce9935fb7c38365f4fa65070e819bf901e10082c5fb2ea67e49b3a60b225ed92` |

To bump: change `_commit`, `pkgver` (`3.1.0.rYYYYMMDD`), the sha256, run
`makepkg --printsrcinfo > .SRCINFO`.

## Build flags

`build()` appends `-mbranch-protection=standard` to `CFLAGS`, `CXXFLAGS` and
`LDFLAGS` if absent. A mix (some objects with BTI/PAC landing pads, others without,
or an LTO link step that drops the flag) produces a binary that dies with SIGILL,
even on `--help` (linux-surface/iptsd#1590). The fork builds with LTO, where code
generation happens at link time, so `LDFLAGS` must carry the flag as well.
Dependencies are the system libraries only (`--wrap-mode=nofallback`), so no
vendored copy is built with different flags. `check()` reports each binary's
AArch64 BTI/PAC property (`readelf -n`) plus the crt/object files lacking the note.
The linker keeps the note only if every input has it, so a consistently absent
note is accepted (no BTI enforcement, no SIGILL); `check()` fails only if the
binaries are mixed (some marked, some not).

Debug tools built: `iptsd-calibrate`, `iptsd-dump` (no SDL2/cairomm needed).

## Dependencies (all in ALARM)

Runtime: `fmt`, `libinih`, `spdlog`, `systemd-libs`.
Build: `meson`, `ninja`, `cmake` (meson finds Microsoft.GSL via CMake), `cli11`,
`eigen`, `microsoft-gsl`, `systemd`. Check: `binutils`. hidrd is not used by this
iptsd version.

## Installed files

- `/usr/bin/iptsd`, `iptsd-check-device`, `iptsd-calibrate`, `iptsd-dump`
- `/usr/bin/iptsd-systemd`, `iptsd-find-service`, `iptsd-find-hidraw`, `iptsd-foreach`
- `/usr/lib/systemd/system/iptsd@.service`, `/usr/lib/systemd/system-sleep/iptsd`
- `/usr/lib/udev/rules.d/50-iptsd.rules` (upstream: starts `iptsd@<hidraw>` for
  matching hidraw devices)
- `/usr/lib/udev/rules.d/61-iptsd-sl7-hide-raw-touchpad.rules` (ours): sets
  `LIBINPUT_IGNORE_DEVICE=1` on `ID_PATH=platform-88c000.spi-cs-0` and
  `ID_INPUT_TOUCHPAD=1` only. The button node ("spi 045E:0C77 Mouse") stays
  visible. Bound by path because hidraw numbers change between boots.
- `/etc/iptsd.conf`, `/usr/share/iptsd/*.conf` presets
- `/etc/iptsd.d/91-calibration-045E-0C77.conf` (backup file; fetched at build time, see licensing)

## Tap-to-click

Not an iptsd option (`[Touchpad]` has only `Disable`, `DisableOnPalm`, `Overshoot`,
`ButtonDebounceMs`, plus the patched-in keys below). It is a libinput setting; disable it in the compositor, for
Hyprland `input { touchpad { tap-to-click = false } }`. Not done by this package.

## Licensing

- iptsd and this packaging: GPL-2.0-or-later (upstream `LICENSE` installed to
  `/usr/share/licenses/iptsd-sl7/`).
- `91-calibration-045E-0C77.conf`: by Oliver White (bryce-hoehn/linux-surface-laptop-7,
  `config/touchpad/`, pinned to commit e60938dcf707d37d24e782e0029b9c9a567d67b8,
  2026-06-03). Upstream has no license; fetched, not redistributed in this repo.
  It is the output of `iptsd-calibrate` (measured numbers). Replace it by running
  `iptsd-calibrate /dev/hidrawN` on your own unit (find N with
  `iptsd-foreach -t touchpad -- echo {}`).

## Patches and tuning

- `0001-daemon-require-button-hold-time.patch` (applied in `prepare()`):
  adds `[Touchpad] ButtonHoldMs` (default 70). The firmware's click bit must be
  held that long, with at least one contact on the pad, before `BTN_LEFT` is
  emitted; release is immediate. 0 disables it. Two-finger (clickfinger) clicks
  are unaffected. A spike longer than the value still passes (a 160 ms one needs
  more than 160, at that much latency).
- `0002-daemon-button-motion-gating.patch` (applied in `prepare()`, after 0001):
  adds `[Touchpad] ButtonMaxMoveMm` (default 1.5; 0 disables). When the click
  bit rises, the positions of the valid contacts are snapshotted (normalized
  0..1 positions times `Width`/`Height` in cm times 10 = mm). The press is
  confirmed only if, for the whole `ButtonHoldMs`, no contact moves that far
  from its snapshot; a contact appearing or disappearing counts as motion. A
  rejected press stays ignored until the bit clears and rises again. After a
  confirmed press, 2 or more contacts moving that far (scrolling) release the
  button and suppress it until the bit clears; one moving contact keeps it held
  (click and drag), and a change in the contact set re-measures from there.
  Fixes repeated right clicks while two-finger scrolling with clickfinger.
- `0003-daemon-lift-grace.patch` (applied in `prepare()`, after 0002):
  adds `[Touchpad] LiftGraceMs` (default 30; 0 disables). A valid contact that
  vanishes for less than that and reappears within 5 mm of its last position
  (as any new tracker index) keeps its old index: no lift, no touch down, and
  the button gating sees an unchanged contact set. While gone it is held at its
  last position; a real lift is therefore delayed by up to `LiftGraceMs`. Held
  contacts are released by time: while one is held the daemon polls the hidraw fd with a timeout and releases it when `LiftGraceMs` is up, even if the sensor sends no more frames. The idea is credited to the
  `LiftGraceMs` comment in ProgrammerIn-wonderland's ELLX iptsd build (that
  code is unpublished; this is an independent implementation). 30 ms is a few
  sensor frames, well under a deliberate tap-lift-tap; ELLX's own comment
  suggests 70 ms was too long.
- Peak suppression (`Neutral`, `NeutralValue`, `PeakSuppressionRadius`,
  `PeakSuppressionFactor`) is already in the pinned fork (upstream iptsd PR #205,
  v3.1.0); the 92 file only enables it, with the Surface Laptop Studio 2 preset
  values. Contact limits (`SizeMin` 0.7, `SizeMax` 3.3, `AspectMin` 1.0,
  `AspectMax` 3.7) and `ButtonDebounceMs` 30 follow ELLX's calibration.
- `/etc/iptsd.d/92-iptsd-sl7-tuning.conf` overrides the 91 calibration;
  `/etc/iptsd.d/93-local-calibration.conf` (from `iptsd-sl7-calibrate`) overrides
  both. `iptsd-sl7-calibrate --revert` removes it.
- `iptsd-sl7-calibrate` is optional and not recommended on the SL7 currently:
  the defaults (91 + 92) are the supported configuration. It prints a notice and
  asks to continue. It may only lower `SizeMin`/`AspectMin` (never above the
  run's measured minimum or the current 91/92 value) and caps `SizeMax`/
  `AspectMax` at the 92 values (3.3 / 3.7). A run whose maxima exceed 2.5x the mean is
  polluted (two close fingers can read as one large blob) and cannot be
  installed; re-run or quit.
