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
| `/etc/sl7-ir-bridge.conf` | `IR_EMITTER=off` and optional timing settings |

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
   msm_csid0 -> msm_vfe0_rdi0 -> video node` by entity name, enables the links on
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

Session cap: one CAMSS streaming session lasts at most 10 s (`IR_SESSION_MAX_MS`,
clamped to 10000). After that the bridge stops the stream, logs it, and waits for
a fresh consumer start (the consumer closes the device and opens it again) before
streaming again. This is a safety budget for the emitter work and also bounds the
sensor's on time.

Failures: if the CAMSS setup or start fails the bridge logs the reason and retries
every 5 s while a consumer is waiting; no frames arrive and the consumer times
out (no fake frames are sent). If no frame arrives for 4 s (first) or 1.5 s
(later) the session is stopped. If the loopback disappears the daemon exits and
systemd restarts it.

## Self test

```
sl7-ir-bridge --selftest [-n 30] [-d /dev/v4l/by-id/sl7-ir-camera]
```

Streams N frames from the loopback as a normal consumer (so it wakes the sensor
through the bridge) and prints the time to the first frame, fps and mean
brightness. No images are saved. The first frame it receives is the bridge's idle
black frame and is not counted. Exit status 0 pass, 1 failure, 3 frames received
but all black (a dark scene while the emitter is not working yet).

## IR emitter hook (disabled)

The emitter does not work yet and this package never drives an LED or a GPIO.
The hook points are in `ir_emitter.c`:

- `ir_emitter_pre_stream()` runs after the links and formats are set and just
  before STREAMON;
- `ir_emitter_post_stream()` runs after STREAMOFF and on every error path after
  `pre_stream`.

Per the emitter plan (stage D), the later implementation sets the vd55g
subdev's `led_mode` control (`V4L2_CID_FLASH_LED_MODE`) to flash before STREAMON
when the control exists and the config enables it, and back to none after
STREAMOFF. That code is present but compiled out: it needs
`-DSL7_IR_EMITTER_BUILD=1`, which the PKGBUILD does not pass, and even then
`IR_EMITTER=on` in `/etc/sl7-ir-bridge.conf`. In this package version
`IR_EMITTER=on` is ignored with a warning, and it must stay off. The kernel owns
the real safety limits; the 10 s session cap above is the bridge's own.

## Sandbox

Root with an empty capability set, `NoNewPrivileges`, `DevicePolicy=closed` with
`DeviceAllow` for `char-media` and `char-video4linux` only, `ProtectSystem=strict`,
`ProtectHome`, `PrivateTmp`, `PrivateNetwork`, the kernel and clock protections,
`MemoryDenyWriteExecute`, a `@system-service` syscall filter without `@privileged`
and `@resources`, `MemoryMax=64M`. `systemd-analyze security` rates it 1.1 OK.
It restarts on failure with no start limit.

## Known limits

- One consumer at a time (v4l2loopback 0.15.4 gives the capture side to one
  client). A second one fails at `REQBUFS` with `EBUSY`.
- The client-usage event has one queue slot; if a consumer closes and reopens
  within a single wake-up the 0 can be coalesced away. After a session cap the
  bridge then does not restart until the next real stop; the consumer times out
  and a retry works.
- The default udev rules give the CAMSS and subdev nodes to group `video`. The
  emitter plan wants them root-only; that is a separate udev change.
- Browsers and PipeWire will list "SL7 IR Camera". A WirePlumber rule that hides
  it (and the raw CAMSS node) is still to do.
- Not run on hardware yet: only the repacking logic is unit tested (`make check`).

## Build

```
make            # sl7-ir-bridge
make check      # unit tests of the repacking logic
```
