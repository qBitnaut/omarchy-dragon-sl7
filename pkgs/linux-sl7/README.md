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
| `VIDEO_QCOM_CAMSS=m`, `PHY_QCOM_MIPI_CSI2=m`, `I2C_QCOM_CCI=m`, `CLK_X1E80100_CAMCC=m`, `V4L2_FWNODE=m`, `V4L2_CCI_I2C=m` | X1E camera subsystem (patches 0025-0037) |
| `VIDEO_OV02C10=m`, `VIDEO_VD55G=m` | front RGB and IR sensors (`VIDEO_VD55G` replaces `VIDEO_VD55G1`) |
| `LEDS_CLASS_FLASH=m`, `LEDS_QCOM_FLASH=m`, `V4L2_FLASH_LED_CLASS=m` | PMIC flash LED class; not described in the DT, so nothing fires the illuminator |

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
| 0024 | eDP variable refresh (DPU INTF AVR, MSA ignore, `vrr_capable`) behind `msm.vrr_enabled=1` (kernel default 0; omarchy-surface-sl7 sets it on the default cmdline) | scuggo/x1e-nixos `msm-vrr-avr.patch` (ca7db70), rebased and gated by us | will not go upstream as is |
| 0025-0026 | qcom MIPI CSI2 DPHY schema and driver (`phy-qcom-mipi-csi2`) | Bryan O'Donoghue v18 (patchwork 1166977, 2026-09-16) | in linux-next, expected in 7.4 |
| 0027-0032 | `phy_get_by_of_node()` helpers, CAMSS PHY API, data-lanes start at 1 | Bryan O'Donoghue v20 (patchwork 1168715, 2026-09-18) | posted v20 |
| 0033-0034 | x1e80100 CAMSS binding: iommus, optional csiphy supplies | x1e/Hamoa camera DTSI v7 patches 1-2 (patchwork 1167605) | posted v7 |
| 0035 | x1e80100 CAMCC node (also purwa compatible) | torvalds `6a3568f938c9` | merged for 7.3 (backport) |
| 0036-0037 | x1e80100 CCI0/1 and CAMSS plus four standalone CSIPHY nodes | camera DTSI v7 patches 3-4 | posted v7, unreviewed |
| 0038-0040 | ST VD55G family driver with VD55G0 (replaces `vd55g1`), binding, firmware header | petm5, linux-surface/kernel PR 169 (patches 3, 4, 7-9; the x86 IPU6 patches are dropped) | posted as linux-media 1169036 v2; ST pushes back on merging G0 into the G1 driver |
| 0041 | vd55g: no strobe GPIO and no flash LED control unless `st,leds` is set | ours | not for upstream |
| 0042 | HACK vd55g: `mclk_index` and `mclk_hz` module parameters (`mclk_hz` alone retunes the DT clock) | ours | not for upstream, drop once the clock is known |
| 0067 | camss: stop the subdevs already started when a later `s_stream(1)` fails | ours | candidate for linux-media (same code in mainline) |
| 0043 | romulus: front RGB OV02C10 (CCI1, CSIPHY4, MCLK4, PM8010 rails l1m/l3m/l5m) | ours, from ELLX / bryce / Oliver White v2, on the v7 DTSI style | pending |
| 0044 | romulus13: IR VD55G0 (CCI0 0x10, CSIPHY0 1 lane, 378 MHz, reset gpio109, pinned rails l2m 1.2 V / l4m 1.8 V / l6m 1.8 V, MCLK0 plus pinctrl states mclk1..3), **no illuminator** | ours; `ir/REPORT.md` | pending |
| 0068-0069 | serial: qcom-geni force suspend/resume in the system sleep callbacks, and the unbalanced-resume fix | torvalds `d0cd9c8d0fd5` (v7.3-rc1), `3098c989bd38` (v7.3-rc6) | merged for 7.3 (backport) |
| 0070 | SL7 local: ps883x drops the XO clock while the retimer is in reset | ours | not submitted |
| 0071 | SL7 local: log why PCI D3cold is vetoed (dynamic debug only) | ours | not submitted |
| 0072 | PCI: allow D3 for native hotplug-capable Root Ports on non-x86 | torvalds `d4c79b63d82d` (Manivannan Sadhasivam, v7.3-rc1) | merged for 7.3 (backport) |
| 0082 | hwmon: `qcom_pld_power`, read-only firmware power telemetry (CPU clusters, GPU, system, USB) | ItsLucas, `drivers/qcom-pld-power/` at `1cc387f` (GPL-2.0-only), author kept, only build glue changed | not submitted; author says it needs a reviewed binding and more firmware evidence |
| 0083 | romulus (13.8 and 15 inch): `pld-power@81f30000` node for 0082 | ours; resource from ItsLucas's `sl7_pld_device` | not submitted |
| 0084 | SL7 local: romulus13 disables `&pcie3` and `&pcie3_phy` (the 15 inch card reader slot, empty on the 13.8 inch) | ours; RUNTIME-PLAN C1 | not submitted (candidate: romulus13 fix) |
| 0085 | ath12k: DTIM stick mode for station vdevs (the STA follows the AP DTIM instead of listen interval 5) | torvalds `af50baccaa5f` (Daizhuang Bai, v7.3-rc1) | merged for 7.3 (backport) |
| 0086 | SL7 local: romulus (13.8 and 15 inch) enables `&iris` with the Microsoft signed `qcom/x1e80100/microsoft/Romulus/qcvss8380.mbn` (V4L2 stateful decoder and encoder) | ours; firmware from the SL7 MSI via `omarchy-surface-sl7-firmware` | not submitted (needs signed firmware in linux-firmware) |
| 0087-0088 | clk and genpd: defer disabling of unused clocks and power domains by 30 s, **only with `clk_unused_defer` on the command line** (used by `omarchy-sl7-test-entry enable clk-unused`) | jhovold/linux `1e3e4a97ba7e`, `b3f09e07cfbb` (Johan Hovold, Sep 2024) plus our opt-in gate | not mainline; Hovold's WIP, drop when mainline has an equivalent |
| 0089 | SL7 local: drm/msm/dpu computes the core clock per layer mixer when the CRTC uses several mixers (3D merge): mode clock divided by the mixer count, planes wider than a mixer split in two pipes, plane clocks read from the checked state | ours; companion of `f5d079564c44` (Jessica Zhang, mode filter only) | not submitted (discuss with Dmitry Baryshkov and Jessica Zhang first) |
| 0090 | SL7 local: ps883x module parameter `fixed_phy_orientation` (on by default since 7.2.8-18; `ps883x.fixed_phy_orientation=0` disables it): the downstream QMP PHY is always told TYPEC_ORIENTATION_NORMAL while the retimer state and REG0 ORIENTATION_REVERSED bit follow the real plug | ours | not submitted (SL7 specific, firmware-dependent) |
| 0091 | SL7 local: leds-qcom-flash `ir_max_ua` module parameter (flash current limit per channel for IR LEDs, default 25000 uA, run-time writable 12500 to 100000, hard cap 100 mA per channel in code); an IR LED refuses a larger flash_brightness with -EINVAL; 0080 timer and torch rules unchanged | ours; IR plan stage B | not submitted (SL7 specific) |
| 0092 | SL7 local: romulus13 replaces the four IR discovery LEDs of 0081 by one ganged IR LED on flash channels 1 and 4 (`ir:flash-14`, 200 mA total = 100 mA per channel at most, 10 ms) | ours; EMITTER-LOCATE.md section 7 | not submitted (SL7 specific) |
| 0093 | SL7 local: leds-qcom-flash read-only register instrumentation for IR strobes (`ir_test=1` only): 23 flash registers read at idle, arm, +3 ms, +15 ms and after strobe off, logged as "SL7 IR strobe snapshot" lines afterwards; pulse, current and timer unchanged | ours; IR plan stage B | not submitted (debug only) |
| 0094 | SL7 local: vd55g module parameter `illuminator` (read-only, default 0): `st,leds` and the `led_mode` control are honoured only with `illuminator=1` (the IR test boot, via the omarchy-surface-sl7 modprobe rule), so a normal boot never drives sensor GPIO 1 | ours; IR plan stage C | not submitted (SL7 specific) |
| 0095 | SL7 local: leds-qcom-flash strobe instrumentation: registers 0x4f, 0x55, 0x67, 0x68, a +1 ms moment (key registers at t0 and +1 ms), STATUS3 read on its own at +15 ms, absolute-time waits, and the monotonic time of every snapshot | ours; IR plan stage C | not submitted (debug only) |
| 0096 | SL7 local: leds-qcom-flash IR hardware strobe arm: `hw_strobe_arm` attribute on the IR LEDs (`ir_test=1`, 4ch): CHAN_STROBE 0x05 (hardware, level, active high, source bits 6:4 = 0), 10 ms timer, at most 25 mA per channel whatever `ir_max_ua` says, auto disarm after 1 s, disarm on remove, shutdown and suspend, 30 ms back-to-back status poll logged afterwards. Torch still refused | ours; EMITTER-LOCATE.md section 7 | not submitted (SL7 specific) |
| 0097 | SL7 local: romulus13 `st,leds = <1>` on the IR sensor (GPIO 1 strobe, gated by 0094) and a second ganged IR LED `ir:flash-23` (channels 2 and 3, same limits) for the T0b decode check | ours | not submitted (SL7 specific) |
| 0098 | SL7 local: vd55g holds exposure (at most 100 lines) and frame length (at least 1750 lines) to the values Windows Hello programs whenever `led_mode` is not off, at control set time, on `led_mode` change and at stream start, auto exposure replaced by manual while the strobe is on; the `illuminator` parameter (0094) now defaults to 1 (`illuminator=0` disables the strobe) | ours; IR plan stage C result | not submitted (SL7 specific) |
| 0099 | media: i2c: ov02c10: accept a 12 MHz external clock with a 250 MHz link frequency (19.2 MHz stays 400 MHz, any other pairing is refused at probe); pixel rate follows the link frequency; default frame length scaled with the link frequency (2328 lines at 400 MHz, 1455 at 250 MHz) by one helper; no new register values | Ryan Thomas Cragun report, linux-media 2026-07-02; Sakari Ailus' reply | not submitted yet, upstream candidate |
| 0100 | SL7 local: romulus front camera clocked from a 12 MHz `fixed-clock` node (CAMCC MCLK4 reference and its 19.2 MHz assigned rate dropped, gpio100 pinctrl kept), `link-frequencies` 250 MHz | ours | not submitted (SL7 specific) |

