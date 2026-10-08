# libcamera-sl7

Arch Linux ARM's `libcamera` 0.7.2 rebuilt for the Surface Laptop 7, with a camera sensor
helper for the front camera (OmniVision OV02C10) and three software ISP fixes. It builds the same split packages
(`libcamera`, `libcamera-ipa`, `libcamera-tools`, `gst-plugin-libcamera`, `python-libcamera`),
so the omarchy-sl7 repository replaces Arch's with a plain `sudo pacman -Syu`.

## Why

Without a helper for the sensor, libcamera's software ISP cannot run AGC for it and logs
`Failed to create camera sensor helper for ov02c10`. The helper
([patch 28362](https://patchwork.libcamera.org/patch/28362/), François Roux, under review
upstream) declares the analogue gain as `AnalogueGainLinear{ 1, 0, 0, 16 }` (the driver's codes
0x10 to 0xf8 are 1x to 15.5x in 1/16 steps) and a black level of 4096 (64 at 10 bits). It is
carried unmodified as `0001-ipa-libipa-camera_sensor_helper-add-ov02c10.patch` until it is
released.

## Software ISP fixes (0002 to 0004)

Found by reading a debug capture from the laptop (libcamera 0.7.2, software ISP with the Adreno
EGL debayer). Each is a separate patch against 0.7.2, in the style of an upstream submission.

| Patch | What it does and why |
|---|---|
| `0002-ipa-simple-agc-converge-quickly-after-stream-start` | The AGC corrects the exposure by at most about 10% per statistics update, so the first seconds of a stream are badly exposed. For the first six updates it scales the total exposure (exposure time times gain) by the squared ratio of the optimal to the measured mean sample value (limited to 0.25 to 4) and splits the result in one go: exposure time first up to its maximum, the remainder as gain (when darkening, gain first, then exposure time). Afterwards the existing proportional step applies, capped at +-15% both ways. A black frame (MSV 0) takes the maximum step; a non-finite MSV is ignored. |
| `0003-libcamera-software_isp-debayer_egl-compute-stats-on-the-displayed-area` | `DebayerEGL::configure()` set the statistics window to `Rectangle(window_.size())`, origin 0,0, but the EGL path passes the whole input buffer to `SwStatsCpu::processFrame()` (the CPU debayer passes only the part it processes, so there 0,0 is right). When the output is smaller than the sensor frame, such as 720p, AGC and AWB measured the top left corner instead of the displayed area. The patch passes `window_` with its offset. |
| `0004-ipa-simple-adjust-read-default-gamma-contrast-saturation-from-tuning` | `Adjust::init()` ignored its tuning data. It now reads optional `gamma`, `contrast` and `saturation` keys from the `Adjust` block and uses them as the defaults, also in the control info; controls set by an application still override them. A tuning file without the keys behaves as before. `sl7-camera-tuning` writes contrast 1.2 and saturation 1.15. |

Not done: the first one or two frames are still rendered with the debayer's built-in defaults
(black level 0, gamma 1, identity matrix, white balance gains 1) because `SoftwareIsp::process()`
uses the parameters saved from the previous frame and the IPA computes them asynchronously.
Seeding them needs values from the IPA before the first frame and a change in the pipeline
handler's flow, which is not a small patch.

Long term: libcamera master (0.8) replaces the simple pipeline's AGC with libipa's shared AGC
(the one the Raspberry Pi and other pipelines use). When 0.8 reaches Arch, drop 0002 and re-check
whether 0003 and 0004 are still needed.

## Differences from the ALARM package

| | |
|---|---|
| Version | `0.7.2-4.2`: pkgrel 4.2 sorts above ALARM's 4. A later ALARM pkgrel (5 or more) would win again; bump ours when that happens. |
| Patches | the OV02C10 helper; the three software ISP fixes above; ALARM's Python 3.14 fix, with trailing whitespace stripped |
| Not built | `libcamera-docs` (it needs TeX Live), tests and `check()` |
| Unchanged | dependencies, build options, split packages, the signed IPA modules |

IPA modules are signed at build time with a per-build key whose public half is embedded in
`libcamera.so`, so `libcamera` and `libcamera-ipa` must come from the same build. They do: both
are published by the same workflow run.

## Not included

libcamera issue 355 (the EGL debayer does not fully apply the AWB blue gain on some sensors) is
not patched: the shader code reads correctly and the report does not identify the cause.
`LIBCAMERA_SOFTISP_MODE=cpu` avoids the GPU path.

## Tuning

This package carries no tuning. `sl7-camera-tuning` in `omarchy-surface-sl7` builds the colour
tuning on your machine from Microsoft's driver package (see its README, section 8k).

## Updating

Change `pkgver`, the tag in `source`, and re-check that the patches still apply in order
(`git apply --check`, applying each one before checking the next). Compare with ALARM's `extra/libcamera/PKGBUILD`. Keep `.SRCINFO` in step
(the workflow diffs it against `makepkg --printsrcinfo`).
