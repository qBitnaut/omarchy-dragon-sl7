<#
.SYNOPSIS
  Fill a USB stick labelled SL7DATA with the Surface Laptop 7 firmware, from Windows.
  This is the Windows counterpart of tools/installer-kit/get-sl7-firmware.sh plus the
  firmware step of make-install-usb.sh (omarchy-dragon-sl7).

.DESCRIPTION
  The Omarchy installer ISO contains no Microsoft or Qualcomm firmware. At boot the
  live system looks for a volume labelled SL7DATA (on any USB stick, not only the one
  the ISO was written to) and takes the firmware from it. Linux users get that volume
  from make-install-usb.sh; on Windows you write the ISO with Rufus or balenaEtcher
  and use this script for a SECOND, small stick.

  What it does:
   1. Takes the Surface Laptop 7 driver MSI (-Msi FILE) or downloads Microsoft's
      public one (the same URL and pin as get-sl7-firmware.sh) and checks its sha256.
   2. Unpacks it with "msiexec /a" (an administrative extract: nothing is installed
      and no system setting changes) into a temporary folder.
   3. Checks the six pinned firmware files against their sha256.
   4. Copies, onto the drive you name, exactly what make-install-usb.sh stages:
        firmware\qcom\x1e80100\microsoft\...   (zap shader, ADSP, CDSP, video)
        camera\com.surface.tuned.ffc_ov02c10.bin   (webcam tuning; optional)
        README.txt, installer-info.txt
      then re-reads the six firmware files from the stick and compares them.

  It never formats anything. The target must already be a FAT32 volume whose label is
  exactly SL7DATA, must not be the Windows drive, and is refused otherwise. Only the
  firmware\ and camera\ folders of that volume are replaced.

  The files are Microsoft/Qualcomm firmware for your own device. Do not share them.

  DISCLAIMER: unofficial, experimental community project, no warranty, use at your
  own risk, not affiliated with Microsoft, Qualcomm or Omarchy. Installing Linux with
  the installer ISO WIPES Windows and everything on the internal SSD. Back up your
  data and save your BitLocker recovery key first (Prepare-SL7.ps1 helps), and keep
  this MSI: the firmware comes from it. This script itself only writes to the
  SL7DATA stick you name.

  Needs Windows PowerShell 5.1 or later. Administrator rights are normally not
  needed. Read the script first, then:

    Set-ExecutionPolicy -Scope Process Bypass
    .\Make-SL7DATA.ps1 -Drive E
    .\Make-SL7DATA.ps1 -Drive E -Msi C:\Users\you\Downloads\SurfaceLaptop7_ARM_Win11_26100_26.091.9400.0.msi

  The execution policy change applies to this PowerShell window only.

.PARAMETER Drive
  Drive letter of the SL7DATA stick (E, E: and E:\ are all fine).

.PARAMETER Msi
  A Surface Laptop 7 driver MSI you already have. Without it the pinned MSI is
  downloaded to -WorkDir (about 1 GB; an interrupted download resumes when curl.exe
  is available, which Windows 10 and 11 include).

.PARAMETER WorkDir
  Scratch folder for the download and the extraction. Default: %TEMP%\sl7-msi.
  It is deleted at the end unless -KeepWork is given.

.PARAMETER AllowUnverified
  Continue when the MSI sha256 or a firmware file differs from the pin (a newer MSI).
  Not recommended: DSP firmware is signed and a wrong file only fails at boot.

.PARAMETER KeepWork
  Keep -WorkDir (the downloaded MSI and the extraction) after the copy.

.PARAMETER WhatIf
  Do everything except writing to the stick.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Drive,
    [string]$Msi,
    [string]$WorkDir = (Join-Path $env:TEMP 'sl7-msi'),
    [switch]$AllowUnverified,
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with a progress bar in 5.1

# Same pins as tools/installer-kit/get-sl7-firmware.sh and omarchy-surface-sl7-firmware.
# Known driver packages, newest first. Microsoft replaces the MSI under download id
# 106120 from time to time and the old URL then returns 404; the firmware files
# pinned below were identical in both packages. Fields: version, sha256, name.
$KnownMsis = @(
    @('26.091.9400.0', '0917d206fb35278b4df4be980240318475300f3a130a86edac836519059a453d', 'SurfaceLaptop7_ARM_Win11_26100_26.091.9400.0.msi'),
    @('26.053.36539.0', '66b6e1ace7e5f01bc592cd4c9ae78aa30bbb0e04ab57491cd03ec2aaa6e1229b', 'SurfaceLaptop7_ARM_Win11_26100_26.053.36539.0.msi')
)
$MsiBaseUrl = 'https://download.microsoft.com/download/b7ca2c3f-d320-4795-be0f-529a0117abb4'
$MsiPage = 'https://www.microsoft.com/download/details.aspx?id=106120'