PMIC IR LED patches (0080, 0081, 0091 to 0093, 0095, 0096): retired. The PM8550 flash LED path
proved to have no load (open circuit); the IR emitter is lit by the sensor's GPIO 1 strobe (0094,
0097, 0098) through sl7-ir-bridge on the normal boot, and the "IR test" boot entry is gone. These
patches are inert without `sl7.ir_test=1` (the omarchy-surface-sl7 modprobe rule keeps
`leds_qcom_flash` unloaded and the driver refuses the IR LEDs without `ir_test`) and are slated
for removal at the 7.3 rebase. linux-sl7 is not changed for this.

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
  allow-listed in `scripts/check-dtbs.sh`; anything else fails. The PLD power node (0083) adds a
  fourth, an unknown compatible (`qcom,x1e80100-pld-power`), allow-listed the same way; that regex is
  a guess at the message format, as `dt-validate` was not run.

## Power: 7.3 deepest-idle backport

Added in 7.2.8-5 (patches 0045-0065). Goal: let the SoC enter the
`domain_ss3` system idle state, so that `cxsd`, `ddr` and `aosd` have a chance
to count in suspend, and take the suspend-time fixes that go with it. Nothing
here has been booted on the SL7 yet. Measure with `sl7-sleepstats` (package
omarchy-surface-sl7; not yet packaged) before and after.

Baseline on 7.2.8-4: suspend (`PM: suspend entry (deep)`, 8 h 25 min) drew
about 0.8 to 0.9 W; Linux idle is about 5 W; `cxsd` and `ddr` never counted.
On the only other X1E machine measured with this stack (Dell Inspiron 7441,
omarchy discussion 12441) suspend stayed at 0.93 W overnight and `cxsd` stayed
at 0 even with `domain_ss3` entered, so treat a watt gain as unproven.

All patches are GPL-2.0 and carry the upstream author, `Signed-off-by` chain,
a `commit <sha> upstream.` line and `Origin:`/`Upstream-Status:` headers. Rework
is limited to the items marked below.

### Config: no Qualcomm Crypto Engine (7.2.8-6)

`config.sl7` sets `# CONFIG_CRYPTO_DEV_QCE is not set`. On 7.2 `qcrypto`
(`1dfa000.crypto`) takes a permanent 393600 kBps ALWAYS-tagged crypto to EBI1
interconnect vote at probe and has no runtime PM, so it holds DDR out of
collapse whenever it is bound. 7.3 marks the driver BROKEN (`df373d39c6f0`),
and the ARMv8 Crypto Extensions cover the kernel's crypto. A 10 minute suspend
on 7.2.8-5 with `qcrypto`, ath12k, `hci_uart` and USB wakeup removed still left
`cxsd`, `ddr` and `aosd` at 0, so this is not expected to be sufficient alone;
`sl7-sleepstats --trace` finds the remaining holders. `scripts/check-config.sh`
now also asserts `# CONFIG_X is not set` lines from the fragment.

### 7.3 PDC pass-through and deepest idle state (Maulik Shah)

Series "x1e80100: Enable PDC wake GPIOs and deepest idle state"
(`20260707-hamoa_pdc_v3-v4`, DT patch v5). The DT patch (0052) must never be
carried without 0045-0051: it lets the SoC enter a state in which the GIC is
powered down, so GPIO wakeups have to be routed through the PDC first.

| # | Subject | Upstream SHA | Tree |
|---|---|---|---|
| 0045 | irqchip/qcom-pdc: Restructure version support | `83e089ef0d4e` | torvalds, v7.3-rc1 |
| 0046 | irqchip/qcom-pdc: Move all static variables to struct pdc_desc | `60caa95aa14a` | torvalds, v7.3-rc1 |
| 0047 | irqchip/qcom-pdc: Differentiate between direct SPI and GPIO as SPI | `45af2d61edf6` | torvalds, v7.3-rc1 |
| 0048 | irqchip/qcom-pdc: Configure PDC to pass through mode | `ad01c2b2f291` | torvalds, v7.3-rc1 |
| 0049 | irqchip/qcom-pdc: Fix kernel doc for qcom_pdc_gic_secondary_set_type() | `d307a7e7d939` | torvalds, v7.3-rc1 |
| 0050 | pinctrl: qcom: Acknowledge IRQs for PDC interrupt controller | `f790ea0b699d` | torvalds, v7.3-rc1 |
| 0051 | Revert "pinctrl: qcom: x1e80100: Bypass PDC wakeup parent for now" | `77fbc756d9cb` | torvalds, v7.3-rc1 |
| 0052 | arm64: dts: qcom: x1e80100: Add deepest idle state (`domain_ss3`; cluster_cl5 latencies 2000/2000 us) | `95f827ceb21e` | torvalds, v7.3-rc1 |

0052 changes `hamoa.dtsi`, which `x1e80100.dtsi` and both romulus DTBs include;
the built `x1e80100-microsoft-romulus13.dtb` and `romulus15.dtb` contain
`domain_ss3` (`arm,psci-suspend-param = <0x0200c354>`, 2500/2500/9000 us) and
`power-domain-system` lists it in `domain-idle-states`. The series applies
unchanged on 7.2.8. Not carried: `c39df6b350ef` (x1e80100: reduce the OS PDC
DRV span to 0x10000, a size trim that the driver does not depend on).

### 7.4 pmdomain and cpuidle-psci (Ulf Hansson, Maulik Shah)

PSCI OS-initiated PM domains start powered off with `GENPD_FLAG_POWER_UNKNOWN`,
so cores that never come online no longer pin their cluster and the system
domain. Pinned to ulfh/linux-pm `next` (identical SHAs in linux-next), not yet
in a tag.

