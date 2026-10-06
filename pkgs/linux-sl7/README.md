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
| 0072 | PCI: allow D3 for native hotplug-capable Root Ports on non-x86 | torvalds `d4c79b63d82d` (Manivannan Sadhasivam, v7.3-rc1) | merged for 7.3 (backport) |
| 0082 | hwmon: `qcom_pld_power`, read-only firmware power telemetry (CPU clusters, GPU, system, USB) | ItsLucas, `drivers/qcom-pld-power/` at `1cc387f` (GPL-2.0-only), author kept, only build glue changed | not submitted; author says it needs a reviewed binding and more firmware evidence |
| 0083 | romulus (13.8 and 15 inch): `pld-power@81f30000` node for 0082 | ours; resource from ItsLucas's `sl7_pld_device` | not submitted |
| 0084 | SL7 local: romulus13 disables `&pcie3` and `&pcie3_phy` (the 15 inch card reader slot, empty on the 13.8 inch) | ours; RUNTIME-PLAN C1 | not submitted (candidate: romulus13 fix) |
| 0085 | ath12k: DTIM stick mode for station vdevs (the STA follows the AP DTIM instead of listen interval 5) | torvalds `af50baccaa5f` (Daizhuang Bai, v7.3-rc1) | merged for 7.3 (backport) |
| 0086 | SL7 local: romulus (13.8 and 15 inch) enables `&iris` with the Microsoft signed `qcom/x1e80100/microsoft/Romulus/qcvss8380.mbn` (V4L2 stateful decoder and encoder) | ours; firmware from the SL7 MSI via `omarchy-surface-sl7-firmware` | not submitted (needs signed firmware in linux-firmware) |

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

Nothing fires the emitter. Requires omarchy-surface-sl7 22 or later for the load gate. Plan:
`Research/omarchy-dragon-sl7/ir/EMITTER-PLAN.md`.

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
