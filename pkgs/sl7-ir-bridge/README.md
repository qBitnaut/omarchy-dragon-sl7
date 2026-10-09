# sl7-ir-bridge

On-demand bridge from the Surface Laptop 7 IR camera (ST VD55G0 on the Qualcomm
CAMSS raw node) to a v4l2loopback device, so that howdy-next, `howdy add`, a
preview and anything else that speaks V4L2/OpenCV see one stable, correct GREY
camera. It is a small C program with direct V4L2 and media-controller ioctls
(no OpenCV, no libcamera, no v4l-utils at run time).

Why a bridge: the CAMSS node is multi-planar, its rows are 656 bytes apart for a
644 pixel wide frame (OpenCV's GREY path ignores the stride and shears the
picture), and it needs media links and pad formats set first.

## Pieces

| File | Purpose |
|---|---|
| `/usr/bin/sl7-ir-bridge` | the daemon and `--selftest` |
| `/usr/lib/systemd/system/sl7-ir-bridge.service` | started at boot, idle, sandboxed |
| `/usr/lib/modules-load.d/sl7-ir-bridge.conf` | loads `v4l2loopback` at boot |
| `/usr/lib/modprobe.d/sl7-ir-bridge.conf` | `devices=1 video_nr=42 card_label="SL7 IR Camera" exclusive_caps=1 max_buffers=4` (override in `/etc/modprobe.d/`) |
| `/usr/lib/udev/rules.d/71-sl7-ir-bridge.rules` | `/dev/v4l/by-id/sl7-ir-camera`, group `video`, mode 0660, `uaccess` |
| `/etc/sl7-ir-bridge.conf` | `IR_EMITTER=on` (default; `off` keeps the emitter dark), optional gains and timing settings |

The `v4l2loopback` module (0.15.4, GPL-2.0-or-later) comes from `linux-sl7`
7.2.8-10 or later, which builds it out of tree against its own tree and installs
it as `extra/v4l2loopback.ko`. It is not in mainline. Do not install ALARM's
`v4l2loopback-dkms` next to it.

Point howdy-next at `/dev/v4l/by-id/sl7-ir-camera` (it accepts `/dev/video*`,
`/dev/v4l/by-id/*` and `/dev/v4l/by-path/*`).

## How it works

1. At start the daemon finds the loopback by its card name (`SL7 IR Camera`,
   never by number), sets GREY 644x604 (tight, stride 644, 35 fps) on its output
   side, subscribes to v4l2loopback's `V4L2_EVENT_PRI_CLIENT_USAGE` event (type
   0x10E00001, `count` in the payload) and writes one black frame. That first
   write makes it the single long-lived writer: the format lives as long as the
   daemon, and the node announces itself as a capture device. Nothing touches
   the camera yet; the sensor is off.
2. v4l2loopback queues that event when a consumer starts or stops streaming
   (capture STREAMON, STREAMOFF, close), not on plain open, so device
   enumeration by PipeWire or a browser does not wake the sensor. In 0.15.4 only
   one capture client can stream at a time (a second one gets `EBUSY`), so the
   count is effectively 0 or 1.
3. Count 1: the daemon opens the CAMSS media device (the one whose driver is
   `qcom-camss`), reads the topology, finds the path `vd55g* -> msm_csiphy ->
   msm_csid1 -> msm_vfe1_rdi0 -> video node` by entity name (the CSID and VFE are
   `IR_CSID` / `IR_VFE_RDI`, see below), enables the links on
   that path (only those not already enabled), sets `Y8_1X8` 644x604 on every pad
   of the path, sets GREY 644x604 on the video node (reading back the stride, 656
   today), maps 4 buffers and starts streaming. It never resets the media graph
   (`media-ctl -r`), so an RGB call on the same media device is unaffected, and
   the video node number is found by entity name every time.
4. Each frame is repacked to a tight 644x604 and written to the loopback with a
   single `write()`. Incomplete or error-flagged frames are dropped and counted.
5. Count 0: after a grace period (500 ms, `IR_STOP_GRACE_MS`) the daemon stops
   the CAMSS stream, closes the media and video nodes, disables the links it
   enabled, and writes a black frame. A new reader of a v4l2loopback device first
   gets the newest frame in the buffer, so the black frame stops a stale face
   from being replayed.
6. One log line per session start and end (journal: `journalctl -u
   sl7-ir-bridge`), for example `session end (consumer stopped): 312 frames in
   9.0 s (34.7 fps), 0 dropped`.