| # | Subject | SHA | Tree |
|---|---|---|---|
| 0053 | pmdomain: core: Rename genpd_status_on() | `81f1099186fd` | ulfh/linux-pm next |
| 0054 | pmdomain: core: Allow a non-CPU device in a CPU PM domain to do power on | `9e8dff8e0978` | ulfh/linux-pm next |
| 0055 | pmdomain: core: Add a genpd config to support unknown initial status | `2224d686e788` | ulfh/linux-pm next |
| 0056 | cpuidle: psci: Initialize the PM domains in powered off state for OSI | `6d3080bfe007` | ulfh/linux-pm next |
| 0057 | cpuidle: psci: Move initialization a bit earlier in the boot sequence | `65705b18162b` | ulfh/linux-pm next |
| 0058 | pmdomain: core: Fall back to node name for idle states | `46ff460038d6` | ulfh/linux-pm next |

### Suspend fixes (Abel Vesa, Linaro)

Both defer a Type-C worker to `system_freezable_wq` so it cannot touch the
PS8830 retimer over I2C while the I2C controller is suspended.

| # | Subject | SHA | Tree |
|---|---|---|---|
| 0059 | soc: qcom: pmic_glink: Fix device access from worker during suspend | `7d0767c5cd87` | qcom drivers-for-7.4 (linux-next) |
| 0060 | usb: typec: ucsi: Schedule connector worker on freezable workqueue | none (RFC, not merged) | lore `20250205-ucsi-schedule-conn-worker-on-freezable-wq-v1-1-107d1356b77b@linaro.org` |

0060 is the posted one-line RFC, rebased onto 7.2.8 by us (the Linaro tree
commit `4622de89` and linux-msm `7106d100ce` named in discussion 12441 were not
independently checked). In 12441 these two fixes were first blamed for doubling
suspend drain; that was a fan artefact, the retest showed 0.916 W against
0.926 W.

### QREF and refgen supplies for the TCSR clock controller (Qiang Yu)

Lets the kernel manage the QREF/refgen LDOs instead of leaving them as the
firmware set them. Upstream this is the same change Ubuntu's X1 kernel
carries. Expect no measurable power change (the LDOs are shared).

| # | Subject | SHA | Tree |
|---|---|---|---|
| 0061 | clk: qcom: Add generic clkref_en support | `22c70e573200` | torvalds, v7.3-rc1 |
| 0062 | dt-bindings: clock: qcom: Move x1e80100 TCSR to own binding | `fcbd3151c9be` | qcom clk-for-7.4 (linux-next); reworked |
| 0063 | clk: qcom: tcsrcc-x1e80100: Migrate to clk_ref helper | `011ed2a61f44` | qcom clk-for-7.4 (linux-next) |
| 0064 | arm64: dts: qcom: hamoa/purwa: Add QREF regulator supplies | `d9d07e230c45` | qcom arm64-for-7.4 (linux-next); reworked |

Rework: 0062's `qcom,sm8550-tcsr.yaml` hunk is rebased (on 7.2.8 the x1e80100
compatible still sits in the single enum); 0064 keeps only the
`x1e80100-microsoft-romulus.dtsi` hunk, because the other 18 board files do not
exist in 7.2.8 or are not SL7 hardware. All 18 supplies in the romulus hunk
match the binding.

### Other 7.4 queue

| # | Subject | SHA | Tree |
|---|---|---|---|
| 0065 | soc: qcom: pmic_glink: Avoid losing early rpmsg probe | `1517efff0e9d` | qcom drivers-for-7.4 (linux-next) |

Without it a pmic_glink rpmsg endpoint that appears before the platform device
has probed is dropped, and the battery manager and Type-C never come up.

### Already in 7.2.8, not carried

`rpmsg: glink: smem: order FIFO read after availability check` (`786439ad5876`)
and `PM: sleep: Unblock runtime PM when device prepare fails` (`cb258d651d74`)
are in the 7.2.8 stable patch, as is the `d9108bfdb746` drm/msm a6xx GMU RPMh
stop fix (checked in the patched 7.2.8 tree: the patches were found already
applied).

### Not carried, with reasons

| Item | Reason |
|---|---|
| EC standby notification (register `0xB9`) | Dell-only. It is the Qualcomm "Fan EC Interface" (`QCOM0D05`, I2C 0x3b) that Dell's `_DSM` pokes. The SL7 DSDT has no such device and its Modern Standby `_DSM` (UUID `11e00d56`, functions 3 to 8) only writes an `MSBN` record into the ABD region. The SL7's EC is the Surface Aggregator Module, and 7.2.8 `ssam_serial_hub_pm_*` already sends display-off (prepare), D0-exit (suspend), D0-entry (resume) and display-on (complete). |
| gcc-x1e80100 "Tie the CX power domain to controller" (`965dd2be7d35`) | Inert here: only `.use_rpm = true`, and no x1e80100 GCC `power-domains` DT or binding change is queued. A possible later experiment, not made without evidence. |
| interconnect "implement get_bw with rpmh_read" (`11a44c6087c6`) | Changes the boot-time vote state of every RPMh interconnect; X1E already hard-resets under bus starvation (see the QoS revert below). Needs on-device validation first. |
| `serial: qcom-geni: add force suspend/resume to system sleep callbacks` (`d0cd9c8d0fd5`) | Touches the UART resume path and sits in a churning series (nbcon conversion, revert, three fixes). It arrives with 7.3 anyway. |
| `ucsi: allow retries of ucsi_resume_work` (`a2463e239443`) | Only for drivers that call `ucsi_resume()`; `ucsi_glink` does not. |
| `pmdomain: qcom: rpmhpd: Skip retention by default` (`7178817f1904`) | No power evidence; changes every rpmhpd consumer; in 7.3. |
| ASPM/L1ss series, `PCI: Add support for PCIe WAKE# interrupt`, ath12k ASPM API conversion | Large, touches resume paths; L1ss is already enabled at both ends of the NVMe link on this platform. |
| drm/msm a6xx "Fix RPMH dependency votes" series (`eab0aff8965e`...) | Changes GPU voltage votes, not suspend or idle power. |
| interconnect x1e80100 QoS enable (`5a8b2cc36e79`) and DT clocks (`f49d819c8987`) | Not in 7.2.8; it was reverted upstream (`2cc67425a97e`, hard resets on Hamoa). Check that the 7.3 rebase target includes the revert. |

### Risks

- Resume: the stack changes which low power state the cores and the system
  domain request in suspend. ELLX's 7.3-rc3 broke resume on the SL7, and
  7.3-rc4 mainline suspended worse than 7.2.6 on the Dell (that run was later
  found to be fan-driven). The resume-sensitive pieces are 0048 (PDC mode
  switched via SCM), 0051 (GPIO wake routing back through the PDC), 0052 and
  0056.
- `cluster_cl5` (cluster power-off) is requested far more often once 0056 lands.
  The Dell owner removed it from the cluster domains because of the X1 DC ZVA
  reset erratum (laptops-kernel `5c3cf1033d`). If the SL7 resets under load or
  at idle, that is the first suspect.
- 0060 is an unmerged RFC.
- 0057 moves cpuidle-psci to `subsys_initcall`; the Dell owner saw a one-off
  CDSP `timeout waiting for subsystem event response` at boot with the pmdomain
  backport.

### Rebase onto 7.3

When 7.3 is tagged, drop 0045-0052, 0061 and 0068-0069, 0072 and 0085, and also 0053-0058, 0059, 0062-0065
only if they are in the tag (check with `git merge-base --is-ancestor`; they are
7.4-queued). Re-run `scripts/fast-check.sh`.

Diagnostic: `sl7-sleepstats` (pkgs/omarchy-surface-sl7, not in the PKGBUILD yet)
prints the qcom_stats counters, `power-domain-system` residency (S0 is
`domain_ss3`) and cpuidle totals; `--suspend-test` runs a measured suspend.

## Power: suspend holders (7.2.8-9, 7.2.8-10)

