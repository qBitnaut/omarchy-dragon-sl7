# Recon USB kit

A guided USB stick that boots the Surface Laptop 7 13.8" (model 2036, X1P-64-100)
into a live Arch aarch64 system, walks Chris through hardware checks, and saves
the results back to the stick. It is Phase 0.5 of `PLAN.md`: measure first, build
later. The internal disk is never touched.

## What is in the kit

| File | Role |
|---|---|
| `make-recon-usb.sh` | Runs on ramius. Downloads and verifies the ISO, remasters it, writes the stick, adds and fills the `SL7DATA` partition. |
| `sl7-guide.sh` | Runs on the SL7 as root. The step-by-step wizard (whiptail, or plain prompts). |
| `../sl7-recon.sh` | Read-only hardware report, called twice by the guide. |

Base image: `dwhinham/archiso-aarch64-sp11` release 2026-09-26
(`archlinux-sp11-2026.09.26-aarch64.iso`, sha256 `388ebc2e...ccacccb3bb`, checked on
every build; a mismatch aborts).

## Build the stick

Packages on ramius (once): `sudo pacman -S --needed libisoburn dosfstools mtools`
(`util-linux`, `curl`, `python` are already there).

```
tools/recon-kit/make-recon-usb.sh --device /dev/sdX            # with firmware
tools/recon-kit/make-recon-usb.sh --device /dev/sdX --no-firmware
```

Run it as yourself, not with `sudo`; the script calls `sudo` only for the write step.
Check the device with `lsblk -o NAME,MODEL,SIZE,TRAN,RM`. The script refuses anything
that is not removable/USB, anything holding `/` or `/boot`, and anything over 256 GB
(`--force-large` overrides). It shows model and size and makes you type the device
path. It unmounts the stick's auto-mounted partitions, runs
`dd bs=4M conv=fsync oflag=direct`, adds partition 3 (`SL7DATA`, FAT32) in the free
space and fills it.

Work files (ISO, remaster, staging) live in
`/mnt/Rocket4/Quadrant/Personal/Research/omarchy-dragon-sl7/recon/work/`
(override with `SL7_WORK`), never in `/tmp` or the repo. Needs about 4 GB (about 6 GB with the test kernel).

Test without hardware: `make-recon-usb.sh --image FILE [--size 8G] --no-firmware`
writes the same layout into an image file with no root needed (`--loop` attaches it
with `losetup -P` instead, to exercise the device code path). `--build-only` stops
after the remaster and staging.

### How the remaster works

Only two things change, and the kernel UKI (stubble plus DTBs), initramfs,
`airootfs.sfs` and its checksum stay byte-identical:

1. `/sl7-autostart.sh` is added to the ISO9660 tree (mounted at
   `/run/archiso/bootmnt`).
2. ` copytoram=n script=/run/archiso/bootmnt/sl7-autostart.sh` is appended to the `options` line
   of both systemd-boot loader entries, in the ISO tree and in the appended ESP.

`copytoram=n` is needed because with the default `copytoram=auto` the initramfs copies
the rootfs to RAM and unmounts the ISO partition before login, so the `script=` path
would disappear (found in the QEMU test). archiso's `.automated_script.sh` runs that
`script=` file on the tty1 root autologin.
It waits up to 45 s for `/dev/disk/by-label/SL7DATA`, mounts it read-write at `/sl7`
and starts `/sl7/sl7-guide.sh`. If the partition is missing it prints instructions.
The build verifies that partition types, the ISO UUID, the kernel UKI, the initramfs
and the EFI binaries are unchanged. The ISO is rebuilt with xorriso replaying the
original El Torito, GPT and appended-ESP boot records.

Manual fallback on the SL7 (if the hook does not fire):
`sh /run/archiso/bootmnt/sl7-autostart.sh`, or
`mkdir -p /sl7; mount /dev/<SL7DATA partition> /sl7; bash /sl7/sl7-guide.sh`.

## What Chris will see

Boot the SL7 from the stick (Volume Down while powering on, or the UEFI boot menu;
Secure Boot off). Expect the systemd-boot menu for 15 s, then a possibly black screen
for 2-3 minutes while msm and firmware settle, then the guide on tty1:

1. Welcome and safety summary (stay on AC, read-only for the internal disk).
2. Identity check with pass/fail marks against model 2036 and `microsoft,romulus13`
   (no serial number or MAC is shown). The marks are `[OK]`/`[!!]` on the Linux
   console and a check mark / cross elsewhere.
3. Baseline `sl7-recon.sh` into `results/<ts>-baseline/`.
4. Optional: load firmware into RAM (`/lib/firmware/updates`), start the ADSP and CDSP
   via sysfs when their firmware exists, report battery and DSP state. The ADSP start
   can reset USB-C and briefly drop the stick; the guide runs from RAM and remounts
   `SL7DATA` when it returns. An optional GPU re-probe (default No) is offered.