CAMSS route: libcamera's simple pipeline wires the RGB camera through the first
route it finds (`msm_csiphy4 -> msm_csid0 -> msm_vfe0_rdi0`, `/dev/video2`) and
keeps those links and nodes open while the desktop session runs. A CSID sink
accepts one enabled source link, so the IR camera cannot share `msm_csid0`:
enabling `msm_csiphy0 -> msm_csid0` fails with EBUSY and face unlock times out.
The bridge therefore defaults to `msm_csiphy0 -> msm_csid1 -> msm_vfe1_rdi0`
(`/dev/video6` on the SL7 today; always resolved by entity name, never by
number). csid0/vfe0 and csid1/vfe1 are the FULL CAMSS blocks; csid2 and up and
vfe2 and up are LITE blocks. Verified on the SL7 (0.1.0-5): the lite route
`msm_csid2 -> msm_vfe2_rdi0` sets up without error but delivers 0 frames, while
`msm_csid1 -> msm_vfe1_rdi0` streams at 18.6 fps with lit frames. Automatic
selection therefore tries csid1/vfe1 first, then the other full blocks
(csid0/vfe0) only if free, and the lite blocks last as a last resort.
`IR_CSID` and `IR_VFE_RDI` in `/etc/sl7-ir-bridge.conf` change the preferred
route. The bridge touches only links on its own path (sources `msm_csiphy0`,
its CSID and its RDI); it never changes anything involving `msm_csiphy4` or
another camera's CSID/VFE. If the configured CSID sink or RDI is already
enabled for another source (libcamera moved, or the setting was changed), it
picks the next free CSID/VFE combination in that order and logs `IR route: ...`.
No-frame fallback: if a route sets up but delivers no frame within 2 s (or the
session ends with 0 frames after 1.5 s or more), the bridge logs a WARN naming
the route, marks it bad until the daemon restarts, and the next session uses the
next candidate. If every candidate has been marked bad, the configured route is
used again. Sessions that deliver frames are not affected. The start up cleanup
of leftover links is limited to the same path. After an update and a reboot,
`media-ctl -p` shows the IR sensor on `msm_csid1` / `msm_vfe1_rdi0` and the RGB
camera on `msm_csid0` / `msm_vfe0_rdi0`; the journal has no EBUSY.

Session cap: one CAMSS streaming session lasts at most 10 s (`IR_SESSION_MAX_MS`,
clamped to 10000). After that the bridge stops the stream, logs it, and waits for
a fresh consumer start (the consumer closes the device and opens it again) before
streaming again. This is a safety budget for the emitter work and also bounds the
sensor's on time.

Failures: if the CAMSS setup or start fails the bridge tears down what it had set up
(links, buffers, `led_mode`), logs the reason once and retries after 5 s, then 10 s, then
every 20 s while a consumer is waiting (a fresh consumer start retries at once); no frames
arrive and the consumer times out (no fake frames are sent). Enabling a media link can fail
with `EBUSY` while a stream still runs through the IR path (a test tool, or a consumer that was
killed and whose pipeline the kernel is still stopping): the bridge waits up to 2 s for it,
then releases the links it enabled and retries later instead of looping. When the daemon
starts it releases IR path links that a killed predecessor left enabled (links in use stay). If no frame arrives for 2 s (first) or 1.5 s
(later) the session is stopped. If the loopback disappears the daemon exits and
systemd restarts it.

## Foreign writer on the loopback