Added in 7.2.8-9 (patches 0068-0071) and 0072 (7.2.8-10), from the 7.2.8-7 `sl7-sleepstats --trace` capture of 2026-10-05 (8 min
`deep` suspend, qcrypto, BT, ath12k unloaded, USB wakeup off). The holder-by-holder mapping, with the trace
evidence, is `Research/omarchy-dragon-sl7/power/sleeptrace-20261005/HOLDERS.md`. In short, APPS held three DDR
BCMs (MC0, SH0, SH1, vote 1) through the 1 kBps vote that `1bf8000.pci` and `1c08000.pci` keep while their link
stays up, `xo.lvl` through the PCIe clkrefs, the SSAM UART clock chain and the two PS8830 retimer clocks, and
the ADSP woke 104 times a second. CX was not held. Nothing here has been booted on the SL7.

| patch | addresses | upstream status | risk |
|---|---|---|---|
| 0068 serial: qcom-geni force suspend/resume (`d0cd9c8d0fd5`) | `b88000.serial` (SSAM) is never runtime-suspended, so its SE clock, `gcc_gpll0`/XO, CX OPP and QUP core vote stay in suspend | in 7.3-rc1 | the UART is powered off for the whole suspend. SSAM wakes through its own GPIO (tlmm 91, armed by `ssam_irq_arm_for_wakeup()`); the serdev child suspends first and resumes last, so EC D0-exit/entry still run with a live UART. If keyboard, touchpad or battery input is dead after resume, drop 0068/0069 first |
| 0069 serial: qcom-geni fix unbalanced runtime PM resume (`3098c989bd38`) | follow-up to 0068 for `no_console_suspend` (a console that was not force-suspended must not be force-resumed) | in 7.3-rc6 | none beyond 0068. 7.3 has later serial changes (nbcon, `.pm` removal) that are not carried, so only these two apply to 7.2 |
| 0070 SL7 local: ps883x drops XO while in reset | `rfclka3`/`rfclka4` (RPMh `clka3`/`clka4`, held at 1 in the sleep set) were enabled at probe and never released for retimers that sit in reset with all supplies off | not submitted | the clock is taken after the supplies and before the reset GPIO is released, and dropped after the supplies go off. Not tested on hardware; if a USB-C port stops negotiating after plugging a device, drop 0070 |
| 0071 SL7 local: log the PCI D3cold veto | none directly. `pci_host_common_d3cold_possible()` is false for `1bf8000`/`1c08000`, so the controllers take the keep-link branch (1 kBps vote, clkrefs, aux clocks). The log lines name the vetoing device | not submitted | none (dynamic debug, silent by default) |
| 0072 PCI: allow D3 for native hotplug-capable Root Ports (`d4c79b63d82d`) | 7.2.8-9 trace with 0071: both root ports (`0004:00:00.0`, `0006:00:00.0`) stay in D0 at suspend_noirq (`current_state` unknown), so `pci_host_common_d3cold_possible()` vetoes D3cold and `1bf8000`/`1c08000` keep link, 1 kBps vote, clkrefs. The qcom root ports advertise Hot-Plug Capable (the driver sets NCCS for it), so `is_pciehp` is set and `pci_bridge_d3_possible()` returns false, `bridge_d3` stays 0, `pci_power_manageable()` is false and the PCI core never calls `pci_prepare_to_sleep()` on them. 0072 drops that restriction on non-x86 | in 7.3-rc1 | the qcom controllers now take the full D3cold path: PME_Turn_Off, link and PHY off, pwrctrl off (NVMe 3.3 V rail, Wi-Fi PMU), icc and clkref released. NVMe is already shut down cleanly (SHN) and reset on resume, but the rail is now cut and re-applied each suspend, and this path has not run on SL7 hardware. pciehp is suspended with the port. If resume hangs, NVMe or Wi-Fi vanish after resume, or `pciehp` removes devices, drop 0072 |

Not done, with reasons:

- dwc3-qcom: not a holder. `dwc3_qcom_suspend()` already calls `icc_disable()` on both paths; the earlier "never
  dropped" reading used the stored request, not the aggregate.
- PCIe: no patch drops the 1 kBps vote while the link is up. Upstream and next still keep it, and removing it
  risks an endpoint (Wi-Fi) with live DMA and no DDR vote. The fix is to get the D3cold path taken (the controller
  then releases `icc_mem`, `icc_cpu`, the OPP, the PHY and the clkref). 0071 is the first step. Do two
  suspends in one boot and compare; see HOLDERS.md section 3 for the suspected `state_saved` cause.
- BT UART `a98000.serial`: a stored qup-core/qup-config vote stays enabled after `hci_uart` is unloaded. It is not
  covered by 0068 (`pm_runtime_force_suspend()` skips a device already suspended) and it is not a DDR vote.
  Unresolved.
- ADSP wakeups (104/s): no kernel patch.

## Power telemetry: qcom_pld_power (7.2.8-12)

Patches 0082 and 0083, `CONFIG_SENSORS_QCOM_PLD_POWER=m` in `config.sl7`. It gives Linux on the
X1E the live power numbers it otherwise lacks (no RAPL, no other hwmon power driver), so an A/B of
a setting takes one to two minutes instead of a 30 minute battery-gauge run. The userspace side is
`sl7-powermeter` in `omarchy-surface-sl7` (see its README, section 12d, for the rails and how to read
them).

**Provenance and licence.** The driver is ItsLucas's
[surface-laptop-7-ubuntu-kernel](https://github.com/ItsLucas/surface-laptop-7-ubuntu-kernel),
`drivers/qcom-pld-power/` at commit `1cc387f` (2026-09-27), GPL-2.0-only (SPDX headers on every
file, `GPL-2.0` licence file in that repository, `MODULE_LICENSE("GPL")`), compatible with this
kernel. Patch 0082 carries it with ItsLucas as author (`From:` and `MODULE_AUTHOR`, plus an author
note in each file); no sign-off is added on his behalf. What changed: the three files
(`qcom_pld_power.c`, `qcom_pld_protocol.h`, `qcom_pld_cache.h`) moved to `drivers/hwmon/`, a Kconfig
symbol and Makefile line replaced the external module build, and the author notes were added; the
code is otherwise his. His `sl7_pld_device` bridge is not carried: it matched DMI, BIOS
`175.235.235` and `microsoft,romulus15` only, and refused the 13.8 inch on purpose. Patch 0083
describes the device in the shared romulus DTSI instead, so both sizes bind.

**Read only.** The driver maps the 24 KiB firmware region `0x81f30000` read-only and uncached
(`PAGE_KERNEL_RO`), reads the producer counter and seven u16 fields from the one-second ring, and has
no write, control, limit, reset or raw-memory interface. It refuses to probe unless the range is
EFI reserved memory and not System RAM, returns `ENODATA` until the firmware counter advances, and
`EIO` on a torn read, so a wrong region fails closed. A deferrable work item refreshes a cached
snapshot once a second (it does not wake an idle CPU) and a PM notifier invalidates it across suspend.

hwmon `qcom_pld_power`, per channel `powerN_label`, `powerN_average` (uW) and
`powerN_average_interval` (1000 ms), plus `update_interval`:

```
grep . /sys/class/hwmon/hwmon*/name | grep pld      # find it
sensors 'qcom_pld_power-*'                          # if lm_sensors is installed
cat /sys/class/hwmon/hwmonN/power{1..7}_{label,average}
```

power1-7 are CPU_CLUSTER_0, CPU_CLUSTER_1, CPU_CLUSTER_2, GPU, PSU_USB, USBC_TOTAL, SYS.

**Status.**

- Validated by the author on a 15 inch X1E-80-100, BIOS 175.235.235 (cluster mapping by affinity
  load, one-second averaging against the 100 ms ring, suspend/resume, module reload).
- Not validated by anyone: the 13.8 inch (the author's earlier "Romulus13" record was this 15 inch
  booting the romulus13 DTB), GPU load, battery and USB rail meaning, absolute calibration, a cold
  Linux-only boot, and whether the firmware measures or models the rails.
- Here: patches apply on 7.2.8 with the queue, the driver compiles for aarch64 with clang, and its
  undefined symbols are all exported. Nothing was booted. The DT node was not compiled (no `dtc`
  on the dev box).
- The `qcom,x1e80100-pld-power` compatible is the author's provisional string with no upstream
  binding, so `dtbs_check` may report the node as undocumented.
- 7.2.8's `hamoa.dtsi` still reserves `pld-pep` (no-map); 7.3 drops it because EFI reserves it. The
  driver's checks should pass either way, but this is read from the code, not seen on hardware.
- It loads on every boot once built (the DT node triggers the module alias). To switch it off:
  `echo 'blacklist qcom_pld_power' | sudo tee /etc/modprobe.d/no-pld-power.conf`.

## Runtime power, round 1 (7.2.8-13)

Two small patches for screen-on power and Wi-Fi power save. Neither has been built into a kernel
package or run on the SL7 yet; the checks below are static.

- **0084, no card reader on the 13.8 inch.** `x1e80100-microsoft-romulus.dtsi` enables `pcie3` and
  `pcie3_phy` for the 15 inch's RTS5261 card reader. The 13.8 inch has none (Windows lists only the
  Wi-Fi and NVMe root ports), so the controller never trains a link, and `pcie-qcom` keeps the
  maximum OPP it voted at probe: a 15.75 GB/s peak interconnect vote on DDR (the largest on the
  system), the Gen4 x8 PHY with its clocks and the `tcsr_pcie_8l_clkref_en` XO reference. The
  patch sets both nodes to `disabled` in `x1e80100-microsoft-romulus13.dts` only; romulus15 is
  unchanged. Nothing else references pcie3: `pcie3_port0` is a child of the controller, the
  `pcie3_default` pinctrl state is used only by `pcie3`, the PHY supplies (`vreg_l3c`, `vreg_l3e`)
  are shared and stay, `vreg_nvme` belongs to `pcie6a`, and the gcc node's `pcie3_phy` clock
  parent is a disabled-by-default node on every other board. There is no dedicated pcie3 slot
  regulator in the romulus DT. Expected: the `llcc_mc` peak falls from 15753000 to 7876500 kBps and
  the DDR vote with it (NVMe becomes the floor at 7.88 GB/s), and the pcie3 PHY, clocks and GDSC
  go off. Estimated gain 0.1 to 0.4 W; not measured. `dtc` was not available when the patch was
  written, so the DTS change was reviewed by hand, not compiled.
