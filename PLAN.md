# omarchy-dragon-sl7 — Project Plan

Omarchy (Arch Linux ARM + Hyprland) on the Microsoft Surface Laptop 7.

- **Primary target:** SL7 13.8" (model 2036, codename romulus13), Snapdragon X Plus **X1P-64-100** (10-core, binned X1E80100 "Hamoa" die), Adreno X1-85, 16 GB RAM, ~256 GB NVMe.
- **Secondary (where cheap):** SL7 13.8"/15" with X1E-80-100 (romulus13/romulus15). The same DT family and the same firmware MSI cover both.
- **Status date:** 2026-10-03 (research redo + device capture). Mainline is 7.3-rc5 (7.3 final ≈ Oct 18); ALARM `linux-aarch64` is 7.2.8-1.

## Research

Full evidence lives outside this repo (never committed; contains Microsoft-licensed files):

| Topic | Path (under `/mnt/Rocket4/Quadrant/Personal/Research/omarchy-dragon-sl7/`) |
|---|---|
| Omarchy, dragon branches, forks, discussions | `omarchy/REPORT.md` |
| DT, boot chain, firmware paths, ALARM config, patch inventory | `platform/REPORT.md`, `platform/SOURCES.md` |
| Per-feature status and actions | `features/REPORT.md`, `features/notes/*.md` |
| Windows vs Linux power, ranked plan, design notes | `power/REPORT.md`, `power/ideas/*.md` |
| IR camera decode, draft DT, test plan | `ir/REPORT.md`, `ir/METHOD.md`, `ir/decoded/` |
| USB4 status and series tracker | `usb4/REPORT.md`, `usb4/TRACKER.md` |
| Microsoft SL7 MSI, extraction, firmware index | `msi/FIRMWARE-INDEX.md`, `msi/README.md` (local only) |
| Chris's device capture (Windows) | `device/sl7-capture/` (local only; contains MACs) |
| Clones | `repos/` |

## Device facts (Chris's unit, captured 2026-10-03)

