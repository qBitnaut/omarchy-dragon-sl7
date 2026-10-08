# libcamera-sl7

Arch Linux ARM's `libcamera` 0.7.2 rebuilt for the Surface Laptop 7, with a camera sensor
helper for the front camera (OmniVision OV02C10). It builds the same split packages
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

## Differences from the ALARM package

| | |
|---|---|
| Version | `0.7.2-4.1`: pkgrel 4.1 sorts above ALARM's 4. A later ALARM pkgrel (5 or more) would win again; bump ours when that happens. |
| Patches | the OV02C10 helper; ALARM's Python 3.14 fix, with trailing whitespace stripped |
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

Change `pkgver`, the tag in `source`, and re-check that the helper patch still applies
(`git apply --check`). Compare with ALARM's `extra/libcamera/PKGBUILD`. Keep `.SRCINFO` in step
(the workflow diffs it against `makepkg --printsrcinfo`).