- **0085, ath12k DTIM stick mode.** `af50baccaa5f` applies to 7.2.8 with the queue (two offsets,
  no fuzz) and `ath12k/mac.o` compiles for arm64 with the ALARM config. It sets
  `WMI_VDEV_PARAM_DTIM_POLICY` to stick for station vdevs when the target supports STA power save.
  With power save on, the firmware followed listen interval 5 (500 ms) instead of the AP's DTIM,
  which added latency. It does not save power by itself; it makes Wi-Fi power save on battery
  (`omarchy-surface-sl7-power wifi-powersave enable`) less painful. Tested upstream on WCN7850.

Measure with `sl7-powermeter` (omarchy-surface-sl7 README, section 12d), battery, backlight 30%:

- 0084: `sl7-powermeter --log` for 180 s three times on the previous kernel (or the same kernel with
  a `fdtput`-patched DTB as the plan describes) and three times on 7.2.8-13, alternating, same
  Wi-Fi. Compare SYS. Also check `cat /sys/kernel/debug/interconnect/interconnect_summary | grep -E
  'llcc_mc|ebi|1bd0000'` (peak 7876500 kBps, no `1bd0000.pcie` entry), `dmesg | grep -i pcie` (no
  `1bd0000` probe, no "Device not found" at resume) and that Wi-Fi and NVMe are unaffected.
- 0085: `iw dev wlan0 set power_save on`, then `ping -i 0.2 -c 300 <gateway>` on 7.2.8-12 and
  7.2.8-13 and compare the average and maximum round trip time; then the power A/B with power save
  on against off on 7.2.8-13.

## Iris video codec (7.2.8-13, patch 0086)

`hamoa.dtsi` describes `iris: video-codec@aa00000` (`qcom,x1e80100-iris`, falling back to
`qcom,sm8550-iris`) and leaves it `disabled` because the firmware is signed by the OEM. Patch 0086
enables it in `x1e80100-microsoft-romulus.dtsi` (both the 13.8 and the 15 inch) with
`firmware-name = "qcom/x1e80100/microsoft/Romulus/qcvss8380.mbn"`, the Microsoft signed image from the
SL7 MSI (`omarchy-surface-sl7-firmware` installs it; nothing here ships it). The driver is
`VIDEO_QCOM_IRIS=m` and the clock controller `SM_VIDEOCC_8550=m` (it binds `qcom,x1e80100-videocc`,
which `hamoa.dtsi` enables by default); both were already in `config.sl7`.

Checked statically against v7.2: `video_mem` (`video@87700000`, 7 MiB, `no-map`) is in `hamoa.dtsi`
and romulus does not override it; the node carries its own clocks, GDSCs, OPP table, interconnects
and IOMMU streams. The `firmware-name` property overrides the driver default
(`qcom/vpu/vpu30_p4.mbn`, which the sm8550 data would otherwise request). The patch applies on top
of the queue (checked against a v7.2 tree with 0043, 0064 and 0083 applied). The DTS was not compiled
(no `dtc` here). Not run on the SL7.

Codecs the 7.2 driver advertises for this platform (`iris_platform_vpu3x.c`, `iris_vdec.c`,
`iris_venc.c`, `iris_hfi_gen2_defines.h`): the decoder accepts H.264, HEVC, VP9 and AV1 and outputs
NV12 (plus the Qualcomm tiled `QC08C` and 10 bit `P010`/`QC10C`); the encoder produces H.264 and HEVC
from NV12 (or `QC08C`). There is no VP9 or AV1 encode. Whether the Microsoft firmware image supports
each codec is untested.

## Runtime power, round 2 (7.2.8-15): deferred unused-clock disabling, opt-in

Patches 0087 and 0088 backport Johan Hovold's `1e3e4a97ba7e` ("clk: defer disabling of unused
clocks") and `b3f09e07cfbb` ("pm_domain: defer disabling of unused domains"), both from
`jhovold/linux` (Sep 2024, not in mainline). Each turns the `late_initcall_sync` disabling into a
30 s delayed work, so modular clock and power domain providers and consumers (dispcc, gpucc, msm)
can probe and claim their clocks first. That is the reason Omarchy puts `clk_ignore_unused
pd_ignore_unused` on the Snapdragon command line (`qualcomm-snapdragon.conf` of limine-entry-tool,
not our drop-in).

**Nothing changes on a normal boot.** Our backport is gated: the deferral is active only when
`clk_unused_defer` is on the kernel command line. Without it the disabling still runs in the
late_initcall exactly as before (0087 keeps the old body as `clk_disable_unused_now()` and the
genpd body as `genpd_power_off_unused_now()`), and the existing `clk_ignore_unused` and
`pd_ignore_unused` flags keep working the same way (they are now checked when the work runs).
The flag is parsed once in `drivers/clk/clk.c` (`__setup`, returns 1 so init does not see it) and
shared with `drivers/pmdomain/core.c` through `clk_unused_defer_requested()` (declared in
`include/linux/clk.h`, with a `false` stub for `!COMMON_CLK`), because two `__setup()` handlers
for one string would not both run. The `__init` markers on the clk subtree helpers and on
`clk_ignore_unused` are dropped, as in the originals, since they now run after init.

Use it only through the test entry, which removes both ignore flags and adds the defer flag:

```
sudo omarchy-sl7-test-entry enable clk-unused     # entry "linux-sl7 (CLK-UNUSED test)"
```

Risk (medium): without the deferral the Dell XPS 13 owner saw one boot in five freeze (framebuffer
clocks cut before dispcc/gpucc/msm probed). With the deferral those clocks are claimed within the
30 s window, but this is not proven on the SL7. A frozen or garbled boot is the failure; the
fallback is choosing the normal linux-sl7 entry in the Limine menu (the default entry and
`BOOT_ORDER` never change). `fw_devlink.sync_state=timeout` (already on our cmdline) fires its
sync_state at about the same 30 s, so providers' unused resources are also released then.
Expected gain 10 to 50 mW awake (idle clock trees, two TCSR clkref buffers), more in suspend
[estimate, RUNTIME-PLAN 4.5].

