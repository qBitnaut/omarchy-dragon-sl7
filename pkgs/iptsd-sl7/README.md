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
`ButtonDebounceMs`, plus the patched-in keys below). It is a libinput setting that the
compositor owns. Hyprland's default tapping gave false left clicks and repeated right
clicks (a two-finger tap) during two-finger scrolls on the SL7, so `omarchy-surface-sl7`
turns it off once per user (`tap_to_click = false` appended to `~/.config/hypr/input.lua`,
see its README, "Touchpad defaults"). Set it to `true` there to get tapping back.

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
- `0004-runner-reenable-multitouch-on-legacy-reports.patch` (applied in `prepare()`, after
  0003): mode watchdog, touchpads only. spi-hid can reset the pad without any uevent (a
  refresh whose report-descriptor CRC is unchanged creates no new hid device, so udev and the
  `iptsd-sl7-restart` helper never hear of it). The pad then falls back to mouse mode and a
  running iptsd keeps waiting for touch data; two-finger scroll is gone until the unit is
  restarted, sometimes twice. The runner now counts legacy reports: input reports whose ID is
  neither touch data nor the button report, plus, if the button report is a full mouse report
  (its descriptor has X/Y), button reports with non-zero motion bytes. Those only exist outside
  multitouch mode. Three of them with no touch data in the last 300 ms switch the device to
  singletouch and back to multitouch (what a restart does), at most once per 500 ms, doubled
  per failed attempt. Touch data at all proves multitouch works: it resets the counters, and
  legacy-looking reports interleaved with touch data never trigger anything, so a false
  positive is harmless. After 3 failed recoveries the loop ends and iptsd exits; systemd
  restarts the unit with a fresh mode switch. The journal shows
  `Device sent legacy reports without touch data, re-enabling multitouch` (`sl7-doctor`
  reports a count). Not active for the touchscreen (its pen reports have their own IDs).
  `IPTSD_MODE_WATCHDOG=0` in the unit environment disables it. The signal is unverified on
  hardware for the exact legacy report IDs: if the pad's mouse mode reuses the button report
  without X/Y fields, the daemon cannot see it and the old restart paths still apply.
- `0005-daemon-drag-latch.patch` (applied in `prepare()`, after 0004): drag latch, adds
  `[Touchpad] DragStartMm` (default 1.5; 0 disables) and `DragReleaseStillMs` (default 300;
  0 = release only on lift). The firmware click bit is a pressure threshold: it drops out while
  a finger slides during a click and drag, and is not set again, so the drag broke partway.
  After a confirmed press, once exactly one contact moves `DragStartMm` from its press
  position, releases of the bit are ignored (BTN_LEFT stays down, and the singletouch lift no
  longer clears it). The latch ends when the dragging contact lifts or all contacts are gone
  (`LiftGraceMs` still applies, the held contacts count as present), or when the bit is
  released and no contact moves 0.5 mm for `DragReleaseStillMs`. A re-press during the latch
  just continues the drag. Palm block or disabling the device also ends it. A click that never
  moves `DragStartMm` releases immediately as before. Two moving contacts never latch, and
  0002's scroll cancel still ends a latched drag. 0002's cancel now counts the contacts that
  moved (2 or more) instead of using the farthest one, so a drag with a second resting contact
  (thumb) is not cancelled. The stillness release uses the same runner timeout as `LiftGraceMs`,
  so it fires even if the sensor sends no frames. Pausing mid-drag with a light touch (bit
  released, finger still) releases after `DragReleaseStillMs`: raise it, or set it to 0, if that
  bites.
- `0006-daemon-drag-fast-motion-relatch.patch` (applied in `prepare()`, after 0005): fixes
  the latch breaking when dragging fast, and adds `[Touchpad] DragRelatchMs` (default 400;
  0 = off). Causes at speed: the tracker re-indexes a contact that moves more than 0.15
  (normalized) per frame, which `LiftGraceMs` (5 mm) cannot bridge, so the drag contact
  vanished and ended the latch; a smeared fast blob failing the size / aspect check
  (`DisableOnPalm`) ended it too; an unstable frame (`PositionThresholdMax`) skipped the
  singletouch contact, which read as a lift (BTN_TOUCH and tool off, BTN_LEFT too before the
  latch engaged); a transient split contact next to the finger counted as a second mover and
  fired the scroll cancel; the bit could drop before `DragStartMm` was reached. Now the latch
  follows the drag by the real contact nearest its last position (25 mm plus 3 times its last
  step, max 60 mm), rides out 100 ms of invalid frames, keeps the singletouch contact down over
  unstable frames, counts only contacts present for 60 ms as movers, and latches on a bit drop
  while the only contact moved 1 mm in the last frame. An unstable frame restarts the stillness
  timer (never counts as still). `DragRelatchMs`: when the drag finger lifts and no other
  contact is left (a selection reaching the pad edge), BTN_LEFT stays held that long; one new
  contact landing in the window continues the same drag (no release or press) under the same
  stillness rule, two contacts landing end it, and so does the timeout (it also fires without
  frames). Trade-off: after a real drag ends by lifting, the drop is delayed by `DragRelatchMs`
  (plus up to `LiftGraceMs`); a plain click is not delayed. If the delay bothers you, lower it
  or set 0.
