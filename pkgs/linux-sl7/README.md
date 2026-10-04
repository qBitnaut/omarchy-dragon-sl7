# linux-sl7

A Linux 7.2.8 kernel package for the Microsoft Surface Laptop 7 (Snapdragon X
Plus and X Elite) on Arch Linux ARM and Omarchy. This is v0: the base config,
a patch queue and the CI that builds them. Nothing here has been booted on
hardware yet.

## What v0 is

- **Base:** Arch Linux ARM `core/linux-aarch64` (PKGBUILD and config, 7.2.x),
  upstream linux 7.2 plus the 7.2.8 stable patch. ALARM's own five patches
  (Rockchip and Raspberry Pi 5 only) are not carried.
- **Packages:** `linux-sl7` and `linux-sl7-headers`.
- **Side by side:** no `provides` or `conflicts` for `linux` or
  `linux-aarch64`, so the stock `linux-aarch64` stays installed as the rescue
  kernel. Nothing is installed in `/boot`.
- **Layout:** `vmlinuz` and `pkgbase` go in `/usr/lib/modules/<ver>/`
  (the linux-sp11 and Arch style). Qualcomm DTBs go in the private directory
  `/usr/lib/modules/<ver>/dtbs/qcom`. Omarchy's `dtb-uki.sh` defaults to
  `/boot/dtbs/qcom`, so point it here with `OMARCHY_QUALCOMM_DTB_DIR`.
- **Config:** `config.alarm` (vendored ALARM config) with `config.sl7` merged
  over it. `scripts/check-config.sh` asserts every fragment option after
  `olddefconfig`.

### Config fragment

| Options | Why |
|---|---|
| `SURFACE_PLATFORMS=y`, `SURFACE_AGGREGATOR=m`, `SURFACE_AGGREGATOR_BUS=y`, `SURFACE_AGGREGATOR_REGISTRY=m`, `SURFACE_AGGREGATOR_HUB=m`, `SURFACE_HID=m`, `SURFACE_HID_CORE=m` | internal keyboard |
| `SURFACE_PLATFORM_PROFILE=m`, `SENSORS_SURFACE_FAN=m` | platform profile and fan |
| `SPI_HID=m`, `SPI_HID_OF=m` | touchpad and SPI touchscreen |
| `CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y` | battery life |
| `ARM_SCMI_CPUFREQ=y` | built in, so the SCMI autoload series is not needed |
| `VIDEO_QCOM_IRIS=m`, `SM_VIDEOCC_8550=m` | hardware video decode |

## Patch queue

`patches/series` lists the patches in apply order. Each patch has `Origin:`
and `Upstream-Status:` headers in its commit message. Patches apply with plain
`patch -p1` on linux 7.2.8.

| # | Patch | Origin | Upstream status |
|---|---|---|---|
| 0001-0002 | QSPI 1-4-4 in spi-geni-qcom, QSPI protocol in GPI | dwhinham/linux-sp11 (`1b7e53984d`, `092fa92263`), from Nikkuss/scuggo | not posted |
| 0003-0013 | spi-hid v4 series (HID core, transport, ACPI, DT, binding, PM, panel follower) | Chromium v4 (2026-06-09), carried via dwhinham/linux-sp11 (`f2ab65f537`..`ace142773e`) | v4 on list, no v5 |
| 0014-0015 | spi-hid single full duplex transfer, SPI id table entry | dwhinham/linux-sp11 (`6673ac0122`, `378b6a8f72`) | not posted |
| 0016 | romulus: touchpad on `spi19` (QSPI, IRQ gpio3, reset gpio120, VDD gpio65, data gpio66/67) | ours; nix1e `b274dd7`, SSDT `HSPI` | pending the series above |
| 0017 | romulus13: SPI touchscreen `GTCH` on `spi10` (40 MHz, IRQ gpio51, reset gpio48, VDD gpio64) | ours; linux-sp11 `6080c70979`, nix1e `b274dd7`, SSDT `GTCH` | pending the series above |
| 0018 | SCMI perf: ignore a sustained frequency below the lowest OPP | rafaelguariento, omacom/omarchy discussion 12441 | not submitted |
| 0019 | qcom_battmgr: report capacity on X1E80100 | Liviu Nicoara, patchwork series 1169875 | submitted 2026-09-20 |
| 0020-0022 | ps883x v5 (DP state F, config delay, disable USB4 on incomplete platforms) | Jens Glathe, usb-next `42411ff1a7bb`, `d9eadbba6663`, `647f31f34d40` | in usb-next, expected in 7.4 |
| 0023 | ath12k: ignore the false rfkill hard block | linux-sp11 `37f883437b` (Jiajie Chen) | will not go upstream |
| 0024 | EXPERIMENTAL: eDP variable refresh (DPU INTF AVR, MSA ignore, `vrr_capable`) behind `msm.vrr_enabled=1` (default 0; see `omarchy-sl7-test-entry`) | scuggo/x1e-nixos `msm-vrr-avr.patch` (ca7db70), rebased and gated by us | will not go upstream as is |

