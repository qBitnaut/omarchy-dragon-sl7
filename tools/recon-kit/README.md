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
(override with `SL7_WORK`), never in `/tmp` or the repo. Needs about 4 GB.

Test without hardware: `make-recon-usb.sh --image FILE [--size 8G] --no-firmware`
writes the same layout into an image file with no root needed (`--loop` attaches it
with `losetup -P` instead, to exercise the device code path). `--build-only` stops
after the remaster.

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