# Source (below SurfaceUpdate\), destination (below firmware\ on SL7DATA), pinned sha256 or ''.
# Same list and destinations as stage_firmware in tools/lib/usb.sh.
$Rom = 'qcom/x1e80100/microsoft/Romulus'
$Files = @(
    @('qcdx8380/qcdxkmsuc8380.mbn', 'qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn', 'b526e365b644b019b4866d0eec9544de6aa61975a7ab7086af6ea4ee4f7ef8c7'),
    @('proextadsp8380/qcadsp8380.mbn', "$Rom/qcadsp8380.mbn", '3a0240f9a1c0c43b657959b1bf10433a1a9793eb5c4af9f6beff8644c174f5a0'),
    @('proextadsp8380/adsp_dtbs.elf', "$Rom/adsp_dtbs.elf", 'b03f066e2645dbe35a33a08a91312842f5cee3676cac3e111f1f3dabd1cf4e9e'),
    @('proextadsp8380/adspr.jsn', "$Rom/adspr.jsn", ''),
    @('proextadsp8380/adsps.jsn', "$Rom/adsps.jsn", ''),
    @('proextadsp8380/adspua.jsn', "$Rom/adspua.jsn", ''),
    @('proextadsp8380/battmgr.jsn', "$Rom/battmgr.jsn", ''),
    @('qcnspmcdmextcdsp8380/qccdsp8380.mbn', "$Rom/qccdsp8380.mbn", '4a67a03367f2eff2f8a0e867ca25d2bf2fcd5aee3e41e2c9f436c804e257c789'),
    @('qcnspmcdmextcdsp8380/cdsp_dtbs.elf', "$Rom/cdsp_dtbs.elf", '93941f040da14b8305d39579686d886706d22954a538b03da676c1aaa191797f'),
    @('qcnspmcdmextcdsp8380/cdspr.jsn', "$Rom/cdspr.jsn", ''),
    @('qcdx8380/qcvss8380.mbn', "$Rom/qcvss8380.mbn", '121d6864e5b8408f5c43d211f1634b59a6fb333c98c880cdbcd1bcb9f3c7e2f4')
)
$CameraName = 'com.surface.tuned.ffc_ov02c10.bin'

function Fail([string]$Message) {
    throw "Make-SL7DATA: $Message"
}