Checked statically only: both patches apply after 0086 on a v7.2.8 tree (apply-series.sh, 81
patches), and `drivers/clk/clk.o` and `drivers/pmdomain/core.o` compile for arm64 with clang
without warnings (the `__setup` strings and the exported symbol are in the objects). Not booted.

Test (battery, backlight pinned, same Wi-Fi), alternating normal and CLK-UNUSED boots, three
`sl7-powermeter --log FILE --seconds 180` runs each after 10 minutes idle, then
`sl7-powermeter --compare`:

- on the test boot: `cat /proc/cmdline` has `clk_unused_defer` and neither ignore flag;
  `dmesg | grep -E 'clk: |genpd: '` shows "Deferring ... by 30 s", then, 30 s later,
  "Disabling unused clocks" and "Disabling unused power domains" (not "Not disabling");
  the display stays up at that moment;
- `/sys/kernel/debug/clk/clk_summary` (root): the enable count of the clocks listed in the plan's
  141-clock set drops to 0 after the 30 s;
- compare SYS and the CPU rails; also `sl7-sleepstats --suspend-test` for the suspend side.
- If the screen freezes or garbles: hold power, choose the normal entry.

## Runtime power, round 3 (7.2.8-16): MDP core clock per layer mixer

Patch 0089. `_dpu_core_perf_calc_clk()` in `dpu_core_perf.c` votes the pixel rate of the whole mode,
`vtotal x hdisplay x vrefresh x 1.05`, as the floor of `disp_cc_mdss_mdp_clk`. On the SL7 eDP
(2304x1536 at 120 Hz, vtotal 1579) that is 458.4 MHz, which rounds to the 514 MHz OPP and holds MMCX
at NOM for as long as the screen is on (bench v2: `mdp_clk_mhz` 514, `mmcx_perf_state` 256 for 100%
of samples). The CRTC runs two layer mixers joined by 3D merge, each handling 1152 pixels per
line, and `dpu_crtc_mode_valid()` already halves the mode clock for 3D merge (`f5d079564c44`); the
performance calculation did not. Per mixer the need is 1579 x 1152 x 120 x 1.05 = 229.2 MHz, which fits
the 325 MHz OPP (MMCX SVS). Research: `Research/omarchy-dragon-sl7/power/AWAKE-CX-MDP.md`, section 3
and fix MD-d.

What the patch changes:

- the mode clock is divided by the number of mixers of the CRTC state (one mixer: unchanged);
- `dpu_plane_split()` also splits a plane that is wider than one mixer of its stage into two pipes,
  like it already did above `max_core_clk_rate`. A full-width plane was fetched by one SSPP feeding
  both mixers and needed the full clock by itself. The split is skipped when two parallel rectangles
  are not possible (scaling, rotation, YUV, wide UBWC, SSPP without smart DMA); that plane keeps one
  pipe and its full clock;
- the plane clocks come from the plane states being checked (`drm_atomic_crtc_state_for_each_plane_state()`),
  not from the value cached at the previous atomic update, and the unused `plane_clk` member is gone.
  Without that, the first commit after a modeset could run on a clock computed without its planes,
  which the old full-width floor used to hide.

`max_core_clk_rate` and its debugfs files are unchanged, so the manual cap still works. External
modes: 4K at 120 Hz needs about 537 MHz per mixer and 5K at 60 Hz about 476 MHz (estimates from
CVT-RB2 timings), both below the 575 MHz limit.

Risk (medium): a full-width pipe on a per-mixer clock underruns. The plane term of the calculation
is meant to prevent it, but this is read from the code, not seen on hardware. Not built, not booted;
the series applies with `apply-series.sh` on 7.2.8 and CI is the compile check. A failure shows as
flicker or torn lines, and `dmesg` reports DPU underruns. Fallback: the previous linux-sl7 entry.

Test on the SL7 (battery, backlight pinned, VRR on, same Wi-Fi):

- after boot and a first Hyprland modeset: `sudo cat /sys/kernel/debug/clk/disp_cc_mdss_mdp_clk/clk_rate`
  is 325000000 (before: 514000000), `sudo cat /sys/kernel/debug/pm_genpd/mmcx/perf_state` is 128;
- `sudo grep -E 'src\[|dst\[' /sys/kernel/debug/dri/0/state` shows the primary plane as two pipes of
  1152 pixels;
- 10 minutes of mouse circling, fast scrolling, window drags and a fullscreen 60 fps video, then
  `sudo dmesg | grep -iE 'underrun|dpu'` and `ls /sys/class/devcoredump/` (both must stay empty);
- an external monitor on each USB-C port, at its largest mode (4K120 or 5K60 if it has them): it must
  light up and stay clean, `dmesg` without underruns;
- bench v2, 30 min: `mdp_clk_mhz` 325 and `mmcx_perf_state` 128 for 100% of samples, battery W lower
  than the 2.95 W run by more than the run-to-run spread.

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

## Camera (Phase A of IR face unlock)

Phase A proves that the cameras probe and stream, and nothing else. The infrared illuminator
(PM8550 flash, 700 mA) is **not** described: `&pm8550_flash` stays disabled, there is no `leds`
link and no `st,leds`, and patch 0041 stops the vd55g driver from defaulting a sensor GPIO to a
strobe output. Do not enable the emitter until its flash channel has been found (Phase B).

- Firmware: the VD55G0 needs `vd55g0-cut1.bin` or `vd55g0-cut2.bin`, installed by this package
  under `/usr/lib/firmware` (petm5/vd55g-firmware at e519457, GPL-2.0 STMicroelectronics patch
  arrays, licence text in `LICENSE.vd55g-firmware`). No Microsoft file is involved.
- Rails: IR vcore LDO2_M 1.2 V, vio LDO4_M 1.8 V, vana LDO6_M 1.8 V, all pinned (min = max).
  vana must never be raised to ST's 2.8 V.
- The master clock is unknown. The IR node starts with MCLK0 (gpio96) at 19.2 MHz.
  The `vd55g` module parameters `mclk_index` (0 to 3 for MCLK0..3 on gpio96..99, -2 for no
  clock, default -1 = device tree) and `mclk_hz` are read at probe, so the probe procedure tries
  every candidate without rebuilding or rebooting: `sudo sl7-ir-probe --sweep-mclk`
  (package omarchy-surface-sl7). Chosen over four extra DTBs because Limine's `efi` protocol has
  no `dtb_path` (only the `linux` protocol does, and then initramfs and command line must be
  supplied by hand), and a UKI cannot select between DTBs by command line (`.dtbauto` is chosen
  by SMBIOS HWIDs). It changes no persistent state: a reboot returns to the device tree.
- 7.2.8-4: the vd55g mono pad format defaulted to code 0 (`fmt:unknown/644x604` in `media-ctl -p`)
  because the generic driver returned the requested code unchanged for mono sensors. Patch 0040
  now validates the code against the mono list and falls back to the first entry (Y8_1X8), the
  Bayer lookup falls back to row 0, and `init_state` picks the first mono or Bayer code (as
  `vd55g1` did). `set_fmt` and `enum_frame_size` go through the same check. Patch 0031 also logs
  `csiphy %d init fail` with `dev_err_probe()` so a deferred probe is not printed as an error.
- 7.2.8-7: the IR sensor probes and loads firmware patch 2.11, but `vd55g_enable_streams()` failed
  with a hard-coded `-EINVAL` that hid the cause. Patch 0040 now returns the real error, logs
  `enable streams: <step> failed: <ret>` for each step, logs register, expected value, last value and
  system FSM state when a poll times out, and logs the computed clock tree (`clock tree: ...`, at
  `dev_info`) at every stream start. `s_ctrl` failures are logged with the control name. Patch 0042:
  `mclk_hz` now defaults to 0 (keep the DT rate) and, with `mclk_index` -1, sets the DT clock to
  that rate; with `mclk_index` >= 0 or -2 a zero still means 19.2 MHz. `sl7-ir-probe --mclk-hz N`
  uses this. Patch 0067 (new) stops the VFE, CSID and CSIPHY that `video_start_streaming()` had
  already started when the sensor fails, which removes the `call_s_stream` WARN libcamera's `cam`
  hit after a failed start.
