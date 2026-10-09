# Installer USB kit

Writes the Omarchy installer for the Surface Laptop 7 13.8" (model 2036) to a USB
stick. The ISO comes from the `installer-latest` release (built by `.github/workflows/installer-iso.yml`); this kit adds a
data partition `SL7DATA` with the Microsoft/Qualcomm firmware from your local MSI
extraction, so the firmware never reaches git or CI. The installer wipes the disk
you pick; this procedure does not keep Windows.

**Use at your own risk.** Unofficial, experimental community project, no warranty, not
affiliated with Microsoft, Qualcomm or Omarchy. The installer WIPES Windows and everything
on the internal SSD. Back up your data, save the BitLocker recovery key
(`tools/windows/Prepare-SL7.ps1`), keep the Surface driver MSI, and install all
Windows/Surface firmware updates first (they only arrive through Windows Update). The full
checklist is in the top-level README, Install section.

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

The default is the `installer-latest` release
(https://github.com/qBitnaut/omarchy-dragon-sl7/releases/tag/installer-latest), which
`installer-iso.yml` updates in place after every successful build on `main`. The ISO is larger
than GitHub's 2 GiB asset limit, so it is split into 1900 MiB parts
(`NAME.iso.part-00`, ...); `make-install-usb.sh --from-release` downloads them, checks
`NAME.iso.parts.sha256`, reassembles the ISO and checks `NAME.iso.sha256` (and its
signature, which must be a valid one by key `6387C619EF246F6F20C536B72C3331C78353BA04`; without it the
script aborts unless you pass `--insecure-skip-signature`). By hand: `cat NAME.iso.part-* > NAME.iso; sha256sum -c NAME.iso.sha256`.

The workflow takes the newest signed `linux-sl7`, `iptsd-sl7`, `libcamera-sl7`,
`howdy-next`, `sl7-ir-bridge` and `omarchy-sl7-faceunlock` from the non-expiring
`repo-aarch64` release (`upstream.lock` only holds minimum versions), and builds
`omarchy-surface-sl7` from the checkout. The CI artifact `omarchy-sl7-installer-iso`
(ISO and `.sha256`, 14 days) is still produced for `--from-ci`.

### From Windows

Write the ISO with Rufus (DD Image mode) or balenaEtcher, and fill a second, FAT32 stick
labelled `SL7DATA` with `tools/windows/Make-SL7DATA.ps1 -Drive E`. `sl7-firmware-stage.service`
looks for `LABEL=SL7DATA` on any block device (`/dev/disk/by-label`), so the firmware does
not have to be on the ISO stick. Steps in the top-level README, "From Windows".

## 2. Get the firmware

`tools/installer-kit/get-sl7-firmware.sh [--dir DIR] [--msi FILE]` downloads Microsoft's
public driver MSI, checks its sha256 against the known packages (the pins of
`omarchy-surface-sl7-firmware`), extracts it with `msiextract` (msitools) and writes `DIR/extracted/ProgramFiles64Folder/SurfaceUpdate`
and `DIR/SHA256SUMS.extracted`. `DIR` defaults to `$SL7_MSI`, else `./sl7-msi`. It runs on
any Linux machine or macOS, and nothing is read from Windows.

Microsoft replaces the driver MSI from time to time and the old URL then returns 404. The
script knows the current and the previous package (26.091.9400.0 and 26.053.36539.0; the
firmware files this kit uses are identical in both), tries the newest URL first and falls
back to the older one. If every URL fails, download the current Surface Laptop 7 driver MSI
from https://www.microsoft.com/download/details.aspx?id=106120 and pass it with `--msi FILE`;
it is accepted only if its sha256 is one of the known ones (`--help` lists them).
`--allow-unverified` accepts an unknown MSI but still requires every firmware file to
match its pinned hash.

The stick also carries the camera tuning file from that MSI (`camera/` on SL7DATA).
The live system hands it to the installer next to the firmware; on first boot of the
installed system `omarchy-surface-sl7-camera-stage.service` keeps it under
`/var/lib/omarchy-surface-sl7/camera/`, builds `/etc/libcamera/ipa/simple/ov02c10.yaml`
with `sl7-camera-tuning --if-missing --quiet` and deletes the staged copy. Nothing of
Microsoft's is in the ISO, the packages or the repository. Restart pipewire/wireplumber
(or log out and in) once to use it.

## 3. Write the stick

Packages on the build host (once): `sudo pacman -S --needed dosfstools mtools util-linux python github-cli`.

```
tools/installer-kit/make-install-usb.sh --device /dev/sdX                    # latest release ISO (--from-release)
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