function Info([string]$Message) {
    Write-Host "==> $Message"
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-RelativePath([string]$Rel) {
    return $Rel.Replace('/', '\')
}

# ---------------------------------------------------------------- the target volume
$letter = $Drive.Trim().TrimEnd('\', ':').ToUpperInvariant()
if ($letter -notmatch '^[A-Z]$') {
    Fail "-Drive must be a single drive letter such as E (got '$Drive')."
}
$target = "${letter}:\"
$sysLetter = $env:SystemDrive.Substring(0, 1).ToUpperInvariant()
if ($letter -eq $sysLetter) {
    Fail "$target is the Windows system drive. Refusing."
}
$vol = $null
foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
    if ($d.Name.Substring(0, 1).ToUpperInvariant() -eq $letter) {
        $vol = $d
    }
}
if ($null -eq $vol -or -not $vol.IsReady) {
    Fail "$target is not a ready drive. Plug in the SL7DATA stick and check the letter in File Explorer."
}
if ($vol.VolumeLabel -cne 'SL7DATA') {
    $msg = "$target is labelled '{0}', not SL7DATA. Nothing was written. " -f $vol.VolumeLabel
    $msg += 'Rename the volume (File Explorer, right-click the drive, Rename) only if it really is the stick you mean to use.'
    Fail $msg
}
if ($vol.DriveFormat -ne 'FAT32') {
    $msg = "$target is {0}, not FAT32. The installer's live system is only tested with FAT32. " -f $vol.DriveFormat
    $msg += 'Reformat the stick yourself (right-click the drive, Format, File system FAT32, Volume label SL7DATA) and run this again; this script never formats.'
    Fail $msg
}
if ($vol.DriveType -ne 'Removable') {
    Write-Warning "$target is reported as '$($vol.DriveType)', not Removable. Some USB sticks and USB SSDs look like that; check that it is the right drive."
}
Info ("Target: {0} (label SL7DATA, FAT32, {1:N1} GB free)" -f $target, ($vol.AvailableFreeSpace / 1GB))
if ($vol.AvailableFreeSpace -lt 200MB) {
    Fail "less than 200 MB free on $target."
}

# ---------------------------------------------------------------- 1. the MSI
if (-not (Test-Path -LiteralPath $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir | Out-Null
}
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path

if ($Msi) {
    if (-not (Test-Path -LiteralPath $Msi -PathType Leaf)) {
        Fail "$Msi not found."
    }
    $msiPath = (Resolve-Path -LiteralPath $Msi).Path
}
else {
    $msiPath = $null
    foreach ($k in $KnownMsis) {
        $cand = Join-Path $WorkDir $k[2]
        if ((Test-Path -LiteralPath $cand) -and ((Get-Sha256 $cand) -eq $k[1])) {
            Info "MSI already downloaded and verified: $cand"
            $msiPath = $cand
            break
        }
    }
    if ($null -eq $msiPath) {
        foreach ($k in $KnownMsis) {
            $cand = Join-Path $WorkDir $k[2]
            if (Test-Path -LiteralPath $cand) {
                # A complete file with the wrong hash is not a partial download.
                Move-Item -LiteralPath $cand -Destination "$cand.part" -Force
            }
            Info "Downloading $($k[2]) (about 1 GB; run the script again if it is interrupted)"
            $part = "$cand.part"
            $url = "$MsiBaseUrl/$($k[2])"
            $ok = $false
            $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
            if ($curl) {
                & $curl.Source -fL --retry 3 -C - -o $part $url
                $ok = ($LASTEXITCODE -eq 0)
            }
            else {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                try {
                    Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing
                    $ok = $true
                }
                catch {
                    $ok = $false
                }
            }
            if ($ok) {
                Move-Item -LiteralPath $part -Destination $cand -Force
                $msiPath = $cand
                break
            }
            Write-Warning "not available (Microsoft may have replaced it): $url; trying the next known package."
        }
        if ($null -eq $msiPath) {
            Fail "no known MSI could be downloaded. Microsoft has probably replaced the package again. Download the current Surface Laptop 7 driver MSI from $MsiPage and run this again with -Msi FILE (it must match a known sha256, or add -AllowUnverified)."
        }
    }
}

# ---------------------------------------------------------------- 2. verify
Info 'Verifying the MSI sha256'
$got = Get-Sha256 $msiPath
$known = $KnownMsis | Where-Object { $_[1] -eq $got } | Select-Object -First 1
if ($null -ne $known) {
    Write-Host "    sha256 OK: $got (MSI $($known[0]))"
}
elseif ($AllowUnverified) {
    Write-Warning "sha256 $got matches no known MSI; continuing because of -AllowUnverified (the firmware files are still checked)."
}
else {
    $list = ($KnownMsis | ForEach-Object { "$($_[0]) $($_[1])" }) -join '; '
    Fail "sha256 mismatch for ${msiPath}: got $got, which is none of the known MSIs ($list). Delete the file and retry, or use -AllowUnverified for a newer MSI."
}

# ---------------------------------------------------------------- 3. extract
$ext = Join-Path $WorkDir 'extract'
if (Test-Path -LiteralPath $ext) {
    Remove-Item -LiteralPath $ext -Recurse -Force
}
New-Item -ItemType Directory -Path $ext | Out-Null
Info 'Extracting with msiexec /a (administrative extract: nothing is installed)'
$msiArgs = '/a "{0}" /qn TARGETDIR="{1}"' -f $msiPath, $ext
$proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    Fail "msiexec failed with exit code $($proc.ExitCode). Run this script again from a PowerShell opened as administrator; if it still fails, extract on Linux with get-sl7-firmware.sh."
}
$fwDir = Get-ChildItem -LiteralPath $ext -Recurse -Directory -Filter 'SurfaceUpdate' | Select-Object -First 1
if ($null -eq $fwDir) {
    Fail 'no SurfaceUpdate folder in the MSI; is this the Surface Laptop 7 driver package?'
}
$fwBase = $fwDir.FullName

# ---------------------------------------------------------------- 4. check the result
Info 'Checking the firmware files the installer needs'
$bad = $false
foreach ($f in $Files) {
    $src = Join-Path $fwBase (Get-RelativePath $f[0])
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        Write-Host "    MISSING  $($f[0])" -ForegroundColor Red
        $bad = $true
    }
    elseif ($f[2] -ne '' -and (Get-Sha256 $src) -ne $f[2]) {
        Write-Host "    DIFFERS  $($f[0]) (not the pinned file)" -ForegroundColor Red
        if (-not $AllowUnverified) {
            $bad = $true
        }
    }
    else {
        Write-Host "    ok       $($f[0])"
    }
}
if ($bad) {
    Fail 'required firmware files are missing or differ from the pin; do not use this extraction.'
}
$camSrc = Get-ChildItem -LiteralPath $fwBase -Recurse -File -Filter $CameraName | Select-Object -First 1

# ---------------------------------------------------------------- 5. write
Info "Writing to $target (firmware\ and camera\ on the stick are replaced)"
if ($PSCmdlet.ShouldProcess($target, 'replace firmware\ and camera\ and write README.txt, installer-info.txt')) {
    foreach ($dir in @('firmware', 'camera')) {
        $p = Join-Path $target $dir
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Recurse -Force
        }
    }
    foreach ($f in $Files) {
        $dst = Join-Path (Join-Path $target 'firmware') (Get-RelativePath $f[1])
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath (Join-Path $fwBase (Get-RelativePath $f[0])) -Destination $dst
    }
    if ($null -ne $camSrc) {
        New-Item -ItemType Directory -Force -Path (Join-Path $target 'camera') | Out-Null
        Copy-Item -LiteralPath $camSrc.FullName -Destination (Join-Path $target 'camera')
        Write-Host '    camera tuning staged (webcam colour tuning is built from it on first boot)'
    }
    else {
        Write-Warning 'no camera tuning file in the MSI; the webcam stays untuned until you run sl7-camera-tuning.'
    }

    $readme = @(
        'SL7DATA - Surface Laptop 7 Omarchy firmware stick (omarchy-dragon-sl7)',
        '========================================================================',
        '',
        "The installer's live system mounts this volume read-only at boot",
        '(sl7-firmware-stage.service) and passes firmware/ to qcom-firmware-extract, which',
        'stages the files the device tree asks for (GPU zap shader, ADSP, CDSP) and the',
        'installer copies them into the new system.',
        '',
        'PRIVACY AND LICENSE',
        '-------------------',
        "camera/ holds Microsoft's camera tuning file from the same package. The installed",
        "system builds the webcam's libcamera tuning from it at first boot and then deletes",
        'this staged copy.',
        '',
        'firmware/ contains Microsoft/Qualcomm firmware extracted from the Surface',
        'driver package. It is for your personal use on your own device only. Do NOT',
        "share, upload or copy this stick's firmware/ directory anywhere, and do not",
        'make an image of this stick public.'
    )
    $info = @(
        'iso: (not on this volume; written separately with Rufus or balenaEtcher)',
        "msi: $(Split-Path -Leaf $msiPath)",
        "msi sha256: $got",
        'firmware: included (written by tools/windows/Make-SL7DATA.ps1)'
    )
    # LF line endings and no BOM, as the Linux kit writes them.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $target 'README.txt'), (($readme -join "`n") + "`n"), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $target 'installer-info.txt'), (($info -join "`n") + "`n"), $utf8)

    # ------------------------------------------------------------ 6. verify the stick
    Info 'Verifying the files on the stick'
    $fail = $false
    foreach ($f in $Files) {
        $dst = Join-Path (Join-Path $target 'firmware') (Get-RelativePath $f[1])
        $src = Join-Path $fwBase (Get-RelativePath $f[0])
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf) -or (Get-Sha256 $dst) -ne (Get-Sha256 $src)) {
            Write-Host "    BAD      $($f[1])" -ForegroundColor Red
            $fail = $true
        }
    }
    if ($fail) {
        Fail "the copy on $target does not match the source; try again, or use another stick."
    }
    Write-Host '    all firmware files match the source'
    Get-ChildItem -LiteralPath $target -Recurse -File | ForEach-Object {
        Write-Host ('    ' + $_.FullName.Substring($target.Length).Replace('\', '/'))
    }
}

# ---------------------------------------------------------------- done
if (-not $KeepWork) {
    Remove-Item -LiteralPath $ext -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $Msi) {
        Write-Host "    kept the downloaded MSI at $msiPath (delete it when you are done)"
    }
}
Write-Host ''
Write-Host "Done. Eject the stick ('Safely remove hardware') before unplugging it."
Write-Host 'WARNING: these files are Microsoft/Qualcomm firmware for your own device.'
Write-Host '         Do not share or upload them, or an image of this stick.'
Write-Host ''
Write-Host 'Next: plug BOTH sticks into the Surface (the installer ISO stick and this SL7DATA stick).'