| Item | Value |
|---|---|
| SKU | `Surface_Laptop_7th_Edition_2036` (consumer, not For_Business, so SKU-based romulus13 CHIDs apply) |
| UEFI | 175.235.235 (2026-04-01); the same version ItsLucas validated `qcom_pld_power` on (15") |
| CPU | Snapdragon X1P64100, 10 cores |
| IR camera | `ACPI\VEN_SMO&DEV_55F0&SUBSYS_MSHW0472` (VD55G0) — confirmed |
| Touchscreen | **`MSHW0460` = SPI "GTCH"**, not the I2C `MSHW0468`. ACPI SSDT: touch board ID (TBID) 2/3 → I2C `ITCH` (MSHW0468 on I2C9); otherwise SPI `GTCH` on SP11. Exposes a "Touch Pen Processor" collection: pen worth testing |
| Touchpad | `MSHW0238` (HID 045E:0C77 on QSPI) |
| Also present | USB4 host router `QCOM0C6D`; "CPU Core parking Policy" device (Windows parks cores) |
| BitLocker | on (used space only); recovery key saved |
| Saved | driver export (300 packages), `sleepstudy.html`, `battery-report.html`, display EDID (`display.reg`), Wi-Fi MAC |

---

## 1. Goal and principles

**Goal:** a bootable ISO that installs a daily-drivable Omarchy on the SL7, and keeps receiving updates from upstream Omarchy.

**Principles**

1. **Track upstream, don't fork.** Base on `omacom/omarchy@dragon` and `omacom/omarchy-iso@dragon`, and follow them as `dragon` converges into `quattro`. Our repo is a thin overlay: pinned upstream refs, a device entry, our packages, and a build wrapper.
2. **Device support ships as packages**, following the `omarchy-mac` model: add-on packages that depend on `omarchy`, with `groups=('omarchy-platform-qualcomm')`. Nothing is patched in place in upstream trees if a package, hook or drop-in can do it.
3. **Never ship Microsoft/Qualcomm OEM firmware in the ISO or a public repo.** Fetch it on the target, either from the public SL7 MSI or from the Windows DriverStore.
4. **Upstream every generic fix:** x86 guards to Omarchy, the SAM kernel config to ALARM, kernel fixes to LKML, shim fixes to omarchy-pkgs. The overlay should shrink over time.
5. **Safety first on audio.** No config we ship may raise the WSA speaker limits or expose the PipeWire "Pro Audio" profile.
6. **Measure, don't guess**, on power. Every power tweak lands with before/after watts.

**Closest template:** `denislopt/omarchy-surface-laptop7` (published 2026-09-16, SL7 15" only): dragon-based, stock ALARM kernel + out-of-tree modules (SAM keyboard, touchpad, touchscreen, Wi-Fi), firmware package, pre-unlock display hook, `fix-surface-keyboard.sh` bypass, kernel-upgrade review hook. We follow its overlay shape but still build our own `linux-sl7` (distinct pkgname, `provides`/`conflicts` `linux-aarch64`): the X1P SCMI fix lives in built-in code (`ARM_SCMI_PERF_DOMAIN=y`) and Iris needs `SM_VIDEOCC_8550`, neither of which a module package can carry. Its scripts hard-check `microsoft,romulus15` and need adapting to romulus13.

---

## 2. Architecture

### 2.1 Repo layout

```
omarchy-dragon-sl7/
├── PLAN.md
├── upstream.lock              # pinned SHAs: omarchy@dragon, omarchy-iso@dragon, omarchy-pkgs
├── upstream/                  # git submodules (or fetched by build script at locked SHAs)
│   ├── omarchy/
│   ├── omarchy-iso/
│   └── omarchy-pkgs/
├── iso/
│   ├── platforms.d/surface-laptop-7.json   # merged into configs/aarch64/platforms.json at build
│   └── build.sh               # wrapper around omarchy-iso-make --arch aarch64 ...
├── pkgs/
│   ├── linux-sl7/             # ALARM linux-aarch64 PKGBUILD + config.sl7 + patches/
│   ├── omarchy-surface-sl7/   # add-on: hooks, drop-ins, board script, safety policy
│   ├── sl7-firmware/          # fetcher/extractor (no blobs!): MSI + DriverStore → /usr/lib/firmware/updates
│   ├── iptsd-sl7/             # alex-lentz/iptsd fork, built with -mbranch-protection=standard
│   ├── ath12k-board-sl7/      # board-2.bin remap hook (pacman hook on linux-firmware-qcom)
│   ├── sl7-mac-fixup/         # valeronm/sl7-mac (or sp11-mac-fixup port) as a systemd unit
│   ├── qcom-firmware-extract/ # vendored from omarchy-pkgs #221 until merged (the dragon ISO build check requires it)
│   ├── linux-aarch64-pkgbase-shim/  # #222; maybe obsolete (limine-mkinitcpio-hook ≥1.38 finds ALARM's kernel); only for the stock rescue kernel
│   ├── x1e-sleepdoctor/       # Phase 4: names what blocks SoC power collapse (qcom_stats, icc, clk, genpd)
│   ├── sl7-powerd/            # Phase 4: AC/battery switcher + cgroup cluster-parking daemon
│   └── sl7-ir/                # Phase 5: vd55g firmware, IR bridge (Y10P→GREY v4l2loopback), udev, PAM glue
│   # later: hexagonrpcd, libcdsprpc (fastrpc), libcamera OV02C10 helper/tuning, fex-emu, visage/howdy-next (aarch64)
├── tools/                     # recon.sh (Phase 0.5 read-only hardware report), power harness
├── repo/                      # generated local pacman repo (gitignored), served via --local-repo
├── docs/                      # hardware notes, measurements, test logs
└── .github/workflows/         # arm64 package + ISO builds
```

### 2.2 Device entry (`platforms.json`)

| Field | Value |
|---|---|
| match | `sys_vendor = Microsoft Corporation`, `product_name = Microsoft Surface Laptop, 7th Edition` (optionally `product_sku = Surface_Laptop_7th_Edition_2036/2037`) |
| packages | `linux-sl7 linux-sl7-headers omarchy-surface-sl7 sl7-firmware iptsd-sl7 ath12k-board-sl7 sl7-mac-fixup` |
| kernel args | `cpufreq.default_governor=schedutil fw_devlink.sync_state=timeout console=tty0`; consider `plymouth.enable=0 rd.plymouth=0` until the LUKS prompt is proven visible; keep `clk_ignore_unused pd_ignore_unused` (§4) |

The `platforms.json` schema matches only `{sys_vendor, product_name}`, not SKU; 13.8"/15" divergence (I2C vs SPI touch, TBID) is handled at runtime by the add-on, not by the ISO match.

### 2.3 Boot chain

```
Surface UEFI (Secure Boot OFF)
  └─ Limine (EFI, also copied to \EFI\BOOT\BOOTAA64.EFI as fallback)
       └─ UKI built by ukify (mkinitcpio + limine-mkinitcpio-hook)
            ├─ .linux    linux-sl7 Image (package ships vmlinuz/pkgbase itself; no shim needed)
            ├─ .initrd   incl. SAM keyboard + msm display modules + zap/gen70500 fw
            ├─ .dtbauto  x1e80100-microsoft-romulus13.dtb, romulus15.dtb (NOT -el2)
            └─ .hwids    systemd ≥260 hwids/aa64 (romulus13.json / romulus15.json)
                 → systemd-stub matches SMBIOS CHIDs → installs the right DTB → kernel
```

- Omarchy's `install/hardware/qualcomm/dtb-uki.sh` writes `DeviceTreeAuto=` in `/etc/kernel/uki.conf`. Our add-on restricts it to romulus13/15 to keep the UKI small. `linux-sl7` installs DTBs to `/boot/dtbs/qcom` (the glob dtb-uki.sh reads).
- **`ENABLE_UKI=yes` is mandatory.** Omarchy ships `ENABLE_UKI=no` in some paths; the next kernel update then writes a bare `protocol: linux` entry with no DTB and the machine resets at boot (Dell 7441, #12441). The add-on sets it in `/etc/default/limine` and `sl7-doctor` asserts it. Re-add the quiet-boot flags in a `limine-entry-tool.d` drop-in (they drop on rebuild).
- romulus13 and romulus15 share 5 generic CHIDs; Chris's consumer SKU 2036 matches the SKU-based romulus13 CHIDs. The 3 BIOS-tied CHIDs reference 144.18.235 and are stale on his 175.235.235 (harmless).
- Snapper and limine-snapper-sync are unchanged.
- The live ISO keeps upstream's GRUB (gfxterm) → live UKI with ~32 `.dtbauto` sections.
- The live ISO uses `modprobe.blacklist=qcom_q6v5_pas`. Starting the ADSP resets USB-C and drops the boot stick.
- EL2/KVM (slbounce, qebspil, dtbloader) needs systemd-boot or firmware DriverOrder. **Out of scope for v1.**

### 2.4 Install flow

1. Boot the live ISO. Expect a black screen for up to ~2–3 min while msm and firmware settle.
2. The ISO matches the SL7 `platforms.json` entry.
3. **Firmware staging, before partitioning:**
   - (a) Default: fetch the public MSI (Microsoft download id 106120) or read a user-supplied MSI/backup dir, then run `msiextract`.
   - (b) Optional: if a readable Windows partition exists (BitLocker decrypted), the DriverStore extract may pick up newer Windows Update firmware.
   - (c) Install into `/usr/lib/firmware/updates/qcom/x1e80100/microsoft/…`, honouring the `Romulus/` subdirectory.
4. Partitioning: LUKS2 + btrfs, the upstream defaults. Keep other Limine entries for dual boot (omarchy-iso #192).
5. Pacstrap: omarchy base/other packages from ALARM plus `[omarchy]` edge plus our local repo. The x86-only package list is filtered.
6. **Platform package transaction:** install the SL7 packages *before* `omarchy-apply-system` → `omarchy-apply-hardware`. This is the order #13362 defines, so our hooks and drop-ins are present when hardware leaves run.
7. `omarchy-apply-system` / `omarchy-provision-user --first-install`.
8. mkinitcpio → UKI, then Limine entry plus a **fallback entry** (§3.5).
9. First boot, then the post-install verify script (`sl7-doctor`, shipped in the add-on): DT compatible, firmware present, battery, Wi-Fi, speaker limits.

### 2.5 Firmware set (`sl7-firmware`)

| File | Path under `/usr/lib/firmware/updates/qcom/x1e80100/microsoft/` | Needed for |
|---|---|---|
| `qcdxkmsuc8380.mbn` | `./` — **not** `Romulus/` (also into the initramfs) | GPU zap; without it a black screen, `gpu hw init failed: -2` |
| `qcadsp8380.mbn`, `adsp_dtbs.elf` | `Romulus/` | audio, battery, sensors |
| `qccdsp8380.mbn`, `cdsp_dtbs.elf` | `Romulus/` | NPU/compute |
| `adspr.jsn adsps.jsn adspua.jsn cdspr.jsn battmgr.jsn` | `Romulus/` (harmless) | **likely unnecessary**: in-kernel `QCOM_PD_MAPPER` has an `x1e80100_domains` table. Install anyway; verify battery works without them on device |
| `qcvss8380.mbn` | `Romulus/` (per ItsLucas 0019 `firmware-name`) | Iris HW video decode (Phase 5) |
| sensor registry (82 ADSP sensor files; `DriverData\Qualcomm\fastRPC\persist\sensors`) | `/var/lib/hexagonrpcd/…` | ALS auto-brightness (Phase 5) |
| USB4 router MCU firmware, embedded in `QcUsb4Filter8380.sys` (0x9f70-byte stream at offset 0x4b9c0) | TBD by the host-router driver when posted | USB4 (future). **Present in the public MSI** (`qcusb4filter8380/`); not redistributable |
| `vd55g0-cut1.bin` / `cut2.bin` (ST sensor patch) | per vd55g driver | IR camera (Phase 5). GPL, from petm5/vd55g-firmware; this one **may** ship in our repo |
| `X1E80100-Romulus-tplg.bin` | `qcom/x1e80100/` | audio topology — **already in linux-firmware** (ALARM `linux-firmware-qcom` 20260916); nothing to fetch |

**Source:** `SurfaceLaptop7_ARM_Win11_26100_26.053.36539.0.msi` (published 2026-06-25, 523,874,304 bytes, sha256 `66b6e1ace7e5f01bc592cd4c9ae78aa30bbb0e04ab57491cd03ec2aaa6e1229b`). It extracts in one step with `pymsi extract` (python-msi); `msiextract` (msitools, in ALARM) is the on-target path. Index of every needed file with hashes: `msi/FIRMWARE-INDEX.md` in the research folder.

**Rules**

- Store the files **uncompressed or `.xz`**: ALARM's kernel has `FW_LOADER_COMPRESS_ZSTD` off.
- **Both public extractors get the paths wrong.** Debian `qcom-firmware-extract` v21 puts everything (zap included) in `Romulus/`, matches 13.8" only, skips `qcvss8380` and needs dislocker. bryce-hoehn's script flattens everything to `microsoft/` (DSPs miss `Romulus/`) and its MSI URL is 404. ELLX's tarball has both trees right. Our `sl7-firmware` writes zap → `microsoft/`, DSP/Iris → `microsoft/Romulus/`.
- The Windows DriverStore backup is now **optional** (everything we need is in the MSI); Chris's 300-package driver export is kept as insurance against newer Windows Update firmware.
- Record SHA-256s in `/var/lib/sl7-firmware/manifest`.

---

## 3. `linux-sl7` kernel

### 3.1 Base

- ALARM `core/linux-aarch64` PKGBUILD and config (7.2.8 today), with its own pkgbase `linux-sl7` (`provides`/`conflicts` `linux-aarch64`) so ALARM updates can never overwrite it. The Dell 7441 owner's same-named custom kernel was overwritten by ALARM 7.2.7-2.
- Ship `vmlinuz` + `pkgbase` in the modules dir and DTBs in `/boot/dtbs/qcom`, so no pkgbase shim is needed for `linux-sl7`.
- Keep `linux-aarch64` (stock) installable as the **rescue kernel**. It has no internal keyboard, but works with a USB keyboard.
- **Alternative considered:** send the SURFACE_* config to ALARM (like PKGBUILDs #2217/#2220). Do this anyway. The patch queue still forces our own kernel for 6–12 months.

### 3.2 Config deltas vs ALARM

| Option | Why |
|---|---|
| `SURFACE_PLATFORMS=y`, `SURFACE_AGGREGATOR=y` (or `=m` + initramfs), `SURFACE_AGGREGATOR_BUS=y`, `SURFACE_AGGREGATOR_REGISTRY`, `SURFACE_AGGREGATOR_HUB`, `SURFACE_HID_CORE`, `SURFACE_HID` | internal keyboard (incl. at the LUKS prompt) |
| `SURFACE_PLATFORM_PROFILE`, `SENSORS_SURFACE_FAN` | fan speed plus platform profile (feeds power-profiles-daemon, unverified under DT boot) |
| `SPI_HID` (from patch queue), QSPI mode in `SPI_GENI_QCOM` | touchpad, and the SPI touchscreen on Chris's unit (MSHW0460) |
| `I2C_HID_OF=m` (already on) | I2C touchscreen on TBID 2/3 units (MSHW0468) — not Chris's |
| `VIDEO_QCOM_IRIS=m`, `SM_VIDEOCC_8550=m` | HW video decode |
| `CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y` (replacing PERFORMANCE) | battery; the cmdline arg is the belt-and-braces backup |
| `RESET_GPIO=m` (verify still set) | WSA amps |
| `FW_LOADER_COMPRESS_ZSTD=y` (optional) | lets firmware be zstd; until then keep `.xz` |
| `USB4`, `TYPEC_TBT_ALTMODE`: leave off until the host-router series is carried (§5.3) | no X1 host-router driver yet; enabling now creates no domain |
| `VIDEO_VD55G=m` (patch #15), `I2C_QCOM_CCI`, CSI2 PHY driver, `LEDS_QCOM_FLASH=m`, `V4L2_FLASH_LED_CLASS`, v4l2loopback (ALARM ships `v4l2loopback-dkms`) | IR camera + illuminator + howdy bridge |
| `FW_LOADER_COMPRESS_XZ` (already) | firmware stays uncompressed or `.xz` |
| `QCOM_STATS=m` (already on; verify), `DEBUG_FS=y` | sleep diagnostics (`x1e-sleepdoctor`) |
| `UCLAMP_TASK=y` (optional) | lets the power daemon clamp background work; off in ALARM |

### 3.3 Patch queue (ordered, each with upstream status tracked in `patches/series`)

| # | Patch | Source | Upstream status |
|---|---|---|---|
| 1 | ath12k rfkill hack (firmware reports a false hard block) | bryce-hoehn `0001-wifi-rfkill-hack.patch`, ELLX 2e8c2d9, dwhinham 37f883437b | not upstream; DT-property RFC rejected 2026-10-03, so the one-liner stays |
| 2 | spi-geni-qcom QSPI 1-4-4 + GPI QSPI + spi-hid single full-duplex transfer | **preferred:** dwhinham `linux-sp11` `v7.2.8-arch1-sp11` (1b7e53984d, 092fa92263, 6673ac0122, 378b6a8f72; upstream-bound, Arch base); alt: ELLX f3450ff (scuggo) | not posted upstream |
| 3 | spi-hid series (Chromium v4, 2026-06-09) + ItsLucas hardening 0004/0007–0016 | Chromium, ItsLucas | v4, no v5; SL7/SP11 Tested-by on list |
| 4 | romulus DT: touchpad on QSPI (`spi19`, QUP2 SE3, 045E:0C77) | ELLX | out of tree |
| 5 | **romulus13 DT: SPI touchscreen `GTCH` (MSHW0460) on SP11/spi10** — Chris's unit | adapt ItsLucas 15" GTCH DT + spi-hid, denislopt 15" touchscreen module, nix1e touch DT (spi10) to romulus13; resources from the SSDT `GTCH` `_CRS` | ours (15" work exists) |
| 5b | (TBID 2/3 units only) romulus13 DT: I2C-HID touchscreen `ITCH` MSHW0468 @0x34 on i2c8, IRQ GPIO38 | Jizhou Tong (ex-fQwQf) v2, 2026-09-30 (reset-gpio dropped) | in review; **not for Chris's unit**; ship only if TBID detection is solved |
| 6 | **SCMI perf `sustained_freq_khz=0` fix** (`drivers/firmware/arm_scmi/perf.c`: ignore a sustained freq below the lowest OPP) | Dell 7441 X1P-64-100 (omarchy discussion #12441); still present in mainline 7.3-rc5 (`perf.c` ~line 883) | not upstream, no LKML posting; verify SL7 needs it (`ls /sys/devices/system/cpu/cpufreq/`) |
| 7 | X1P64100 fused cores: `cpu@10300`, `cpu@20300` → `status = "fail"` | Dell 7441 pattern; `85-` pacman DTB hook (sorts before `90-mkinitcpio-install`), not a kernel patch | cosmetic/clean boot (CPUs renumber 0–9, clusters 4+3+3) |
| 8 | Camera: OV02C10 DT (cci1 @0x36, CSIPHY4 2-lane, MCLK4, reset gpio 237, privacy LED gpio 225) + CSI2 DPHY driver v18 (in-next, 7.4) + x1e CAMSS dtsi v7 (2026-09-17) + camss stream-on fix (Jizhou Tong) | bryce-hoehn 0004/0005, ELLX 36afa55062 | DPHY in-next; dtsi pending |
| 9 | Iris enable in romulus DT + AHB bridge reset fix + idle/resume crash fix (merged to media tree 2026-09-30, 7.4) | ItsLucas 0019, orvitpng/nix1e, lore | partly queued for 7.4 |
| 10 | dwc3 reinit PHY on resume | bryce-hoehn outgoing 0001–0003 | outgoing |
| 11 | (7.2.x only) backports: `domain_ss3` + PDC wake series (never the DT change alone), qrtr HELLO-on-MHI-resume (`6a5719cc3ef2`, in 7.3-rc4+), 7.4 pmdomain/cpuidle-psci (fused-core clusters reach deep idle) | mainline 7.3 / 7.4 | in 7.3 / queued 7.4 |
| 11b | `qcom_battmgr`: add `capacity` to the X1E property table | posted 2026-09-20 | pending |
| 12 | (optional) DP audio | ItsLucas 0018 (from SP11) | unvalidated |
| 13 | (optional) EC hard-reset-on-reboot for wedged touch rail (GPIO65 must stay with the touchpad) | orvitpng/nix1e `surface-ec-restart`, scuggo `ec_reboot` | out of tree |
| 13b | (optional) DMIC 2.4 MHz fix if mics distort (romulus still 4.8 MHz) | SP11 denali fix, in-next | port |
| 14 | ps883x "fixes for older TB4/USB4 docks" v5 (3 patches; 3/3 = 647f31f34d40 disables USB4 mode on x1e so docks fall back to USB 3.2 Gen2 + DP alt) | Jens Glathe | **applied to usb-next 2026-10-01 → 7.4**; no Cc: stable, so carry until 7.4 |
| 15 | IR camera: petm5 generic `vd55g` driver (ACPI `SMO55F0`, DT `st,vd55g0`) + romulus DT (cci0, csiphy0, `vreg_l6m`, `pm8550_flash` IR LED) + flash re-fire helper | petm5 linux-media "[PATCH 0/7] st-vd55g1: Genericize…" (Sep 2026), linux-surface/kernel #169; DT ours, modelled on Zenbook A14 HM1092 (2026-06-10) | driver in review; DT ours |
| 16 | (future) Qualcomm USB4 host router + binding + SL7 router nodes; USB4 PHY 4/5 Hamoa tables (v6 resend) backport; revert #14 3/3 | Konrad Dybcio (not yet posted); phy v6 2026-09-28 | see §5.3 |
| 17 | (Phase 4) `qcom_pld_power` hwmon ported to romulus13 / SKU 2036 | ItsLucas (15"-only today) | out of tree |

**Patch sources:** dwhinham/linux-sp11 `v7.2.8-arch1-sp11` (preferred for QSPI/spi-hid; Arch kernel base, rebased 2026-10-03), ProgrammerIn-wonderland/ELLX-Kernel (13.8" X Plus confirmed by users; 7.3.0-rc3 build breaks resume), bryce-hoehn/linux-surface-laptop-7 (af76542, 2026-08-06), ItsLucas/surface-laptop-7-ubuntu-kernel (15"-only, best 7.3 audit, spi-hid hardening, SPI touchscreen DT), denislopt/omarchy-surface-laptop7 (15" SPI touchscreen module), orvitpng/nix1e, jhovold/Linaro `qcom-laptops`.

### 3.4 Initramfs (SL7 drop-in `/etc/mkinitcpio.conf.d/zz-sl7.conf`)

- **Use `MODULES+=(…)`, never reset MODULES.**
- Modules, needed for LUKS keyboard and display:

  ```
  surface_aggregator surface_aggregator_registry surface_aggregator_hub
  surface_hid_core surface_hid
  msm dispcc-x1e80100 gpucc-x1e80100 phy-qcom-edp panel-edp ps883x
  pmic_glink pmic_glink_altmode ucsi_glink qrtr
  leds_qcom_lpg pwrseq_qcom_wcn pci_pwrctrl_pwrseq qrtr_mhi ath12k_wifi7
  ```

  (The last line is from denislopt's verified 15" list.) Optionally port denislopt's `omarchy_surface_display` hook, which unblanks msmdrmfb before `encrypt`.

- FILES: `gen70500_sqe.fw gen70500_gmu.bin qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn`.
- `qcom_geni` serial and the x1e pinctrl are built into the ALARM kernel. Verify they stay `=y` in `linux-sl7`.
- **Validate on hardware in Phase 1:** type the LUKS passphrase on the internal keyboard.

### 3.5 Cadence and fallback

- **Now:** 7.2.x (ALARM stable) + backports. **Then** 7.3 once released (≈ Oct 18 2026; avoid 7.3-rc1–rc3, which have the Wi-Fi resume regression), via ALARM `linux-aarch64` 7.3. Rebase the queue on each ALARM bump. Drop patches as they land upstream.
- **Disk:** `/mnt/Rocket4` is at 97% (31 GB free; research uses 2.6 GB). Kernel builds run in CI (arm64 runners) or on another disk, never there.
- **Omarchy gotcha (vault, from ramius):** Omarchy has a single UKI, overwritten in place on kernel upgrade, with no fallback unless a second kernel is installed.
- **Mitigation:**
  - (a) Keep `linux-aarch64` installed as a second Limine entry.
  - (b) Keep limine-snapper-sync snapshots bootable.
  - (c) `sl7-kernel-guard` pacman hook: refuse a `linux-sl7` upgrade if the new UKI lacks `.dtbauto` or the SAM modules. This guards against the regressions seen before omarchy-pkgs #380.
- **Every kernel bump is gated on the Phase 2 test:** update → reboot → LUKS keyboard → Wi-Fi → audio limits.

---

## 4. Upstream hazards to neutralize

| Hazard | Effect on SL7 | Neutralization (overlay) | Upstream fix |
|---|---|---|---|
| `install/hardware/fix-surface-keyboard.sh` matches SL7 (DMI "Surface"; fires when `lsmod \| grep pinctrl_` matches, likely via ALARM's LPASS pinctrl modules), writes `MODULES=(… surface_kbd intel_lpss_pci 8250_dw)` and resets MODULES. Unchanged on quattro and dragon | mkinitcpio fails, so no bootable UKI | path-triggered pacman hook re-patches it to `omarchy-hw-qualcomm-soc && return 0` after every omarchy upgrade (denislopt approach), plus a `zz…` drop-in that sorts last | PR: guard + #8151 (append instead of reset) |
| `ENABLE_UKI=no` default | next kernel update writes an entry with no DTB → reset at boot | add-on forces `ENABLE_UKI=yes`; `sl7-doctor` asserts it | omarchy-pkgs #380 sets yes; verify |
| Quiet-boot flags dropped by `limine-mkinitcpio` | noisy boot | `limine-entry-tool.d` drop-in | — |
| `omarchy-update-restart` looks for `vmlinuz` | "kernel updated, reboot?" after every update | `linux-sl7` ships `vmlinuz`; carry #10232/#12956 if needed | #10232, #12956 |
| `dragon` is 291 commits behind `quattro`; #13362 (convergence) near merge | drift, conflicting extension points | pin SHAs; **retarget onto quattro once #13362 merges**, then register `omarchy-lifecycle-dispatch` entrypoints | #13362 |
| Published aarch64 `omarchy` (edge 4.0.4-1, built from quattro) lacks `install/hardware/qualcomm/*`; #221 unmerged; dragon ISO build check fails without them | ISO cannot be built from published packages | `--local-source omarchy@dragon` + `--local-repo` with #221 (and #222 only if still needed) | #221, #13362 |
| Omarchy forces Wi-Fi power save **off** everywhere (commit da157fb9, 2026-07-24) | 0.1–0.3 W idle on battery | `sl7-powerd` turns it on when on battery only | — |
| `omarchy_hooks.conf` resets MODULES, has the `microcode` hook, and assumes Surface ⇒ Intel iGPU | lost modules / noise | our `zz-sl7.conf` sorts last and appends | comment/guard PR |
| `thunderbolt_module.conf` | initramfs build error | already dropped on aarch64 (#380); verify | done |
| Stable/rc pacman channels have no `[omarchy]` on aarch64 (dragon `helpers/pacman.sh`); stable mirror is x86-only | missing packages / broken updates | **pin the edge channel**; add `[omarchy-dragon-sl7]` local/remote repo after `[omarchy]` | request aarch64 stable publication |
| Hyprland ABI skew: edge `hyprland` wants `libaquamarine.so=13`, ALARM ships 14 | Hyprland won't start | pull `hyprland hyprtoolkit hyprland-guiutils` (and aquamarine) consistently from `[omarchy]` (omarchy-mac `docs/arm-package-sources.md`); CI check that resolves the set | omarchy-pkgs |
| Battery named `qcom-battmgr-bat`, not `BAT*` | battery widget / low-battery notifications missing | carry #13029 until merged | #13029 |
| `clk_ignore_unused pd_ignore_unused` (Qualcomm drop-in) | keeps unused clocks/domains powered, so battery cost | Phase 4 A/B test dropping `pd_ignore_unused`, then `clk_ignore_unused` | report data upstream |
| ALARM default governor = performance | idle/battery drain | Kconfig schedutil + cmdline | — |
| PipeWire "Pro Audio" profile / 100% volume | **speaker damage** (May 2026 incident); safety trip kills audio until reboot | WirePlumber rule hiding the Pro Audio profile for the X1E80100-Romulus card; `sl7-doctor` asserts kernel WSA caps (digital 81 / PA 6) are present; never ship UCM overrides that raise limits | upstream speaker protection (AudioReach VI-feedback) |
| x86-only packages in `omarchy-other.packages` (23 incl. `lib32-*`, `intel-*`, `thermald`, `nvidia-*`, `linux-omarchy`) and `nvim`/`obs-studio` in base | pacstrap fails | ISO filter via dragon's aarch64 package lists (#13362 `omarchy-aarch64.packages`) | #13362 |
| x86-only install-menu apps (ollama bin, lm-studio, cursor, spotify…) | broken menu entries | rely on #11025 gating | #11025 |
| `omarchy-update-pacman-guard` / `omarchy update` flow | our repo must update in the same transaction | ship packages via pacman repo only; no out-of-band installers | — |
| `alsa-restore` race with DSP (seen on SP11) | audio state garbage at boot | mask only if observed | — |
| `omarchy setup direct boot` on Surface | Surface UEFI drops/reorders custom EFI entries | never use it; keep Limine + `\EFI\BOOT\BOOTAA64.EFI` | #12733 |
| `omarchy setup security fingerprint` needs `libfprint-git` (missing on aarch64) | menu error | irrelevant: no fingerprint reader on this SKU | — |
| Omarchy shell spawns `busctl` every 2 s to read the power profile (`shell/plugins/services/battery/Service.qml:101`) | steady userspace wakeups on battery | patch in add-on only if measurable; prefer upstream fix | PR: D-Bus `PropertiesChanged` subscription |
| Omarchy AC/battery switching listens for udev on Mains/USB supplies; `qcom-battmgr-usb` emits no event on plug/unplug | battery profile never applies | `sl7-powerd` hooks the battery supply's change events (Dell 7441 approach) | PR: also watch battery `status` changes |

---

## 5. Feature matrix

**Legend:** ✅ works · 🟡 partial / needs our work · 🔧 out-of-tree patch we carry · ⛔ blocked upstream · ❓ unverified.

| Feature | Status now (SL7, X1P-64-100) | v1 plan | Later / blocked |
|---|---|---|---|
| **Boot / NVMe / display / backlight** | ✅ upstream DT; needs MS zap shader | firmware stage + initramfs; VT-switch sleep hook for the gamma-LUT corruption on resume (matters for hyprsunset) | — |
| **GPU (Adreno X1-85)** | ✅ Mesa 26.2.3 freedreno/turnip; speed bin auto from fuses | `vulkan-freedreno`; verify `dmesg \| grep -i speed` | x86 apps via FEX/box64 (AUR-only; package in Phase 5+) |
| **Performance / cpufreq** | 🟡 SCMI works, but ALARM defaults to performance; **X1P-64-100 may expose cpufreq only for CPUs 0–3** (SCMI `sustained_freq_khz=0`) | schedutil; SCMI patch #6 if needed; fused-core DT fixup | per-cluster power telemetry (ItsLucas `qcom_pld_power`, 15"-validated) |
| **Standby / suspend** | 🟡 firmware offers `s2idle [deep]`; resume OK on 7.0/7.2; 7.3-rc1–3 Wi-Fi resume regression fixed in rc4; touchpad needs rebind; SP11 saw `cpu-sleep-0` s2idle crashes. **~0.9–1.2 W asleep (≈2 days) vs Windows 0.2–0.35 W**; SoC never power-collapses (`cxsd`/`ddr`/`aosd` = 0 on every X1 report) | sleep hooks (touchpad rebind, VT switch); `fw_devlink.sync_state=timeout`; `x1e-sleepdoctor` | CX collapse (unsolved upstream); Windows' "weeks" = hibernate, blocked here (§5.2) |
| **Power efficiency (running)** | 🟡 idle 4–5 W vs Windows ~3 W; light mixed 7–10 h vs 13–16 h (§5.2). ~~6–7 h via core offlining~~: claim **withdrawn** in linux-surface #1590 (the gain was unplugged USB headphones) | Phase 4 ranked plan; governor + SCMI fix first | 7.3 `domain_ss3`; memlat DDR/LLCC scaling (RFC v8); cgroup cluster parking (ours) |
| **Thermal / fan** | 🟡 tsens + LMh upstream; fan firmware-driven via SAM | enable SAM fan/profile | verify power-profiles-daemon backend under DT boot |
| **Keyboard** | ✅ upstream SAM, but **❌ on stock ALARM kernel** | `linux-sl7` + initramfs | ALARM config PR |
| **Keyboard backlight** | ❓ appears EC/firmware-controlled via the backlight key; no LED class seen (low confidence) | verify key works; check `/sys/class/leds` | if a SAM command exists, write a driver (research item) |
| **Touchpad** | 🔧 QSPI + spi-hid + iptsd fork + calibration | patches #2–4, `iptsd-sl7` (bind by path `88c000.spi`, tap-to-click off) | upstream spi-hid (6–12 months) |
| **Touchscreen (13.8")** | 🔧 **Chris's unit is SPI `GTCH` (MSHW0460)**, like the 15"; the I2C MSHW0468 patch (#5b) covers only TBID 2/3 units | patch #5 (adapt 15" SPI touchscreen work to romulus13) | pen: ❓ — a "Touch Pen Processor" HID collection exists; test with a Surface Pen |
| **Wi-Fi (WCN7850, ath12k)** | 🔧 rfkill hack + board-2 remap; random MAC | patch #1, `ath12k-board-sl7`, `sl7-mac-fixup`; test power-save | upstream rfkill + board file in linux-firmware |
| **Bluetooth** | ✅ needs public address | set via `sl7-mac-fixup` (btmgmt/udev) | — |
| **Audio: speakers** | 🟡 upstream static cap since 7.1 (`0a5ee0e520ef`), **no active speaker protection**. The May 2026 destroyed-speaker case was on a pre-7.1 kernel via Pro Audio | kernel ≥7.1 only; caps enforced, Pro Audio hidden (WirePlumber rule), volume guard | AudioReach speaker-protection upstream |
| **Audio: mics / headphones** | ✅ mics (romulus DMIC still 4.8 MHz; SP11 saw distortion, fixed at 2.4 MHz); 🟡 jack sounds poor | UCM from alsa-ucm-conf 1.2.16.1; topology already in linux-firmware | DMIC fix (#13b), DP audio (#12) |
| **USB-A / USB-C / DP alt-mode** | ✅ both USB-C ports: USB 3.x 10 Gb/s, one DP 1.4 stream, PD charging (MST dock: 1 monitor only; dr_mode host). USB4/TB4 docks can give USB but no display. One X1E report: booting with the charger attached sometimes needed a replug to charge | patch #14 (in usb-next for 7.4) so USB4 docks fall back cleanly to USB 3.2 Gen2 + DP alt | MST patches |
| **USB4 / Thunderbolt** | ⛔ host-router driver **not posted** (Konrad 09-16: "soon"; DWC3 tunneling v4 cover 09-29 cites an out-of-tree driver set tested on the X1E CRD); hardware supports PCIe tunnelling, software does not (§5.3). TB3-only devices don't work | carry #14 now; carry the host-router series the day it posts (patch #16) | mainline 7.5 best case (late Feb–Mar 2027), 7.6 (~May 2027) likely; stretch: port jdvmi00/glymur-usb4 |
| **Surface Connect** | ❓ USB via `usb_mp` MP0 likely; charging EC/PD-managed, likely fine; dock displays likely **not** (`mdss_dp2`/`usb_1_ss2` disabled in romulus DT) | Phase 3 test with charger + Surface Dock | DT enablement of DP2 if it is wired there |
| **Adaptive display: 120 Hz** | ❓ panel is 2304×1536@120 (seen working on SL8) | verify 120 Hz mode in Hyprland | — |
| **Adaptive display: VRR / PSR / HDR** | ⛔ no upstream msm VRR (scuggo `msm-vrr-avr.patch` exists, experimental); no HDR. 🟡 PSR code exists in msm but is off by default (`msm.psr_enabled`) | Phase 4 trial of `msm.psr_enabled=1` after checking DPCD 0x070; 60 Hz on battery (EDID captured in `device/sl7-capture/display.reg`) | upstream msm VRR |
| **Adaptive display: auto-brightness (ALS MSHW0473)** | 🔧 behind ADSP sensor core; proven on SP11 via hexagonrpcd + sensor registry + libssc | Phase 5: package `hexagonrpcd`, stage sensor registry, small brightness daemon (or iio-sensor-proxy with ssc) | — |
| **Battery reporting** | 🟡 `qcom_battmgr` (needs ADSP running; `.jsn` likely unnecessary); X1E property table lacks `capacity` upstream | firmware stage; #11b capacity patch; battery-name fix (#13029); udev rule forwarding battery change events (UPower goes stale otherwise) | — |
| **Charge limit** | ❓ `charge_control_{start,end}_threshold` exist for x1e (6.18+); unknown if Surface firmware honours them | Phase 5: test; if honoured, udev rule + Omarchy menu toggle (80%). **Fallback:** Surface UEFI "Battery Limit" (50%) always works | — |
| **HW video decode (Iris)** | 🔧 driver upstream; not in romulus DT; config off in ALARM | Phase 5: config + patch #9 + `qcvss8380.mbn`; mpv `--hwdec=v4l2m2m-copy` | browsers won't use V4L2 stateful decode |
| **Camera (OV02C10)** | 🔧 DT + CAMSS series + libcamera soft-ISP; quality poor (green tint/flicker) | Phase 5: patch #8, libcamera sensor helper + tuning, PipeWire 1.6.9, `70-dma-heap.rules` uaccess, Firefox pipewire camera pref | HW ISP (patches posted Jul 2026) |
| **IR camera / Howdy face unlock** | 🔧 **Feasible, Phase 5 project (~1.5–2.5 weeks)**. SMO55F0 = **ST VD55G0** (mono NIR global shutter), confirmed `MSHW0472` on Chris's unit; drivers exist (petm5 `vd55g`, ST GPL); already used for Windows-Hello-style unlock on Surface Pro 8/9. SL7 wiring decoded from the MSI (§6 Phase 5.1). No Microsoft firmware needed | Phase 5: patch #15, `sl7-ir` bridge, howdy-next for aarch64 | MCLK pin and illuminator channel/strobe must be found on hardware; no fingerprint reader on this SKU |
| **NPU (Hexagon v73)** | 🟡/❓ see conflict below. Userspace matured: qualcomm/fastrpc 1.0.8, `onnxruntime-qnn` 2.6.0 Linux ARM64 wheels, QAIRT 2.48 | Phase 5 | untested on SL7; SP11 needed a fastrpc GLINK fix |
| **Hibernation** | ⛔ two blockers: image write hangs at `test_resume` (Dell 7441); RTC has `qcom,no-alarm` (alarm owned by ADSP) so suspend-then-hibernate cannot schedule its wake. (Lockdown is **not** a blocker: ALARM has `SECURITY_LOCKDOWN_LSM` unset) | disable | Phase 4 research: bisect with `pm_test` + ramoops; low-battery hibernate via battmgr `low_capacity` trip (§6 Phase 4) |
| **TPM (LUKS auto-unlock)** | ⛔ not exposed; `systemd.tpm2_wait=0` needed | passphrase unlock | — |
| **Lid** | ✅ | — | — |
| **Pen** | ❓ research said N/A; Chris's digitizer exposes a pen HID collection | test once the SPI touchscreen works | — |
| **x86 emulation** | 🟡 FEX-2609 / box64 0.4.4 exist; not in ALARM (AUR has box64 only) | build FEX ourselves (Phase 5) | — |
| **EL2 / KVM** | ⛔ practical (slbounce + qebspil, DSPs lost) | none | revisit with systemd-boot |

### Conflicts between research reports (resolve on hardware)

| Topic | Report A | Report B | Verification |
|---|---|---|---|
| **NPU** | Proven on Surface Pro 11 (same die/firmware family): CDSP + patched `fastrpc.ko` + `libcdsprpc` + QNN HTP skel libs → llama.cpp HTP0, 48.8 tok/s gen (denisix SP11 NPU.md) | "CDSP loads, no user-facing stack" | A is the more specific, sourced claim. Phase 5: bring CDSP up, build qualcomm/fastrpc, run llama.cpp Snapdragon backend on `HTP0`. Needs Secure Boot off (unsigned PD) and a CDSP restart between model loads. Mark ❓ until then |
| **Touchscreen bus/HWID** | ~~13.8" = I2C MSHW0468~~ | **Resolved 2026-10-03:** both exist on 13.8", selected by touch board ID (SSDT: TBID 2/3 → I2C `ITCH` MSHW0468 on I2C9 = Linux i2c8; else SPI `GTCH` on SP11). Chris's unit reports **MSHW0460 → SPI** | On device: confirm the SPI bus/CS and IRQ from the SSDT `GTCH` `_CRS` against the 15" DT |
| **board-2.bin remap** | "board-id 255 → board-id 44" | "subsystem-device 3378 → 1107" | **Resolved:** linux-firmware has `17cb:1107/17cb:1107` only for board-ids 82, 44, 513, 514; `fix-board-2-wifi.sh` clones the `subsystem-device=3378, board-id 255` entry onto the SL7 string. Still encode exactly what dmesg requests on the device |
| **Charge limit** | sysfs present on x1e | "unknown if SL7 firmware honours it" | Set end=80, charge from 75%, observe `status`/`current_now` |
| **Keyboard backlight** | "EC-controlled via key" | "no evidence found" | Press the key on hardware; check `/sys/class/leds`, SAM event traces |
| **Core offlining** | "6–7 h after disabling cores" (ELLX maintainer) | withdrawn minutes later in the same thread: the gain was unplugging USB headphones | Treat as void. Hotplug is costly (stop_machine); use cgroup cluster parking instead and measure |
| **IR camera** | "SMO55F0, no driver → not feasible" (first round; repeated in the platform redo) | SMO55F0 = VD55G0 with working drivers; SL7 wiring decoded from the MSI, twice | Resolved in favour of B; MSHW0472 confirmed on Chris's unit. Probe at cci0 0x10 (Phase 5.1) |
| **Topology file** | "no romulus topology in audioreach-topology" (first round) | `X1E80100-Romulus-tplg.bin` is in linux-firmware (since 2026-01-10) | Resolved: B |
| **`.jsn` files** | needed for battery (`battmgr.jsn` avoids EAGAIN) | in-kernel pd-mapper has `x1e80100_domains`; likely unnecessary | Install anyway; on device, test battery with and without them |
| **CxPC gain on 7.3** | "1.2 W → 0.4 W" (repeated in #12441) | no primary measurement; Dell 7441 saw no gain, CX still not collapsing | Measure with `qcom_stats` on 7.3 with the full PDC series |

### 5.2 Power: Windows vs Linux (numbers)

**Windows, SL7 13.8" (54 Wh)**

| Measure | Result | Source |
|---|---|---|
| Web browsing, 150 nits | 14 h 12 m @60 Hz / ~13 h @120 Hz (Notebookcheck); 15 h 44 m (Laptop Mag / Tom's Guide) | reviews, 2024 — **all X Elite units**; no outlet ran a standard battery test on the X Plus. JustJosh (qualitative): X Plus lasts noticeably longer |
| Local video | 19 h 41 m (≈2.7 W) Notebookcheck; 22–23 h Reviewed / Mashable | X Elite |
| Idle at 150 nits | ~3.5 W avg (min 1.4 W) | Notebookcheck |
| Modern Standby | 0.05–0.3 W; X Plus owner: 3% over 8.5 h (~0.19 W) after a BT UART (`_SB.UR15`) DRIPS fix | mymce 2026-08-02; SL8 0.27 W (#13372) |
| "Weeks" of standby | **DRIPS plus hibernate**: even 0.2 W empties the battery in ~11 days | derived |
| **Chris's own baseline** | `sleepstudy.html`, `battery-report.html` captured 2026-10-03 (to be analysed) | `device/sl7-capture/` |

**Consensus for the X Plus 13.8" on Windows (inferred from X Elite tests):** light web 13–16 h (3.3–4 W), video 19–22 h (2.4–2.8 W), idle ~3 W at 150 nits.

**Estimate for this SL7 on Linux** (confidence medium-low unless noted)

| Scenario | Windows | Linux now (ALARM 7.2) | Linux after Phase 4 (7.2) |
|---|---|---|---|
| Idle desktop, ~150 nits | ~3 W → ~17 h | 4.5–6 W → 9–11.5 h | 3.3–4.2 W → 12–16 h |
| Light mixed (browser, terminal) | 3.3–4 W → 13–16 h | 6–9 W → 6–9 h | 4.5–6 W → 9–11.5 h |
| 1080p video | 2.4–2.8 W → 19–22 h | browser software decode 6–8 W → 6.5–8.5 h | mpv + Iris 3.5–4.5 W → 11.5–15 h; browser 5–6.5 W → 8–10.5 h (low) |
| Suspend (medium) | 0.05–0.3 W → 7–40 days | 1.0–1.2 W → 43–52 h (15–18%/night) | ~0.9 W → ~58 h (~14%/night); 0.4–0.7 W only if CX collapses (unproven, low) |

"Linux now" assumes the performance governor, cpufreq on CPUs 0–3 only, 120 Hz, Omarchy defaults (animations on, Wi-Fi PS off).

**Why Linux sleep is 3–4× Windows:** CX never collapses (`cxsd`/`ddr` counters stay 0); providers that never reach `sync_state` hold boot-time max votes (~0.2 W, measured); ADSP firmware ticks ~97×/s (suspect, unproven); CDSP never sleeps until `sync_state`. Ruled out on the Dell X1P: `clk/pd_ignore_unused` (for suspend), PCIe L1ss, stopping remoteprocs, disarming wake sources. Even the SL8, where CX does collapse, sits ~0.4 W above Windows.

### 5.3 USB4 status (2026-10-03)

| Piece | Status |
|---|---|
| Non-PCI NHI refactor (`tb_nhi_ops`) | merged, 7.2 |
| "thunderbolt: Make PCIe NHI support opt-in" | v1 posted 2026-09-15 |
| USB4 PHY (QMP USB43DP) | patches 1–3 + 5 in next for 7.4; **Hamoa tables (4/5) still missing** (patchwork's "accepted" is wrong), v6 resend 2026-09-28 has no maintainer reply |
| GCC USB4 SYS_CLK fix | in next (7.4) |
| ps883x dock fallback (#14) | **applied to usb-next 2026-10-01 → 7.4** |
| DWC3 link tunneling state reporting | v4 2026-09-29, changes requested 10-03 |
| PS8830 retimer USB4/TBT mode, pmic_glink TBT/USB4 altmode, DISP_CC USB4 router clocks | upstream |
| Host-router DT binding | only an RFC (2025-09-16), not for merge |
| **Qualcomm host-router driver** | **not posted**; Konrad 09-16 "soon to be" in review; tested on the X1E CRD out of tree |
| hamoa.dtsi router nodes, SL7 wiring | none |
| DP tunnelling (drm/msm) | nothing |
| PCIe tunnelling | no code; **hardware supports it** (Konrad) |
| Router firmware | inside `QcUsb4Filter8380.sys`, which is in the public MSI |

- **Timeline:** 7.3 ≈ Oct 18; 7.4 ≈ late Dec/early Jan; 7.5 ≈ late Feb–mid Mar 2027 (**best case**, needs the driver posted and queued by early Dec); 7.6 ≈ May 2027 (**more likely**). DP tunnelling may trail.
- **Our path:** (1) now: patch #14 for clean dock fallback; (2) the day Konrad posts: carry host router + PHY v6 + SL7 router nodes, revert #14 3/3 (647f31f34d40), enable `USB4`/`TYPEC_TBT_ALTMODE`, firmware from `QcUsb4Filter8380.sys` (public MSI); (3) stretch project: port jdvmi00/glymur-usb4 (SL8/X2, ~13.3k lines reverse-engineered, same IP family; clocks/IRQs/PHY/DP/sideband differ; suspend broken even on SL8). Weeks of reverse-engineering; coordinate with its author.
- **What USB4 buys:** DP tunnelling (dual displays / 6K through one dock), TB3 device compatibility. **Not** faster storage (USB3 tunnel is still 10 Gb/s); PCIe tunnelling (NVMe enclosures) only once someone writes it (hardware-capable); **no** eGPU.
- **Re-check:** `usb4/TRACKER.md` in the research folder lists every series and how to re-check it.
- **Test:** `/sys/bus/thunderbolt`, `boltctl list`, tbtools, `/sys/class/typec/port*/port*-partner`, `clk_summary` for `gcc_usb4_*_p2rr2p`.

---

## 6. Phased roadmap

### Phase 0 — Prep on Windows (no risk)

Status 2026-10-03: ✅ = done.

1. Update Surface firmware via Windows Update until none remain (after a wipe, firmware updates need Windows back). Done before the capture: UEFI 175.235.235.
2. Make a **Surface recovery USB** (Microsoft Surface recovery image, SL7 model 2036). ⏳
3. ✅ Save the **BitLocker recovery key** (saved off-device).
4. ✅ **SL7 MSI** (id 106120, `SurfaceLaptop7_ARM_Win11_26100_26.053.36539.0.msi`, sha256 `66b6e1ac…229b`) downloaded and extracted in the research folder.
5. ✅ **Identity capture** (`device/sl7-capture/` in the research folder; see "Device facts" at the top): SKU 2036, UEFI 175.235.235, X1P64100, IR `MSHW0472`, touchscreen **`MSHW0460` (SPI)**, Wi-Fi MAC, display EDID. ⏳ BT address (Device Manager → Bluetooth adapter → Advanced → Address). CHIDs are read on Linux in Phase 0.5 (`fwupdtool hwids`), not on Windows.
6. ✅ Driver export (`pnputil /export-driver *`, 300 packages). Optional now: the MSI covers every needed file, including `QcUsb4Filter8380.sys`.
7. ✅ Power baseline: `powercfg /sleepstudy` and `/batteryreport` captured; analyse into `docs/power.md` as the Windows target.
8. **Decided: wipe**, once Phase 1 proves the live ISO works on this unit. Disk math (for the record):
   - ~240 GB usable; Windows fills ~220 GB today.
   - Dual boot needs Windows cut to ≤ ~100 GB used (a ~120 GB partition), leaving ~115 GB for Omarchy with snapper snapshots. That is workable but tight, and needs heavy Windows pruning.
   - Omarchy alone: ~230 GB.
   - The MSI plus captured identity data remove every dependency on Windows. Surface UEFI updates come via Windows Update; restore via the recovery USB if ever needed.
9. In Surface UEFI (Volume Up + Power): **Secure Boot → None**, boot order USB first, **right before the first Linux boot** (Windows will then ask for the BitLocker key). Leave "Battery Limit" off until the charge-limit test.

**Exit:** recovery USB verified; BT address recorded; everything else above is done.

### Phase 0.5 — Reconnaissance boot (read-only, Windows untouched)

**Goal:** answer the open hardware questions before committing the kernel build, using an existing Snapdragon live image (no install).

- **Prereqs:** Secure Boot off (temporarily; Windows asks for the BitLocker key afterwards), a USB keyboard (the stock image may lack the SAM keyboard), a spare USB stick written with `dd`.
- **Image candidates:** Omarchy dragon ISO built locally (needs #221 locally anyway), Ubuntu 26.10 Snapdragon Concept, or an ELLX-based Ubuntu image (13.8" X Plus confirmed). Note: one 16 GB X1P 2036 bootlooped to GRUB on Ubuntu images (Discourse #2162); GRUB-based images need `terminal_output gfxterm`.
- **Read-only check script** (`tools/recon.sh`, writes a report to the stick):
  - `/sys/class/dmi/id/{product_name,product_sku,bios_version}`, `fwupdtool hwids` (CHIDs vs `romulus13.json`), `tr '\0' '\n' </sys/firmware/devicetree/base/compatible`;
  - `ls /sys/devices/system/cpu/cpufreq/`, governors, `lscpu`, `dmesg | grep 'failed to boot CPU'` (SCMI bug, fused cores, cluster layout);
  - `cat /sys/power/mem_sleep`; GPU speed bin from dmesg;
  - panel modes (EDID / `modetest` / `hyprctl monitors all`), DPCD 0x070 via `/dev/drm_dp_aux*` (PSR);
  - `lsmod | grep pinctrl_` (does `fix-surface-keyboard.sh` fire?);
  - `journalctl -k -b | grep 'sync_state() pending'`;
  - `/sys/class/power_supply/*`, `ls /sys/firmware/acpi/platform_profile`, `/sys/class/leds`;
  - `modprobe qcom_stats` and dump `aosd/cxsd/ddr`.
- Nothing is written to the internal disk.

**Exit:** report saved to `docs/device/recon-<date>.txt`; open questions in §8 updated.

### Phase 1 — Live ISO boots on SL7

- Build the ISO: `omarchy-iso-make --arch aarch64 --media-target aarch64/snapdragon --edge --local-source <omarchy@dragon> <omarchy-pkgs> --local-repo <ours> --keep-pkg-cache --no-boot-offer`, with local repo = `linux-sl7`, qcom-firmware-extract (#221), `sl7-firmware`, add-on, iptsd-sl7 (+ the #222 shim only if still needed) + SL7 `platforms.json`. Built on the GitHub `ubuntu-24.04-arm` runner. `dd` it to USB (not Ventoy).
- Expect `psci: failed to boot CPU7/CPU11 (-22)` and a **black screen for ~2 min** on first boot (Dell 7441); both are normal.
- **Checks:**
  - `tr '\0' '\n' </sys/firmware/devicetree/base/compatible` → `microsoft,romulus13`, `qcom,x1e80100`;
  - display up (after firmware stage);
  - internal keyboard works;
  - `lscpu` shows 10 CPUs; which cpufreq policies exist;
  - speed bin in dmesg.

**Exit:** a live session reaches Hyprland with the internal keyboard on the correct DTB.

### Phase 2 — Installed system that survives updates

- Encrypted install on the target (a spare/wiped disk is fine; dual boot needs omarchy-iso #192).
- **Checks:**
  - LUKS unlock on the internal keyboard;
  - Limine fallback entry works;
  - `omarchy update` → new UKI still has `.dtbauto` and SAM modules;
  - a kernel bump (7.2.x → 7.2.y) → reboot OK;
  - snapper rollback boots.

**Exit:** three consecutive update/reboot cycles are clean.

### Phase 3 — Core hardware

- Wi-Fi (rfkill + board-2 + MAC), BT address.
- Audio with safety: caps verified, Pro Audio hidden, jack.
- Battery reporting.
- Touchpad (iptsd calibration, suspend rebind).
- Touchscreen (SPI `GTCH` on Chris's unit); pen test if a Surface Pen is available.
- USB-C DP; USB4/TB4 dock fallback (patch #14); Surface Connect charging, USB and dock display (expect no display).

**Exit:** a full workday on battery with no USB peripherals; `sl7-doctor` all green.

### Phase 4 — Power tuning (measured)

**Measurement harness first** (`docs/power.md`, results as JSONL: kernel, cmdline, config hash, counters, watts):

- Battery gauge: `energy_now` deltas from `qcom-battmgr-bat`. It steps in 10 mWh, so runs must be **≥30 min**; subtract ~**24 mWh per suspend/resume cycle**.
- Fixed brightness via `brightnessctl`; three repeats each of: 20-min idle, mpv loop, scripted browser, overnight suspend.
- Counters diffed per run: `/sys/kernel/debug/qcom_stats/*` (`aosd`, `cxsd`, `ddr`), `interconnect_summary`, `clk_summary`, `regulator_summary`, `pm_genpd/*`, cpufreq `time_in_state`, cpuidle usage, devfreq `trans_stat`, `wakeup_sources`, `/proc/interrupts` (skip the `pmic_arb` column).
- powertop for tunables and wakeups only; its wattage estimate is unreliable here.

**Ranked plan** (A/B one change at a time; ship what measures as a win):

| # | Change | Expected gain | Effort |
|---|---|---|---|
| 1 | **Governor + SCMI fix.** Check `ls /sys/devices/system/cpu/cpufreq/` and `scaling_governor`. schedutil (Kconfig + `cpufreq.default_governor=schedutil`); if only policy0 exists, SCMI `perf.c` patch #6. On battery cap clusters 1–2 at ~2.2 GHz via per-policy `scaling_max_freq` | 0.5–2 W at light load | minutes / small patch |
| 2 | **`fw_devlink.sync_state=timeout`** + `VIDEO_QCOM_IRIS=m` + `SM_VIDEOCC_8550=m` (unbound nodes block `sync_state`; QCE is another SL7 blocker). Verify `journalctl -k -b \| grep 'sync_state() pending'` | ~0.2 W suspend (measured on Dell X1P); 0.1–0.4 W awake (est.) | low |
| 3 | **Display:** 60 Hz on battery (`hyprctl keyword monitor eDP-1,2304x1536@60,…` if EDID lists it); brightness (~0.7 W per ~100 nits); keep Hyprland VFR; blur/animations off on battery; trial `msm.psr_enabled=1` after reading DPCD 0x070 via `/dev/drm_dp_aux*` | 0.3 W (60 Hz) + 0.3–0.6 W (PSR, risk of glitches) | low |
| 4 | Wi-Fi power save on battery (Omarchy forces it off since 2026-07-24), selective runtime PM (powertop tunables), rfkill BT when unused; check the BT UART `runtime_status` (on Windows a BT UART blocked DRIPS) | 0.1–0.3 W | low |
| 5 | SAM `SURFACE_PLATFORM_PROFILE` + fan as the power-profiles-daemon backend | fan/thermal behaviour, small W | low–medium |
| 6 | Kernel 7.3 `domain_ss3` **with the full PDC wake series** (never the DT change alone); check whether `cxsd` moves | uncertain (Dell saw none) | medium |
| 7 | Deep vs s2idle: keep deep (firmware system suspend) on 7.2; re-test s2idle on 7.3. `cpu-sleep-0` disable-during-suspend only if s2idle hangs (SP11) | — | low |
| 8 | Drop `clk_ignore_unused pd_ignore_unused` **only after** msm + dispcc + gpucc are in the initramfs (Dell: 1 in 5 boots froze otherwise; zero suspend gain there) | awake gain unmeasured | low |
| 9 | Small: `cpuidle.governor=teo`; `UCLAMP_TASK` for background clamping; EAS cannot activate (equal capacities, no `capacity-dmips-mhz`; confirm `/sys/kernel/debug/energy_model`); fix Omarchy's 2 s `busctl` poll | a few % | low |
| 10 | **Hibernation research:** bisect the image-write hang (`pm_test` platform/processors/core + ramoops); the RTC `qcom,no-alarm` (ADSP-owned alarm) blocks suspend-then-hibernate (lockdown does not: off in ALARM) | enables weeks of standby | high |

Design notes for each deliverable below: `power/ideas/01`–`06` in the research folder.

**Our own deliverables (not in anyone's code yet):**

1. **`x1e-sleepdoctor`:** snapshot the counters around a suspend or screen-off idle, then name the blocker: pending `sync_state`, interconnect nodes still voting, clocks/genpds left on, non-sleeping remoteprocs (ADSP/CDSP sleep stats), wake-source deltas. Output e.g. "CX held: CDSP never slept; 4 icc nodes voting". Upstream as a tool the community lacks.
2. **Cgroup cluster parking (`sl7-powerd`):** on battery, `systemctl set-property --runtime user.slice system.slice AllowedCPUs=<cluster 0>` so clusters 1–2 empty and reach cluster idle. Widen the mask when PSI/utilisation stays high ~300 ms, narrow after ~5 s low load. Microsecond switches, no hotplug or stop_machine; cluster-aware, unlike scuggo's hotplug module. Verify the 10-core cluster layout (`lscpu`) first. Est. 0.2–0.8 W at light load, unmeasured; risk: latency spikes, pinned kthreads still run on parked clusters.
3. **`qcom_pld_power` port to romulus13 (patch #17):** per-cluster, GPU and system watts from the firmware ring at 0x81f30000, as feedback for parking and frequency caps. Chris's UEFI 175.235.235 is the exact version ItsLucas validated on (15").
4. **Unified AC/battery switcher (`sl7-powerd`):** driven by the battery supply's events (works around `qcom-battmgr-usb` sending none); switches 60/120 Hz, per-cluster `scaling_max_freq`, GPU devfreq max, Wi-Fi PS, blur/animations, SAM platform profile, PSR once proven.
5. **Low-battery hibernate via battmgr wake** (after #10): set the unused `low_capacity` field of the battmgr notification request as a trip point (hypothesis: the ADSP wakes the SoC when crossed); on wake hibernate or power off, else re-suspend immediately, avoiding dark wakes.
6. **Upstream** the SCMI sustained-freq fix and the X1P `sync_state` findings to LKML.

**Exit:** documented best config shipped as defaults; suspend drain and idle W recorded against the Windows numbers (§5.2); `x1e-sleepdoctor` and `sl7-powerd` packaged.

### Phase 5 — Extended features

- Camera (DT + libcamera tuning).
- Iris HW decode.
- NPU (fastrpc + llama.cpp HTP; then ONNX Runtime QNN EP, which also unblocks a Linux path for privacysur).
- ALS auto-brightness (hexagonrpcd + libssc + daemon).
- Charge-limit test + Omarchy menu toggle.
- 120 Hz verification.
- FEX.
- Keyboard-backlight investigation.
- IR face unlock (Phase 5.1 below).
- USB4: carry the host-router series when posted (§5.3).

**Exit:** each feature either shipped or documented as blocked, with the reason.

#### Phase 5.1 — IR face unlock (~1.5–2.5 weeks of evenings)

**Hardware** (decoded from `SurfaceLaptop7_ARM_Win11_26100_26.053.36539.0.msi`: `surfacecamauxsensor_extension8380.inf`, `aux_vd55g0_MSHW0472.bin`, `CAMI_RES_MSHW0472.bin`, `CAMP_PCFG_MSHW0475.bin`, `qccamflash_ext8380.inf`, with geocausa's decoders; the same method reproduces the known OV02C10 wiring exactly):

| Item | Value |
|---|---|
| Sensor | ACPI `SMO55F0` / `MSHW0472` = **ST VD55G0** (confirmed on Chris's unit), 644×604 mono NIR global shutter, RAW10 at **36 fps** (1200 × 1750 timing; the stored "60" is a nominal max) |
| Bus | **CCI0 master0** (`cci0_i2c0`, gpio101/102), 400 kHz, 7-bit addr **0x10** (SP11 uses 0x60) |
| CSI | **csiphy0**, 1 lane, **link-frequency ≈ 378 MHz** (756 Mbps/lane; binding needs ≥375 MHz) |
| Reset | GPIO **109** |
| Rails | **LDO4_M 1.8 V** (VIO), **LDO2_M 1.2 V** (VCORE), **LDO6_M 1.8 V** (VANA, what Windows votes). `vreg_l6m` is **not** in the romulus DT: add pm8010 ldo6 pinned min = max = 1.8 V. Never 2.8 V (ST's binding text and SP11 say 2.8 V; do not "fix" it). csiphy0 rails = csiphy4's (L1C 1.2 V, L2C 0.88 V) |
| Sequence | reset low → L4M → L2M → 1 → L6M → 1 → reset high → 1; D3: reset low → 5 → L6M off → **50** → L2M off → L4M off |
| MCLK | **unknown**: no SL7 RES file names one (the module's "24 MHz" field does not name a pin). Test order: MCLK0 (gpio96) at 19.2/24 MHz → MCLK1–3 (gpio97–99) → no clock |
| Illuminator | PM8550 flash-LED module (`pm8550_flash: led-controller@ee00`, `qcom,spmi-flash-led`, leds-qcom-flash), **700 mA** (`QCOM0C27`); **channel unknown**; driver strings show both SW strobe and a CCI-timer trigger path; an A14-style SW re-fire under the 1.28 s timer works either way |
| Privacy LED | GPIO225 (already in DT); Windows normally leaves it off for IR |

**Software stack:**

- Kernel: patch #15 (petm5 `vd55g`, with `led_mode`, `st,leds` strobe, `limit_flash_duty_cycle`); fallback ST's `vd55g0-linux-driver`. Needs CAMSS/csiphy DT already present (ELLX-based tree), plus `&cci0`, `&csiphy0` (vdda rails as csiphy4, verify), camss port@0 endpoint, pinctrl for gpio96/109, `ir_flash` LED node (`LED_COLOR_ID_IR`, 700 mA flash max, 1.28 s timeout, low torch current).
- Illuminator keep-alive: port the Zenbook A14 re-fire helper (re-fires the PM8550 flash every ~100 ms while streaming) or a small userspace pulser, **keeping the duty-cycle cap**.
- Firmware: `vd55g0-cut1/cut2.bin` from petm5/vd55g-firmware (GPL). **No Microsoft firmware is needed for IR.**
- Upstream shape is unsettled: ST (2026-09-04) questioned folding VD55G0 into the VD55G1 driver; ST's own `vd55g0.c` may become mainline. Base: Bryan O'Donoghue's x1e camera DTSI v6/v7 (mainline 7.3 has no X1E CAMSS/CCI/CSIPHY DT nodes) or the ELLX tree. Draft DT in `ir/REPORT.md` §3.
- Bridge: prefer **Y8_1X8 end to end** (RDI outputs GREY 644×604 directly); fallback Y10P unpacked in the bridge → v4l2loopback at a stable `/dev/sl7-ir-camera` (template: fildunsky `surface-ir-bridge`, adapted to CAMSS entity names; drive the privacy LED while streaming; vblank for ~30 fps).
- Face auth: **howdy-next 3.4.2** (C++, needs OpenCV ≥5: ALARM has opencv 5.0.0, yyjson, libinih; no dlib/Python). AUR PKGBUILD is `x86_64`-only: add aarch64. Alternatives blocked: visage (no `onnxruntime` in ALARM), howdy-git (no dlib). Not `linux-enable-ir-emitter` (UVC-only); not the fma965 plugin as-is.
- PAM: `auth sufficient pam_howdy.so` above `pam_unix`, never `required`; `workaround = off`. Order: **sudo and polkit first**, lock screen **last**, always with a root shell open.
- Lock screen: Omarchy 4.0 quattro uses the Quickshell lock with PAM services `omarchy-lock-password`/`omarchy-lock-fingerprint`; **omacom/omarchy #8336** (open) adds `omarchy-lock-face` + a howdy wizard and is the path to track (#5212 closed as its duplicate). On hyprlock: `ignore_empty_input=false` (#910, #562); #535 unlock-on-reload must be tested.

**Eye and thermal safety rule:** never leave the IR VCSEL on continuously at 700 mA. Keep the driver's duty-cycle cap and the PMIC safety timer; during channel discovery use low current and short flash timeouts only.

**On-device steps:**

1. ✅ `MSHW0472` confirmed (Phase 0). On Linux the probe must read model ID 0x53354730 (not 0x53354731 = VD55G1) and patch revision 0x1111 or 0x1120.
2. RGB camera first (proves CAMSS/CCI/CSIPHY).
3. **MCLK test:** build **four DTB variants** (MCLK0–3 = gpio96–99) plus a **no-clock** variant, each a separate boot entry. Boot each; `dmesg | grep -i vd55g` shows the ID (right pin) or an I2C NACK (next variant). No illuminator involved; only rails Windows uses.
4. Stream: `media-ctl` csiphy0 → csid0 → vfe0_rdi0, `Y8_1X8` 644×604 on every pad; `v4l2-ctl --stream-mmap --stream-count=30`. Watch CSIPHY settle and CSID errors.
5. **Find the illuminator channel:** start at 25 mA torch / 100 mA flash / 100 ms timeout, strobe `led-sources` 1–4 and watch through a **phone camera** (IR shows as a purple-white glow), never by eye. Then restore 700 mA / 1.28 s and add the re-fire patch.
6. Run the bridge, `howdy add` / `test` in dark and lit rooms, wire PAM (sudo → polkit → lock screen last), then abuse tests (reload mid-scan, lid close mid-scan).

**Prior art:** SP11 IR frames + illuminator shown working but unpublished (ooaklee #42, video); Zenbook A14 HM1092 on X1 CAMSS (same CCI0/csiphy0/GPIO109/MCLK0/PM8550 700 mA pattern, linux-media 2026-06-10); SP8/9 VD55G0 face unlock on Intel IPU6 (fildunsky).

**Risks:** kernel base (medium: no X1E CAMSS DT in mainline 7.3); MCLK source (medium); illuminator channel/strobe (medium); VANA 1.8 V vs ST's 2.8 V (low–medium, following Windows); driver (low, proven on SP8/9); userspace (low–medium); security (medium: IR liveness weaker than Windows Hello, #535-class bugs).

### Phase 6 — Upstreaming (continuous from Phase 2)

- **Omarchy:** x86 guard for `fix-surface-keyboard.sh`; SL7 hardware leaf (`install/hardware/microsoft/surface-laptop-7.sh`) plus a `platforms.json` entry in omarchy-iso; battery naming.
- **omarchy-pkgs:** shim two-owner fix (#222, if still needed), zap-in-`microsoft/` + DSP-in-`Romulus/` paths and `qcvss8380` in #221; report the same path bug to Debian `qcom-firmware-extract`.
- **ALARM:** SURFACE_* + IRIS config PR.
- **Kernel:** SCMI sustained-freq fix to LKML; test reports on spi-hid, the touchscreen patch and the CAMSS series.
- **dtbloader:** enable the SL7 MAC fixup.
- **linux-firmware:** SL7 board-2 entry.

**Exit (long-term):** the overlay is reduced to `linux-sl7` (until spi-hid lands), `sl7-firmware` and a `platforms.json` entry.

---

## 7. Build host

| Option | Pros | Cons |
|---|---|---|
| **ramius (x86 Omarchy desktop) + QEMU binfmt** (`qemu-user-static-binfmt`, ALARM container, `pacman --disable-sandbox` wrapper since Landlock fails under emulation) | local, fast iteration on small packages; private | full kernel builds under emulation take hours; ISO build slow; sandbox workaround |
| **GitHub `ubuntu-24.04-arm` runner** (native arm64; upstream dragon ISO workflow already uses it) | native speed; reproducible; reuses upstream `aarch64-build.yml`; artifacts downloadable | free only for **public** repos; private needs paid/self-hosted |
| Native on the SL7 itself | fastest native builds once Linux runs | chicken-and-egg for Phase 1; thermals on a fanless-ish laptop |

**Decided (2026-10-03):**

- **Public GitHub repo `qBitnaut/omarchy-dragon-sl7` + `ubuntu-24.04-arm` runners** for `linux-sl7` and ISO builds. `/mnt/Rocket4` has only 31 GB free, so full kernel/ISO builds never run there.
- **Cross-compile** the kernel on ramius (`ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-`) for fast patch iteration.
- **QEMU/binfmt** on ramius only for small `makepkg` packages.
- Once Phase 2 is done, the SL7 can build natively too.

A public repo is safe because no firmware is ever committed or published: only fetchers.

---

## 8. Risks, open questions, decisions

### Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Speaker damage | low (with guards) | high, irreversible | caps enforced + Pro Audio hidden + `sl7-doctor` check; never ship limit overrides |
| Kernel update leaves the system unbootable | medium | high | fallback kernel entry, `sl7-kernel-guard`, snapper, Phase 2 gate |
| Upstream `dragon` diverges or gets restructured (#13362 lifecycle dispatch) | high | medium | pin SHAs in `upstream.lock`; watch #13362, #11823; adopt `omarchy-lifecycle-dispatch` when it lands |
| spi-hid never lands, so a permanent out-of-tree touchpad | medium | medium | track dwhinham/ELLX rebases; the patch set is shared with SP11 users |
| Hyprland/aquamarine ABI skew on updates | high | medium | CI resolves the package set before publishing |
| Suspend drain / battery far below Windows | high | medium | Phase 4 ranked plan; set expectations (§5.2): ~60–70% of Windows running, ~2 days asleep vs ~a week |
| IR illuminator misuse (eye safety, heat) | low (with guards) | high | duty-cycle cap, PMIC safety timer, low-current discovery only |
| USB4 host-router driver slips past 7.6 | medium | medium | patch #14 fallback keeps docks usable; stretch port of glymur-usb4 |
| Face auth unlocks hyprlock unexpectedly (hyprlock #535) | medium | high | enable for sudo/polkit first; hyprlock only after the bug is verified fixed |
| Microsoft MSI URL/version changes | medium | low | fetcher scrapes the download page; accepts a user-supplied MSI/dir |
| Only a small group of maintainers on upstream dragon | medium | medium | upstream our fixes; be a tester on #11823 |
| Stock-kernel rescue has no internal keyboard | certain | low | keep a USB-C keyboard/hub on hand |
| SPI touchscreen on romulus13 has no ready DT (all prior work is 15") | medium | low | adapt ItsLucas/denislopt/nix1e from the SSDT `GTCH` resources; touch is not a v1 blocker |
| denislopt reports one unexplained freeze-reboot on the 15" build | unknown | medium | watch for it in Phase 2–3; capture ramoops |
| Build disk full (`/mnt/Rocket4` 97%) | high | low | CI builds; keep research `msi/tmp`, `msi/tools` deletable |

### Open questions (answered on hardware)

- Does the SL7 X Plus firmware report `sustained_freq_khz=0` (the SCMI patch is needed)?
- Does a specific romulus13 CHID match (not just the 5 shared generic ones)? (Consumer SKU 2036 confirmed, so expected yes; verify with `fwupdtool hwids` in Phase 0.5.)
- ~~Is the touchscreen on i2c0 or i2c8?~~ Resolved: Chris's unit is SPI `GTCH` (MSHW0460). Remaining: exact SPI bus/CS/IRQ from the SSDT vs the 15" DT; does the pen work?
- Does `fix-surface-keyboard.sh` actually fire (`lsmod | grep pinctrl_` in the live session)?
- Does battery reporting work without the `.jsn` files?
- Does the firmware honour the charge threshold?
- Does the keyboard backlight key work without the OS?
- Does SAM platform-profile appear under DT boot (the power-profiles-daemon backend)?
- IR camera: which MCLK (0–3 or none); does the VD55G0 ID read at cci0 0x10; which PM8550 flash channel drives the IR VCSEL, and HW or SW strobe?
- Does the ADSP honour the battmgr `low_capacity` trip (low-battery hibernate idea)?
- Is the PLD power ring populated on a cold Linux boot on romulus13?
- Which 10 cores are live (cluster layout 4/3/3?), for cluster parking.
- Does `cxsd` ever increment on 7.3 with the full PDC series?
- Does the panel EDID list 60 Hz, and does DPCD 0x070 advertise PSR?
- Surface Connect: charging, USB via `usb_mp`, dock display?

### Decisions

| # | Decision | Status |
|---|---|---|
| 1 | Dual-boot vs wipe | **Decided 2026-10-03: wipe**, after Phase 1 is proven on the unit |
| 2 | Public vs private GitHub repo | **Decided: public**, `qBitnaut/omarchy-dragon-sl7` (free arm64 CI; no blobs ever committed) |
| 3 | Channel | **Decided: edge** (the only channel with the aarch64 Omarchy runtime) |
| 4 | Reconnaissance boot before our ISO | **Decided: yes** (Phase 0.5) |
| 5 | Upstreaming appetite | open — recommended: guard/leaf PRs to Omarchy and the ALARM config PR, at minimum |

---

## 9. Sources

- **Omarchy**
  - https://github.com/omacom/omarchy (branches `quattro`, `dragon`; PRs #8672, #8673, #13362, #8039, #8151, #8336, #10232, #11025, #12733, #12956, #13029)
  - https://github.com/omacom/omarchy-iso (branch `dragon`, PR #129, #189, #192, `plans/aarch64-support.md`)
  - https://github.com/omacom/omarchy-pkgs (PRs #221, #222, #380)
  - https://github.com/omacom/omarchy-mac
  - https://pkgs.omarchy.org/edge/aarch64/omarchy.db
- **Omarchy discussions:** https://github.com/omacom/omarchy/discussions/11823, /13372, /12441 (Dell 7441, X1P-64-100), /10426, /7739
- **Community ports**
  - https://github.com/bprendie/omarchy-snapdragon
  - https://github.com/gilgm12/omarchy-iso/tree/aarch64-support (`docs/alarm-iso.md`)
  - https://github.com/alexisraitano-myffu/omarchy-arm
  - https://github.com/denislopt/omarchy-surface-laptop7
  - https://gist.github.com/cicorias/6da75542f9e2b4a7b6f58a61ba3979d6
- **SL7 kernels and patches**
  - https://github.com/ProgrammerIn-wonderland/ELLX-Kernel and https://public.hgci.org/software/ELLX/
  - https://github.com/bryce-hoehn/linux-surface-laptop-7
  - https://github.com/ItsLucas/surface-laptop-7-ubuntu-kernel
  - https://github.com/orvitpng/nix1e
  - https://github.com/linux-surface/linux-surface/issues/1590
  - https://github.com/valeronm/sl7-mac
- **Surface Pro 11 siblings**
  - https://github.com/dwhinham/linux-surface-pro-11
  - https://github.com/dwhinham/archiso-aarch64-sp11
  - https://github.com/denisix/ubuntu-surface-pro-11 (NPU.md, SENSORS.md, SUSPEND.md)
- **Mainline and systemd**
  - https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/qcom/x1e80100-microsoft-romulus.dtsi
  - https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/qcom/x1p64100-microsoft-denali.dts
  - https://github.com/torvalds/linux/blob/master/drivers/platform/surface/surface_aggregator_registry.c
  - https://github.com/systemd/systemd/tree/main/src/boot/hwids/aa64
- **Patch series**
  - touchscreen (I2C, TBID 2/3 units): https://ratatoskr.run/lkml/2026/09/17522699 (v1), v2 2026-09-30 (`platform/raw/lkml/` in the research folder)
  - QSPI/spi-hid (preferred): https://github.com/dwhinham/linux-sp11 branch `v7.2.8-arch1-sp11`
  - SPI touchscreen (15" templates): https://github.com/ItsLucas/surface-laptop-7-ubuntu-kernel, https://github.com/denislopt/omarchy-surface-laptop7, https://github.com/orvitpng/nix1e
  - CAMSS: https://lore.kernel.org/lkml/20260917-x1e-camss-csi2-phy-dtsi-v7-0-1a63eb35838b@linaro.org/
  - spi-hid: https://ratatoskr.run/linux-trace-kernel/2026/06/17106641/t
  - speaker caps: https://ratatoskr.run/linux-sound/2026/04/3524323/t
- **Boot:** https://github.com/TravMurav/dtbloader, https://github.com/TravMurav/slbounce, https://github.com/stephan-gh/qebspil, https://fedoraproject.org/wiki/Changes/Automatic_DTB_selection_for_aarch64_EFI_systems
- **Firmware:** https://www.microsoft.com/en-us/download/details.aspx?id=106120, https://salsa.debian.org/debian/qcom-firmware-extract, https://github.com/linux-msm/audioreach-topology
- **ALARM:** https://github.com/archlinuxarm/PKGBUILDs/blob/master/core/linux-aarch64/config, PKGBUILDs #2217, #2220; https://ports.archlinux.page/aarch64/
- **NPU:** https://github.com/qualcomm/fastrpc, https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/snapdragon/linux.md, https://onnxruntime.ai/docs/execution-providers/QNN-ExecutionProvider.html
- **Distros**
  - https://discourse.ubuntu.com/t/ubuntu-concept-snapdragon-x-elite/48800
  - https://bugs.launchpad.net/ubuntu-concept/+bug/2084951
  - https://www.phoronix.com/news/Ubuntu-26.10-Snapdragon-Concept
- **Specs:** https://learn.microsoft.com/en-us/surface/tech-specs/surface-laptop-snapdragon-tech-specs
- **Power**
  - Notebookcheck SL7 13.8" review: https://www.notebookcheck.net/Microsoft-Surface-Laptop-7-13-8-Copilot-review-Thanks-to-Snapdragon-X-Elite-finally-a-serious-MacBook-Air-competitor.857051.0.html
  - X Plus DRIPS fix (2026-08-02): https://mymce.wordpress.com/2026/08/02/surface-laptop-7-snapdragon-x-plus-not-entering-drips-how-i-fixed-modern-standby-battery-drain-_sb-ur15/
  - Windows adaptive hibernate: https://www.windowslatest.com/2026/08/08/windows-11-users-were-right-about-modern-standby-and-microsoft-is-fixing-it-with-hibernation/
  - `domain_ss3`: https://github.com/torvalds/linux/commit/95f827ceb21e2885f40eec5d93a340abbcc22d13
  - hotplug parking prior art: https://github.com/scuggo/x1e-nixos/tree/main/kernel/modules/cpu-parking
- **USB4**
  - PHY v5: https://patchwork.kernel.org/project/linux-arm-msm/cover/20260908-topic-usb4phy-v5-0-73aac69578ef@oss.qualcomm.com/
  - PHY v6 resend: https://patchwork.kernel.org/project/linux-arm-msm/patch/20260928-topic-usb4phy-v6-1-815a73b063ef@oss.qualcomm.com/
  - host-router RFC binding: https://patchwork.kernel.org/project/linux-usb/patch/20250916-topic-qcom_usb4_bindings-v1-1-943ecb2c0fa7@oss.qualcomm.com/
  - PCIe NHI opt-in: https://patchwork.kernel.org/project/linux-usb/patch/20260915-topic-tbt_pcie_optional-v1-1-47c4a3d129bd@oss.qualcomm.com/
  - ps883x dock fixes v5: https://patchwork.kernel.org/project/linux-arm-msm/cover/20260922-ps883x-disable-usb4-v5-0-02c0414978e6@oldschoolsolutions.biz/
  - Apple arm64 USB4 v2: https://patchwork.kernel.org/project/linux-usb/cover/20260906-b4-apple-soc-tbt-v2-0-1f80085f93fb@kernel.org/
  - SL8 bring-up driver: https://github.com/jdvmi00/glymur-usb4
  - X1P USB4 firmware RE: https://github.com/pir0c0pter0/fedora-vivobook-x1407q/blob/main/USB4-TB3-investigation.md
- **IR camera**
  - https://github.com/STMicroelectronics/vd55g0-linux-driver
  - https://github.com/linux-surface/kernel/pull/169 and https://ratatoskr.run/lkml/2026/09/17500801/t (petm5 vd55g)
  - https://github.com/petm5/vd55g-firmware
  - https://github.com/fildunsky/linux-surface-pro8-cameras
  - Zenbook A14 IR: https://ratatoskr.run/linux-media/2026/06/17114244/t
  - https://github.com/geocausa/SP11X1ECamera
  - https://github.com/ooaklee/linux-surface-pro-11-oe/issues/42
  - https://github.com/linux-surface/acpidumps
  - https://codeberg.org/nathawat/howdy-next
  - https://github.com/hyprwm/hyprlock/issues/910, https://github.com/hyprwm/hyprlock/issues/535, https://github.com/omacom/omarchy/pull/8336 (live face-unlock PR), https://github.com/omacom/omarchy/pull/5212 (closed)
- **Full source lists:** `*/SOURCES.md` in the research folder (see "Research" at the top).