5. `sl7-recon.sh` again into `results/<ts>-with-firmware/`.
6. Interactive checks, each recorded in `results/answers.txt`: built-in keyboard,
   touchpad, touchscreen, lid switch (20 s, suspend blocked meanwhile), keyboard
   backlight key, charger plug and unplug, USB-C display.
7. Optional suspend test (default No, needs the firmware step to have worked): the
   SL7 has no RTC alarm, so Chris presses the power button after about 2 minutes.
   qcom_stats and battery energy are captured before and after.
8. Summary, then `poweroff` (not `reboot`), then bring the stick back to ramius.

The guide is resumable: run it again and it offers to continue the last session.
Everything is logged to `results/<ts>/guide.log`. It never writes EFI variables and
never touches disks, regulators, LEDs or rfkill.

## Test kernel (linux-sl7) from the same stick

The same stick can also boot our `linux-sl7` kernel without installing anything. The
archlinux-sp11 entries stay untouched as control and fallback; two entries are added:

| Menu entry | What it tests |
|---|---|
| `omarchy-dragon-sl7 test kernel` | systemd-stub UKI: our `Image`, `.dtbauto` for romulus13 and romulus15, `.hwids`. The device tree is chosen from SMBIOS, which is Omarchy's real path. |
| `omarchy-dragon-sl7 test kernel (explicit romulus13 devicetree, no UKI)` | Raw `Image` plus a `devicetree` line in the entry. Fallback if the `.hwids` match misbehaves. |

The default entry stays the sp11 one (control); pick ours in the menu within 15 s. Press
`e` in the menu to edit the command line (for example to drop `clk_ignore_unused`).

```
tools/recon-kit/make-recon-usb.sh --device /dev/sdX --from-ci latest --iptsd-from-ci latest
tools/recon-kit/make-recon-usb.sh --device /dev/sdX --kernel-artifacts DIR --iptsd-pkg FILE
```

`--from-ci RUN` runs `gh run download RUN --pattern 'linux-sl7-*'` into
`$SL7_WORK/ci/linux-sl7` (run id, or `latest` for the newest successful `linux-sl7.yml`
run; artifacts expire after 14 days). `--iptsd-from-ci RUN` does the same for
`iptsd-sl7-aarch64`. The build verifies `SHA256SUMS` and refuses firmware-looking files
in the artifacts.

### Design choices

