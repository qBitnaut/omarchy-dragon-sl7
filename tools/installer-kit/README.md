# Installer USB kit

Writes the Omarchy installer for the Surface Laptop 7 13.8" (model 2036) to a USB
stick. The ISO comes from CI (`.github/workflows/installer-iso.yml`); this kit adds a
data partition `SL7DATA` with the Microsoft/Qualcomm firmware from your local MSI
extraction, so the firmware never reaches git or CI. The installer wipes the disk
you pick; this procedure does not keep Windows.

Status: the pipeline is built and checked on the build host (scripts, patches,
image-mode runs). A full ISO build and a boot on the SL7 are not verified yet.

## What is on the stick

| Part | Content |
|---|---|
| ISO (partitions 1 and 2) | Omarchy `dragon` installer for `aarch64/snapdragon` with the `linux-sl7` kernel, a live UKI carrying the Qualcomm device trees (`.dtbauto` romulus13/15 picked by SMBIOS), the SAM keyboard modules in the live initramfs, and an offline mirror holding `linux-sl7`, `omarchy-surface-sl7`, `iptsd-sl7`, `qcom-firmware-extract` and the pkgbase shim. No firmware. |
| `SL7DATA` (partition 3, FAT32, type Microsoft basic data) | `firmware/qcom/x1e80100/microsoft/...` (zap shader, ADSP, CDSP, Iris video), `README.txt`, `installer-info.txt` |

At boot `sl7-firmware-stage.service` mounts `LABEL=SL7DATA` read-only, runs
`qcom-firmware-extract --stage /run/omarchy/firmware -d /run/sl7data/firmware`
and unmounts. The installer's own stage step then reports "already staged" and copies
the files into the new system, where `omarchy-surface-sl7` and Omarchy's
`qualcomm/firmware.sh` install them. Without `SL7DATA` (or with `--no-firmware`)
the service does nothing and the installer scans for a Windows driver store instead,
which is gone after the disk is wiped.

## 1. Get the ISO

Push to `installer/**` or `upstream.lock`, or run the workflow by hand
(`gh workflow run installer-iso.yml`). The artifact `omarchy-sl7-installer-iso`
holds the ISO and its `.sha256`; it expires after 14 days. The linux-sl7 artifact it
consumes (run id in `upstream.lock`) expires after 14 days too: re-run `linux-sl7.yml`
and update `LINUX_SL7_RUN_ID` when the workflow's download step fails.

## 2. Get the firmware

`tools/installer-kit/get-sl7-firmware.sh [--dir DIR] [--msi FILE]` downloads Microsoft's
public driver MSI, checks its pinned sha256 (the pin of `omarchy-surface-sl7-firmware`),
extracts it with `msiextract` (msitools) and writes `DIR/extracted/ProgramFiles64Folder/SurfaceUpdate`
and `DIR/SHA256SUMS.extracted`. `DIR` defaults to `$SL7_MSI`, else `./sl7-msi`. It runs on
any Linux machine or macOS, and nothing is read from Windows.

## 3. Write the stick

Packages on the build host (once): `sudo pacman -S --needed dosfstools mtools util-linux python github-cli`.

```
tools/installer-kit/make-install-usb.sh --device /dev/sdX --from-ci RUNID    # or "latest"
tools/installer-kit/make-install-usb.sh --device /dev/sdX --iso FILE         # FILE.sha256 next to it, or --sha256 HEX
tools/installer-kit/make-install-usb.sh --device /dev/sdX --from-ci RUNID --no-firmware
```

Use a stick of 16 GB or more. Run it as yourself, not with `sudo`; it calls `sudo`
only for the write steps. Check the device with `lsblk -o NAME,MODEL,SIZE,TRAN,RM`.
The script verifies the ISO's sha256, refuses anything that is not removable/USB,
anything holding `/` or `/boot`, and anything over 256 GB (`--force-large`
overrides), shows model and size and makes you type the device path. Then it
unmounts the stick's partitions, wipes old signatures, runs
`dd bs=4M conv=fsync oflag=direct`, compares the written bytes with the ISO,
relocates the backup GPT, adds `SL7DATA`, copies `firmware/` from the local MSI
extraction (`$SL7_MSI`, default `.../Research/omarchy-dragon-sl7/msi`, checked against
`SHA256SUMS.extracted`), verifies, syncs and unmounts. It ends with
"Installer stick ready".

Work files live in `$SL7_WORK` (default `.../Research/omarchy-dragon-sl7/installer/work/kit`),
never in `/tmp` or the repo.

Test without hardware: `make-install-usb.sh --image FILE --iso ISO [--size 8G]` writes
the same layout into an image file with no root needed (`--loop` uses `losetup -P`).

The stick holds Microsoft/Qualcomm firmware for your own device: do not share it,
its `firmware/` directory or an image of it.

## 4. Install on the SL7

1. Power off. Hold Volume Up while pressing Power to enter the Surface UEFI.
   **Security > Secure Boot: None.** (If Windows is still on the disk and uses
   BitLocker, pausing BitLocker does not matter: the installer wipes the disk.)
2. Plug the stick into the **USB-A port**. The live image keeps the Qualcomm DSP
   driver off (`modprobe.blacklist=qcom_q6v5_pas`) because starting it resets USB-C
   and drops a USB-C boot stick; USB-A avoids that. Stay on AC power.
3. Boot from the stick: Volume Down while pressing Power, or choose it in the UEFI
   boot menu. GRUB shows no menu (timeout 0) and chainloads the live UKI. Expect a
   black screen for a minute or two while the display driver and firmware settle.
4. In the installer's disk picker choose the **internal NVMe, not the stick**. The
   stick shows up as a USB disk; picking it would wipe the installer.
5. Set a LUKS passphrase when asked. On the first boots the unlock prompt may be
   blank (no text visible): type the passphrase blind and press Enter. The built-in
   keyboard works at the prompt through the SAM modules in the initramfs; a USB
   keyboard is the fallback.
6. Let the install finish and reboot without the stick. First boot should land in
   `linux-sl7` (`omarchy-surface-sl7` puts it first in the Limine boot order); the
   stock `linux-aarch64` entry stays as the rescue kernel and has no internal
   keyboard. Check with `uname -r` (contains `sl7`) and `sl7-doctor`.

## Troubleshooting

- **The stick boots but the installer finds no firmware:** `journalctl -u sl7-firmware-stage`
  on the live system; `lsblk -o NAME,LABEL` should show `SL7DATA`; run
  `sudo systemctl restart sl7-firmware-stage` after plugging the stick in properly.
- **`qcom-firmware-extract` stages fewer files than expected:** `qcom-firmware-extract --list-missing`
  lists the names the device tree asks for; non-device-tree files (Iris, `.jsn` extras) are not covered.
- **No keyboard in the installer:** use a USB keyboard and report the live `dmesg | grep -i surface`.
- **GPU or display black for minutes:** wait; if it never comes up, boot the recon
  stick (`tools/recon-kit`) to compare.