- 7.2.8-8: the first IR capture after boot worked (30 frames, Y8 644x604) and every later start
  failed with `apply_cold_start failed: -65528`. `vd55g_apply_cold_start()` declared `int ret;`
  without initialising it and passes it to the `cci_write` accumulators, which skip the write and
  return when `*err` is non-zero, so stack garbage both skipped the cold-start exposure writes and
  became the return value. Patch 0040 initialises it to 0.
- First on-device steps: `sudo sl7-ir-probe`, read its `SUMMARY`, then `--sweep-mclk` only if the
  IR sensor did not bind.

### v4l2loopback (7.2.8-10)

`linux-sl7` also ships `v4l2loopback` 0.15.4 (GPL-2.0-or-later, pinned release tarball with a sha256),
for the `sl7-ir-bridge` package. It is not in mainline, so `build()` builds it out of tree against the
tree that was just built (`make M=... modules`) and `package()` installs it as
`/usr/lib/modules/<ver>/extra/v4l2loopback.ko`. No headers package and no DKMS are involved, so the
vermagic always matches the kernel. It adds no module options: `sl7-ir-bridge` ships the modprobe
options. 0.15.4 compiles clean against 7.2 (arm64, clang). Do not install ALARM's `v4l2loopback-dkms`
next to it.

### IR emitter bring-up, stage A (7.2.8-11)

**Patches 0080 and 0081.** SL7-local, not for upstream.

- **0080** adds a safety layer to leds-qcom-flash for LED nodes with `color = <LED_COLOR_ID_IR>`:
  torch refused (the hardware timer does not run in torch mode); hard clamps in code (flash at most
  700 mA, timeout at most 100 ms, torch 5 mA per channel); the safety timer is never disabled; no
  v4l2-flash sub-device; all channels off on remove and shutdown; a read-only register snapshot
  logged at probe and at remove; and a bind gate (module parameter `ir_test=1`, set only by the
  omarchy-surface-sl7 modprobe rule on the "linux-sl7 (IR test)" boot entry). It also fixes the
  v4l2-flash release loops in `remove()`, which read one past the end.
- **0081** adds four IR discovery LEDs under `&pm8550_flash` on romulus13 (`ir:flash-1` to
  `ir:flash-4`, 12.5 mA, 10 ms, torch 5 mA). They sit in every DTB but bind only on the IR test
  boot. Nothing refers to them; the camera node has no `leds` link and patch 0041 is unchanged.

**IR stage A safety fix (7.2.8-14, patch 0080).** The CHAN_TIMER field very likely counts
(n + 1) x 10 ms (the driver's own 1280 ms ceiling does not fit n x 10 ms in 7 bits, and the reset
value 0x13 is a round 200 ms only as 19 + 1), while the stock driver writes n = timeout / 10. For IR
LEDs 0080 now writes n = timeout / 10 - 1 (at least 0 = 10 ms), so a requested 10 ms is 10 ms and
the 100 ms clamp is a real 100 ms, not about 110 ms. If the field is really n x 10 ms the pulse is
shorter, never longer. Other LEDs keep the stock encoding (the off-by-one is an upstream question
once measured). The probe and remove register snapshots now name every register (4ch: CHAN_TIMER
0x3e-0x41, ITARGET 0x42-0x45, CHAN_STROBE 0x4a-0x4d). Checked as an aarch64 object compile only
(clang, never run).

Nothing fires the emitter. Requires omarchy-surface-sl7 22 or later for the load gate. Plan:
`Research/omarchy-dragon-sl7/ir/EMITTER-PLAN.md`.

### IR emitter bring-up, stage B (7.2.8-19)

**Patches 0091 and 0092.** SL7-local, not for upstream. The 12.5 mA single-channel discovery test
(stage A, 0081) showed nothing on a phone camera. The Windows driver qcpmic8380.sys drives its
"LED1" as flash channels 1 and 4 ganged (350 mA per channel), so 0092 replaces the four discovery
LEDs by one node, `ir:flash-14` (`led-sources = <1>, <4>`; the driver splits the current equally).
The discovery LEDs are retired because they overlapped the ganged node (two owners of channels 1 and
4). 0091 adds the limit:

- Module parameter `ir_max_ua`, the flash current limit per channel in uA, default 25000. An IR
  LED's limit is `ir_max_ua` times its channels (50 mA total for the ganged LED by default).
- Hard cap 100000 uA per channel in the driver, whatever the parameter, the DT or user space say:
  `flash-max-microamp` is clamped to it at probe, the parameter setter refuses values above it or
  below 12500 (the hardware step) with -EINVAL, the use site clamps again. The parameter is writable
  at run time (mode 0644) so `sl7-ir-emitter-test` can step 12.5 / 25 / 50 / 100 mA per channel
  without a reboot; a flash_brightness write above the limit fails with -EINVAL (and a warning in
  the log) instead of being clamped silently.
- Unchanged from 0080: torch refused, safety timer never disabled (n = timeout / 10 - 1), code
  ceiling 100 ms, DT timeout 10 ms, bind gate `ir_test=1`, 700 mA total ceiling. Pulse charge at
  the hard cap: 2 x 100 mA x 10 ms = 2 mC.

Checked as `git apply --check` against the series on v7.2 only; CI compiles the driver and runs
dtbs_check. Never run. Needs omarchy-surface-sl7 36 or later for the test tool.

**Patch 0093 (7.2.8-20).** Stage B at 12.5, 25 and 50 mA per channel showed nothing, and nothing
logged proved the channels ever ran: the sysfs read-backs are software state and the earlier
snapshots were taken before or after a pulse. For an IR LED with `ir_test=1`, the strobe path now
reads STATUS1-3, 0x0C-0x0F, INT_RT_STS, INT_LATCHED_STS, CHAN_TIMER, ITARGET, MODULE_EN,
IRESOLUTION, CHAN_STROBE, CHAN_EN and 0x50-0x53 at five moments (idle, right after arming,
+3 ms, +15 ms after the 10 ms hardware timer, after strobe off) and logs them afterwards, so
printk does not skew the timing. Read-only; `flash_strobe=1` returns about 15 ms later, the pulse
itself is still bounded by the hardware timer.

### IR emitter bring-up, stage C (7.2.8-21)

**Patches 0094 to 0097.** SL7-local, not for upstream. A software strobe of the ganged LED gave
STATUS1 `0x82` (CH1 and CH4 open circuit), INT_RT_STS `0x49` (fault and ramp-down, ramp-up never) and
no current. Hypothesis H2: sensor GPIO 1 (strobe output; Windows writes `0x0468 = 0x02`) enables the
emitter path, and Windows arms the PMIC for a hardware strobe (`CHAN_STROBE = 0x05`).

- **0094 / 0097.** The romulus13 camera node gets `st,leds = <1>`, but vd55g ignores it (one log
  line) unless its read-only module parameter `illuminator` is 1, which only the omarchy-surface-sl7
  39 modprobe rule sets, and only when `sl7.ir_test=1` is on the command line. Without it the driver
  is as before: every sensor GPIO an input, no `led_mode` control. The GPIO configuration latches
  when the stream starts (`vd55g_update_gpios()` in `vd55g_enable_streams()`), so `led_mode` has to
  be set **before** stream-on; the test tool does that. `ir:flash-23` (channels 2 and 3) has the
  same limits and gates as `ir:flash-14`. There is still no `leds` link and no `led-names`: the
  driver never drives the PMIC.