Notes on the DT patches:

- Pins were cross-checked against the Surface Laptop 7 ACPI SSDT. The
  touchscreen node is for units with a G6 touch module (MSHW0460). Units
  with TBID 2 or 3 use an I2C touchscreen (MSHW0468) that is not covered.
- Both nodes use the compatible `microsoft,g6-touch-digitizer`,
  `hid-over-spi`. The touchpad speaks the same protocol (identical `_DSM`),
  and the binding only allows that vendor string.
- `read-opcode` and `write-opcode` are 32-bit cells because the carried
  driver reads them with `device_property_read_u32()`, although the binding
  says uint8. The same mismatch exists in the SP11 device tree.
- `dtbs_check` therefore reports three known findings: `qcom,geni-spi-qspi`
  is not in the geni-se binding, and the opcode type and size. They are
  allow-listed in `scripts/check-dtbs.sh`; anything else fails.

## Build

### Quick validation (any machine, about 1 to 2 minutes)

```
scripts/fast-check.sh <work-dir>
```

This downloads and verifies linux 7.2 and the 7.2.8 patch, applies the
series, merges and asserts the config, builds the romulus13 and romulus15
DTBs, and runs `dtbs_check` if `dt-validate` (dtschema) is on `PATH`. On an
arm64 host, `SL7_COMPILE=1` also compiles the objects the queue touches.
Needs `bc flex bison libssl-dev` and `dtc`. The individual steps are
`fetch-source.sh`, `apply-series.sh`, `make-config.sh` and `check-dtbs.sh`.

### Full package build

On an Arch Linux ARM machine (a full build takes hours; use CI if you can):

```
cp -a pkgs/linux-sl7 /path/to/build && cd /path/to/build
cp -a scripts/check-config.sh patches/* .
makepkg -s
```

makepkg looks up local sources by basename in the build directory, so the
helper script and the patches must sit next to the PKGBUILD (CI's
`scripts/ci-build.sh` does the same).

### CI

`.github/workflows/linux-sl7.yml` runs on pushes to `pkgs/linux-sl7/**` and
on manual dispatch, on `ubuntu-24.04-arm`:

1. **fast-check:** shellcheck, `fast-check.sh` with compile of touched drivers.
2. **full-build:** `makepkg` in the pinned `omarchy-pkg-builder` Arch Linux ARM
   container (`scripts/ci-build.sh`), `MAKEFLAGS=-j$(nproc)`, ccache keyed on
   the version and a hash of the config and patches, 300 minute timeout.
   Artifacts: both packages, `Image`, the Qualcomm x1 DTBs, `config.final` and
   `SHA256SUMS`. `scripts/guard-artifacts.sh` fails the job if any `*.mbn`,
   `*_dtbs.elf` or `*.jsn` file appears, loose or inside a package.

### Rebasing

Bump `pkgver` (and the `_srcname` base for a new minor), refresh the two
kernel.org sums in the PKGBUILD, update `config.alarm` from ALARM, then run
`fast-check.sh`. Drop patches as they land upstream.

## Not in v0

Camera (OV02C10, IR), USB4 host router, fused-core handling for X1P-64-100,
Iris DT enablement, DP audio, the EC reboot helper. See the project PLAN.md.

## Licensing

- Scripts, workflow and packaging glue in this directory are MIT, as in the
  repository LICENSE. The PKGBUILD derives from the Arch Linux ARM
  `linux-aarch64` PKGBUILD.
- Everything under `patches/` is GPL-2.0 (GPL-2.0-only, like the Linux kernel
  it modifies) and keeps its original authors and sign-offs.
- `config.alarm` is the Arch Linux ARM kernel configuration.
- No Microsoft or Qualcomm firmware is built, committed or distributed here.