- `0007-daemon-drag-park-and-debug-log.patch` (applied in `prepare()`, after 0006): lifting
  the finger to continue a drag (past the pad edge) still ended it. The stillness rule
  (bit released, contacts still `DragReleaseStillMs`) released the button, and pausing at
  the edge before lifting is exactly that state, so the drag was over before the relatch
  window could start. Now a drag whose stillness rule fires is parked: BTN_LEFT stays held,
  and it ends only after a further `DragRelatchMs` parked and still, or when the finger
  lifts and no contact lands within `DragRelatchMs`. Moving again or a firmware press
  un-parks it. `DragRelatchMs = 0` keeps the old release. `DragReleaseStillMs = 0` never
  releases because of stillness (it never meant "release at once"). Invalid-contact frames
  (a landing finger at the pad edge failing the size / aspect check) no longer end the drag
  while it waits for the finger; the wait window decides. A firmware press during the wait
  is absorbed, never handled as a new press. Adds `[Touchpad] DragDebug` (default false;
  or env `IPTSD_SL7_DRAG_DEBUG=1`): logs each latch transition with timestamp, reason and
  state to the journal. To capture: set `DragDebug = true` in
  `/etc/iptsd.d/94-local.conf`, `sudo systemctl restart 'iptsd@*.service'`, then
  run `journalctl -f -o short-precise -u 'iptsd@*' | grep drag` next to `sudo libinput debug-events` and compare the clock times.
- `0008-daemon-drag-keep-while-button-held.patch` (applied in `prepare()`, after 0007): holding
  the physical click with one finger and dragging with another, lifting the moving finger to
  reposition (selection at the screen edge) ended the selection: the "drag contact lifted
  while other contacts remain" rule released BTN_LEFT although the firmware button bit was
  still held. While the bit is held, a lifted drag contact now never ends the drag or
  releases BTN_LEFT. The drag stays latched and tracking moves to the newest contact (a newly
  placed finger, else the remaining one; none left: it waits for one), so the pointer
  continues from the new finger without a jump. A drag waiting for the finger
  (`DragRelatchMs`) that sees the bit pressed again keeps going too. When the bit is released
  the usual rules apply again (lift: wait `DragRelatchMs`, still: park, then release). With
  the bit low (tap and drag, parked drag) nothing changes. `DragDebug` logs `drag-keep`
  (contact lifted but firmware button still held) and `drag-keep-handoff`.
- `0009-touchpad-haptic-intensity-and-click-force.patch` (applied in `prepare()`, after 0008):
  adds `[Touchpad] HapticIntensity` (0 to 100, Windows `FeedbackIntensity`, Windows default
  50) and `[Touchpad] ClickForce` (`low`, `medium` or `high`, Windows `ClickForceSensitivity`
  0 / 50 / 100, Windows default medium). Both are unset by default and an unset key sends
  nothing, so the firmware setting stays (`92-iptsd-sl7-tuning.conf` ships them commented
  out with the Windows defaults). The reports are found in the HID descriptor by usage, not
  by ID: click force is the Digitizer page Button Press Threshold (`0x0D` / `0xB0`) feature
  report (SL7: ID `0x88`, 2 bits, logical 1..3 = low / medium / high), intensity the Haptics
  page Intensity (`0x0E` / `0x23`) feature report (SL7: ID `0x87`, 8 bits, logical 0..100).
  The field's bit position comes from the descriptor and the value is scaled onto its
  logical range. They are sent, like Windows does, after iptsd enables multitouch at startup
  and after every mode watchdog recovery (0004); each apply is logged at info level
  (`Applied haptic intensity 50 (raw 50)`, `Applied click force medium (raw 2)`). A pad
  without the report logs a warning once. To set them, put this in
  `/etc/iptsd.d/94-local.conf` and run `sudo systemctl restart 'iptsd@*.service'`:

  ```ini
  [Device]
  Vendor = 0x045E
  Product = 0x0C77

  [Touchpad]
  HapticIntensity = 70
  ClickForce = low
  ```

  Whether the firmware keeps the values across its own resets that iptsd cannot see is
  untested; if the feel reverts, restart the unit.
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