- **0096.** `hw_strobe_arm` (write 1 or 0, read 0 or 1) on the IR LEDs, in this order:
  `led_sysfs_disable()`, strobe off, current budget (the flash current against `ir_max_ua` times
  the channels and against 25000 uA per channel for this mode, enforced in the driver whatever
  `ir_max_ua` is raised to), ITARGET, CHAN_TIMER 10 ms with the timer enabled, MODULE_EN,
  CHAN_STROBE 0x05 on both channels, CHAN_EN. A delayed work that disarms is queued before
  CHAN_EN; it fires 1000 ms after the arm at the latest. Disarm (CHAN_EN first) also runs from a
  write of 0, `flash_strobe=0`, remove, shutdown and suspend. While armed the software strobe,
  `flash_brightness` and `flash_timeout` refuse (-EBUSY). `qcom_flash_external_strobe_set()` is
  not used; torch stays refused. After the arm the driver polls STATUS1, STATUS2, STATUS3,
  INT_RT_STS and CHAN_EN back to back for 30 ms and logs the changes, the union of the values
  and the monotonic times of the arm and the disarm ("SL7 IR HW-strobe poll", "SL7 IR hardware
  strobe ARMED / DISARMED").
- **0095.** Snapshots now also read 0x4f, 0x55, 0x67 and 0x68; the t0 and +1 ms moments read only
  the key registers so the +1 ms read lands on time; STATUS3 is read on its own at +15 ms; waits
  aim at absolute times after t0; each line carries its start offset and the monotonic time
  (`t_mono`, the clock of V4L2 frame timestamps).

Tool: omarchy-surface-sl7 39, `sl7-ir-emitter-test --stage c0a|c0b|c1-sw|c1-hw|t0b` and the Stage C
section of `sl7-ir-lab` (see that README, section 11c). Checked as `git apply --check` against the
series on v7.2 only; CI compiles the driver (now in `fast-check.sh`) and runs dtbs_check. Never run.

### IR emitter, stage C result (7.2.8-22)

**Patch 0098.** Stage C found the emitter: **sensor GPIO 1 drives it.** With `led_mode` = flash and
the PMIC not armed (stage C0b) the frames got brighter: at exposure 100 lines the mean went from
15.7 to 20.1 and p99 from 16 to 38; at exposure 6268 lines the mean was 81.9 with p99 255. The PMIC
flash channels are not in the path, so their current caps and timers do not apply, and nothing in
the PMIC limits how long or how often the emitter is lit.

**Safety rule.** The strobe is high for the whole exposure, so the only safety control is the
strobe duration (the exposure) and its repetition (the frame length). Whenever `led_mode` is not
off, the vd55g driver holds both to what Windows Hello programs, whatever user space asks for:

| | Windows | Source |
|---|---|---|
| exposure | 100 lines (`0x044e` = 100, manual exposure `0x044c` = 2), 1.587 ms | regSetting 37 of `com.surface.sensormodule.aux_vd55g0_MSHW0472.bin` (EMITTER-PLAN E7) |
| frame length | 1750 lines (`0x0458/9` = 214, 6), 27.78 ms, 36 fps | same |
| line length | 1200 px (`0x0300/1` = 176, 4) at 75.6 MHz | same, pixel clock from E11 |
| strobe duty | 100 / 1750 = 5.71 % | derived |

- The limits are scaled by the real pixel clock and line length, so a slower clock or a longer
  line can only tighten them. The tighter of these and the 0040 flash-mode cap (half a frame) wins.
- Enforced when the exposure or vblank control is set (ranges and the values written), when
  `led_mode` changes (registers first, GPIO strobe second) and at stream start after every control
  has been applied and before the stream starts. Failing to write them fails the stream start.
- Auto exposure is replaced by manual exposure while the strobe is on, as in Windows' init. Gains
  are the controls' values, whose defaults are the sensor's power-on values (Windows' init writes
  no gain register; its runtime gain is not decoded).
- The effective timing is logged ("IR strobe timing: ...") at stream start and on every
  `led_mode` change.
- `illuminator` now defaults to 1, so `led_mode` exists on a normal boot. `vd55g.illuminator=0`
  removes the strobe and the control entirely. `led_mode` still defaults to off; user space
  (sl7-ir-bridge) turns it on for a session.

Checked as `patch --dry-run` against the series on v7.2 only; CI compiles the driver. Never run.

### Front camera at 18.8 fps: the OV02C10 runs from 12 MHz (7.2.8-23)

**Patches 0099 and 0100.** Symptom: with the stock driver the front camera ran at 18.8 fps. Setting
`vertical_blanking` = 370 (frame length 1462 lines) mid-stream gave 29 to 30 fps. The driver timings
assume a 19.2 MHz reference; 30 fps * 12 / 19.2 = 18.75 fps, so the sensor's reference is 12 MHz.
This matches the linux-media report by Ryan Thomas Cragun (2026-07-02) that the Surface Laptop 7
drives the OV02C10 from a fixed 12 MHz clock, and Sakari Ailus' answer that the driver should
support 12 MHz and compute the pixel rate from the external clock.

- **Cause.** The same register settings from a 12 MHz reference give a 250 MHz link (500 Mb/s per
  lane) instead of 400 MHz; line time stays 2280 sensor clocks = 22.8 us, pixel rate 100 MHz for two
  lanes. The default frame length (minimum 1164 times 2 lanes = 2328) is 30 fps only at 400 MHz.
- **0099.** Accepts a 12 MHz clock, adds the 250 MHz link frequency and requires 19.2 MHz with
  400 MHz or 12 MHz with 250 MHz. The pixel rate control follows the link frequency by itself. The
  default frame length is scaled by link frequency / 400 MHz (1455 lines at 250 MHz, about 30.1 fps).
  The 19.2 MHz behaviour is unchanged. No new register values.
- **0100.** The module most likely carries its own oscillator: the Windows camera resources for
  MSHW0470 list no MCLK, and CAMCC cannot generate 12 MHz. The sensor's `clocks` is now a 12 MHz
  `fixed-clock` node; the CAMCC MCLK4 reference and `assigned-clock-rates` are gone and the gpio100
  pinctrl state is kept (it only muxes the pin). `link-frequencies` is 250 MHz.
- **CAMSS.** It reads the sensor's link frequency control (`v4l2_get_link_freq`) for the CSIPHY
  settle count, so it now sees the real 250 MHz (500 Mb/s) rate instead of 400 MHz.
- **Check after boot.** Front camera about 30 fps; `v4l2-ctl -d <ov02c10 subdev> -C
  pixel_rate,link_frequency,vertical_blanking` should read 100000000, 250000000 (menu index 1) and
  363; the image is correct; no CSIPHY errors in `dmesg`.

Checked as `git apply --check` against the series on v7.2 only; CI compiles the driver and runs
dtbs_check. Never run.

## USB-C reverse plug (7.2.8-18): fixed PHY orientation, on by default

Patch 0090. On the SL7 USB3 SuperSpeed fails to train whenever the plug is reverse, on both USB-C
ports (Polling to Inactive warm-reset loop, no high speed fallback); normal orientation works.
Flipping only the retimer bit (REG0 0x21 with the QMP PHY reversed) fails too, and 0070 is cleared:
the failure follows orientation, not the XO change. The Microsoft firmware on the PS8830 retimer
performs the flip itself, so the QMP combo PHY must stay normal.

`ps883x.fixed_phy_orientation` (default true) makes `ps883x_sw_set()` forward
TYPEC_ORIENTATION_NORMAL to the QMP PHY whenever the orientation is not NONE; the retimer's own
state and the REG0 bit still follow the plug. Evidence: confirmed on the SL7 (7.2.8-17 test entry)
on both USB-C ports in both orientations, with reverse SuperSpeed, DisplayPort alt mode and a dock
all working. 7.2.8-17 had it off by default, behind the `usbc-flip` test entry; 7.2.8-18 turns it on.

To disable it (plug-following PHY, USB3 will not train on a reverse plug): add
`ps883x.fixed_phy_orientation=0` to the kernel command line (the cmdline in
`/etc/limine-entry-tool.d/omarchy-surface-sl7.conf`, then `sudo limine-mkinitcpio`). The parameter is
read-only (0444) at runtime.

## Not in v0

The IR illuminator, libcamera tuning for the RGB camera, USB4 host router, fused-core handling for X1P-64-100,
Iris DT enablement, DP audio, the EC reboot helper. See the project PLAN.md.

## Licensing

- Scripts, workflow and packaging glue in this directory are MIT, as in the
  repository LICENSE. The PKGBUILD derives from the Arch Linux ARM
  `linux-aarch64` PKGBUILD.
- Everything under `patches/` is GPL-2.0 (GPL-2.0-only, like the Linux kernel
  it modifies) and keeps its original authors and sign-offs.
- `config.alarm` is the Arch Linux ARM kernel configuration.
- No Microsoft or Qualcomm firmware is built, committed or distributed here.
