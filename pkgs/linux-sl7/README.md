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
| 0024 | EXPERIMENTAL: eDP variable refresh (DPU INTF AVR, MSA ignore, `vrr_capable`) behind `msm.vrr_enabled=1` (default 0; see `omarchy-sl7-test-entry`) | scuggo/x1e-nixos `msm-vrr-avr.patch` (ca7db70), rebased and gated by us | will not go upstream as is |
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

When 7.3 is tagged, drop 0045-0052, 0061 and 0068-0069, and also 0053-0058, 0059, 0062-0065
only if they are in the tag (check with `git merge-base --is-ancestor`; they are
7.4-queued). Re-run `scripts/fast-check.sh`.

Diagnostic: `sl7-sleepstats` (pkgs/omarchy-surface-sl7, not in the PKGBUILD yet)
prints the qcom_stats counters, `power-domain-system` residency (S0 is
`domain_ss3`) and cpuidle totals; `--suspend-test` runs a measured suspend.

## Power: suspend holders (7.2.8-9)

Added in 7.2.8-9 (patches 0068-0071) from the 7.2.8-7 `sl7-sleepstats --trace` capture of 2026-10-05 (8 min
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