If opening the loopback, or setting its GREY format, fails with `EBUSY`, another process holds
the node the bridge must write to and could be feeding the consumers (howdy, the lock screen)
frames of its own. The bridge logs `foreign writer on the IR camera`, one `loopback holder: pid
P (name) uid U holds /dev/videoN (read/write)` line per process that has the node open
(`/proc/<pid>/fd` scan; readers show up too, the access mode is the descriptor's), writes
`/run/sl7-ir-bridge/foreign-writer` in the same format as the `ebusy` file, and exits (systemd
restarts it; the unit keeps its runtime directory across restarts, so the flag stays while the
condition lasts). A successful start removes the file. `sl7-doctor` and `omarchy-sl7-faceunlock
status` show it in red as "foreign writer on the IR camera".

## Stuck in EBUSY

If session starts keep failing with `EBUSY` (the bridge cannot enable the IR path links
because another process holds the path), the bridge notes the first failure and, once the
failures span 30 s (`BUSY_REPORT_MS`), does three things, once per episode:

- logs `the IR path has been busy for N s` and one `busy holder: pid P (name) uid U holds
  /dev/videoN (IR video node)` line per process that has the IR video node, the IR sensor or
  CSID/VFE subdevs, or the CAMSS media device open (found by scanning `/proc/<pid>/fd`; the media
  device is shared with the RGB camera, so a camera application shows up there legitimately),
  or a note that no process holds it (a stream whose owner is gone) or that some processes could
  not be inspected;
- logs the fix: `systemctl --user restart pipewire wireplumber`, then `sudo systemctl restart
  sl7-ir-bridge`;
- writes `/run/sl7-ir-bridge/ebusy` (`since=<unix time>`, `holders=<n>`, then the holder lines)
  for `sl7-doctor` and `omarchy-sl7-faceunlock status`.

The file is removed at the next successful session, when a start fails for another reason, or
when the service stops (it lives in the unit's `RuntimeDirectory`). The retries only happen while
a consumer is waiting, so after the holder is gone the flag stays until the next face scan.

## Self test

```
sl7-ir-bridge --selftest [-n 30] [-d /dev/v4l/by-id/sl7-ir-camera]
```

Streams N frames from the loopback as a normal consumer (so it wakes the sensor
through the bridge) and prints the time to the first frame, fps and mean
brightness. No images are saved. The first frame it receives is the bridge's idle
black frame and is not counted. Exit status 0 pass, 1 failure, 3 frames received
but all black (a dark scene while the emitter is not working yet).

## IR emitter

The IR emitter is lit by the sensor's GPIO 1 strobe alone (emitter plan, stage C): it is high for
the whole exposure of every frame while the vd55g `led_mode` control is not off. The PMIC flash
is not in the path, so the only safety control is the strobe duration (the exposure) and how
often it repeats (the frame length). The kernel (`linux-sl7` 7.2.8-22, patch 0098) holds both to
what Windows Hello programs whenever `led_mode` is not off, whatever user space asks:

| | Windows | Source |
|---|---|---|
| exposure | 100 lines = 1.59 ms (manual exposure, `0x044c` = 2, `0x044e` = 100) | Windows sensor module file, regSetting 37 |
| frame length | 1750 lines = 27.8 ms = 36 fps (`0x0458/9`) | same |
| strobe duty | 5.7 % | derived |

With `IR_EMITTER=on` (the default in `/etc/sl7-ir-bridge.conf`) every session does, in
`ir_emitter.c`:

- before STREAMON (the strobe configuration latches when the stream starts): vblank = 1750 -
  604, auto exposure to manual, exposure 100, analogue gain 24 from the shipped config (driver
  default 19; Windows' init writes no gain register; 24 gave faster face matches on the SL7) and
  digital gain at the driver default (`IR_GAIN_ANALOG` and `IR_GAIN_DIGITAL` override), then
  `led_mode` = flash. The values are read back; if the sensor does not report exposure <= 100 and
  frame length >= 1750 with manual exposure, or `led_mode` does not read back flash, the session
  runs unlit. A kernel without the `led_mode` control (older than 7.2.8-22, or
  `vd55g.illuminator=0`) also runs unlit, with a warning.
- before STREAMOFF: `led_mode` = none, so the emitter goes dark before the stream and the sensor
  stop; also on every error path and at shutdown.

`IR_EMITTER=off` keeps the emitter dark and sets `led_mode` to none before every session, so a
state left by another tool cannot light it. The journal shows `emitter ON: led_mode=flash
exposure=100 lines ...` per session and the kernel logs `IR strobe timing: ...` at stream start.
While `/run/sl7-ir-bridge.hands-off` exists and is younger than two minutes the bridge neither sets
nor clears `led_mode` (the stage C test tool of omarchy-surface-sl7 uses it so its own
`led_mode` is not overridden; the kernel limits still apply).
The emitter is lit only while the bridge streams, which is only while a consumer is reading, for
at most 10 s per session.

## Sandbox

Root with only `CAP_SYS_PTRACE` and `CAP_DAC_READ_SEARCH` (to read other users' `/proc/<pid>/fd`
for the EBUSY report; the syscall filter still has no `ptrace`, and `open_by_handle_at` is denied),
`NoNewPrivileges`, `DevicePolicy=closed` with
`DeviceAllow` for `char-media` and `char-video4linux` only, `ProtectSystem=strict`,
`ProtectHome`, `PrivateTmp`, `PrivateNetwork`, the kernel and clock protections,
`MemoryDenyWriteExecute`, a `@system-service` syscall filter without `@privileged`
and `@resources`, `MemoryMax=64M`, and a `RuntimeDirectory` (`/run/sl7-ir-bridge`) for the EBUSY
flag file. `ProtectProc=invisible` is gone (it hid the processes it must inspect). `systemd-analyze
security` was 1.1 OK before these changes; not re-measured.
It restarts on failure with no start limit.

## Known limits

- One consumer at a time (v4l2loopback 0.15.4 gives the capture side to one
  client). A second one fails at `REQBUFS` with `EBUSY`.
- The client-usage event has one queue slot; if a consumer closes and reopens
  within a single wake-up the 0 can be coalesced away. After a session cap the
  bridge asks v4l2loopback for the client count again every second (a new
  subscription with SEND_INITIAL), so a consumer that went away abruptly does not
  leave the bridge waiting.
- The default udev rules give the CAMSS and subdev nodes to group `video`. The
  emitter plan wants them root-only; that is a separate udev change.
- PipeWire and browsers must not hold the IR path or the loopback. `libcamera-sl7`
  0.7.2-4.3 no longer registers the IR sensor, and `omarchy-surface-sl7` ships a
  WirePlumber drop-in that hides the `qcom-camss` video nodes and "SL7 IR Camera" from
  PipeWire (see "Stuck in EBUSY" below). Chromium's own V4L2 enumeration (without the
  PipeWire camera flag) can still list the loopback.
- Lit frames at Windows' 100 line exposure are dim (stage C: mean 20 of 255, p99 38 at
  default gain). The face detector thresholds in omarchy-sl7-faceunlock are set for that.
- Not run on hardware: only the repacking logic is unit tested (`make check`).

## Build

```
make            # sl7-ir-bridge
make check      # unit tests of the repacking logic
```