| | Question | Choice and why |
|---|---|---|
| a | Initramfs for our kernel | Reuse the sp11 archiso initramfs and add to it; do not rebuild. Its init, hooks, busybox and udev are aarch64 binaries; mkinitcpio cannot assemble them on x86, Arch Linux ARM has no `archiso` package, and a CI step would still need the hooks from somewhere. cpio concatenation is architecture independent. The sp11 image is an uncompressed early cpio (sp11 modules and firmware, 206 MB) followed by one xz cpio. The result is: early cpio, then our overlay cpio (modules, zap shader), then the original main cpio with a small cpio appended in the same xz member (`/config` with `sl7test` added to `LATEHOOKS`, and `/hooks/sl7test`). No CI change is needed. |
| b | Modules in the live root | The package's modules are compressed with zstd, `depmod`'ed on ramius (`modules.dep.bin` is not in the package) and packed into the overlay, so the initramfs can load `msm`, `qcom_q6v5_pas` and the rest of the sp11 `MODULES=` list. The late hook runs after archiso mounts the root at `/sysroot`: it mounts a tmpfs on `/sysroot/usr/lib/modules/<ver>` and copies the tree there (a separate tmpfs, so the 256 MB cow overlay stays free). Userspace modules only depend on the kernel, so the Arch Ports root is fine. |
| c | Zap shader at boot | Only `qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn` goes into the overlay and, through the hook, into the live root. `msm` loads from the initramfs, but run 1 shows the GPU firmware being requested at first use (17 s, after switch_root), so the live-root copy is the one that counts; the initramfs copy covers an early probe. It comes from the local SL7DATA stage at stick-build time, never from git or CI. The other firmware stays out of the initramfs on purpose: an ADSP started during boot resets USB-C and can drop the root stick; the guide still starts it later from RAM. |
| d | Device tree | Both: the UKI (`ukify` with the systemd-stub, hwids and `pefile` from the ISO's own live root, systemd 262) and the explicit `devicetree` entry. The UKI carries the command line in `.cmdline`; the initramfs is passed by the loader (`initrd` line), which systemd-stub forwards. |
| e | Where the files live | The ISO's ESP is 270 MB with about 8 MB free (`vmlinuz-linux-sp11` 49 MB plus the 223 MB initramfs), so nothing fits there. systemd-boot only reads the ESP and an XBOOTLDR partition, so SL7DATA is created with the XBOOTLDR type GUID instead of basic data and holds `loader/entries/`, `sl7boot/` and `sl7test/`. Linux ignores the type GUID; the label mount works unchanged (checked in QEMU). With that type, `systemd-gpt-auto-generator` could automount SL7DATA at `/boot` as a second mount of the same FAT, so the test-kernel build adds `systemd.gpt_auto=0` to every entry. Without `--kernel-artifacts` the partition stays basic data. |

### Added to SL7DATA

`loader/entries/20-*.conf`, `21-*.conf`; `sl7boot/` (`omarchy-dragon-sl7.efi`, `Image`,
`initramfs-sl7-archiso.img`, the romulus13 and romulus15 DTBs); `sl7test/`
(`iptsd-sl7.pkg.tar.zst`, `kernel-info.txt`). About 0.5 GB on top of the firmware; the
build checks that the partition has room. The boot files are rebuilt only when an input
changes (`$SL7_WORK/kernel-build`, stamped).

### Extra checks in the guide

On our kernel (`uname -r` contains `sl7`) the guide adds one step after the firmware
step. Each result goes to `results/answers.txt` as `sl7_*` and to
`results/<ts>-sl7kernel/`.

| Check | Pass when |
|---|---|
| cpufreq | three `policy*` directories (SCMI sustained-frequency fix; the sp11 kernel has one); policy leaders, governor and current frequency are listed, plus the `sustained` kernel log lines |
| SPI | `spi19.0` (touchpad) and `spi10.0` (touchscreen) exist and have a driver bound; a `045E:0C77` hidraw node exists |
| GPU | a DRM card and render node exist and the log has no `Unable to load ...qcdxkmsuc8380.mbn` / `gpu hw init failed` |
| Battery | a `capacity` attribute exists (needs the firmware step to have started the ADSP) |
| Wi-Fi | an ath12k interface exists, rfkill is not blocked, and a scan finds access points (count only) |
| Touchpad | the package from `sl7test/` is unpacked into a temp root, its `iptsd` runs on the touchpad hidraw node and creates "IPTSD Virtual Touchpad"; Chris moves, taps/clicks and scrolls |
| Touchscreen | input events from the direct-touch device |
| After suspend | hidraw and iptsd still there, touchpad events again, GPU, battery and Wi-Fi re-checked |

If the ALARM-built `iptsd` cannot run in the Arch Ports live root (library versions), the
guide records `skip` and offers `pacman -S fmt libinih spdlog` (live RAM root only, needs
network). Everything is read-only apart from that daemon and `ip link set up` on the
Wi-Fi interface; no driver is unbound, nothing is written to disks, EFI variables,
regulators, LEDs or rfkill.

### What was verified

Without a successful `linux-sl7` run yet, the build was run in `--image` mode against a
fake artifact directory (sp11 kernel, sp11 DTBs and a handful of sp11 modules renamed to
`7.2.8-1-sl7`). It produced the GPT (partition 3 type `BC13C2FF-...`), both entries, the
UKI (two `.dtbauto`, `.hwids`), and verified the files on the image. QEMU booted both the
default sp11 entry (SL7DATA found by label, mounted at `/sl7`) and the UKI entry (the
`sl7test` late hook ran, so the concatenated initramfs, the UKI and the loader-supplied
initrd all work). Not testable without the hardware: our real kernel, the explicit
`devicetree` entry, `.hwids` selection on the SL7 and XBOOTLDR discovery by the SL7's
firmware.

## Privacy and firmware

- `SL7DATA/firmware/` holds Microsoft/Qualcomm firmware copied from the local MSI
  extraction (`msi/extracted`, see `msi/FIRMWARE-INDEX.md`; checked against
  `SHA256SUMS.extracted`). It is for personal use on Chris's own device only.
  Do not share the stick, an image of it, or that directory. `--no-firmware` skips it.
- The ISO and firmware stay out of git; the repo only holds these scripts.
- `results/*/private/` (from `sl7-recon.sh`) contains the serial number. Other files
  have MACs and serial redacted. Review before publishing anything from `results/`.

## Checking the stick in QEMU (optional)

`qemu-system-aarch64` with edk2-aarch64 (`QEMU_EFI.fd`, padded to 64 MiB for pflash)
boots the image: `-M virt,gic-version=3 -cpu max -m 4G`, a virtio-blk drive, `-device
ramfb`, and a serial socket. The SL7 DTB does not match, so stubble leaves the QEMU
device tree in place and the kernel boots normally.
