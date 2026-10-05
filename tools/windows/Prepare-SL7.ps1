<#
.SYNOPSIS
  Check a Surface Laptop 7 before installing Omarchy (omarchy-dragon-sl7). Run it on
  the SL7 under Windows, BEFORE installing Linux.

.DESCRIPTION
  This script is read-mostly. It changes no system setting. The one step that writes
  anything (the BitLocker recovery key, to a USB drive you choose) asks first, and
  -WhatIf shows what it would do without doing it. It collects no data for anyone
  else and has no network access: nothing is uploaded or sent.

  Linux needs nothing captured from Windows. The firmware comes from Microsoft's public
  driver MSI (tools/installer-kit/get-sl7-firmware.sh), and the Wi-Fi and Bluetooth MAC
  addresses are read from the UEFI at every boot.

  Steps:
   1. Model check. Reads Win32_ComputerSystem (model, SKU) and Win32_Processor and
      reports whether this is a Surface Laptop 7, which CPU (Snapdragon X Plus or X
      Elite) and how much RAM it has, so you know what the project supports.
   2. BitLocker. Shows the status of the system drive (manage-bde) and offers to save
      the recovery key text (manage-bde -protectors -get) to a file on removable
      media. This protects your data. The script never suspends or disables BitLocker;
      that is needed only if you keep Windows (dual boot). The installer wipes the
      disk you pick, so a wipe-and-install does not need it.
   3. UEFI version and Secure Boot. Records the firmware version (Win32_BIOS) and the
      Secure Boot state (Confirm-SecureBootUEFI), and prints how to turn Secure Boot
      off in the Surface UEFI (hold Volume Up, press Power).
   4. Summary and next steps.

  Run it in an administrator PowerShell (BitLocker and Secure Boot need it; without it
  those steps are skipped with a warning). Read it first, then:

    Set-ExecutionPolicy -Scope Process Bypass; .\Prepare-SL7.ps1
    Set-ExecutionPolicy -Scope Process Bypass; .\Prepare-SL7.ps1 -WhatIf

  The execution policy change applies to this PowerShell window only.

.PARAMETER WhatIf
  Dry run. Reads and reports, asks no questions, and writes nothing. (A plain switch,
  also available as -DryRun.)

.PARAMETER OutDir
  Folder to save the recovery key into, instead of asking for a USB drive.

.NOTES
  Compatible with Windows PowerShell 5.1 and PowerShell 7. Output is ASCII only.
  Install guide: https://github.com/qBitnaut/omarchy-dragon-sl7#install
#>
[CmdletBinding()]
param(
    [Alias('WhatIf')]
    [switch]$DryRun,
    [string]$OutDir = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$InstallUrl = 'https://github.com/qBitnaut/omarchy-dragon-sl7#install'
$script:Saved = New-Object System.Collections.ArrayList

function Say([string]$Text) { Write-Host $Text }
function Head([string]$Text) {
    Write-Host ''
    Write-Host ('== ' + $Text)
}
function Warn([string]$Text) { Write-Host ('WARNING: ' + $Text) -ForegroundColor Yellow }
function Dry([string]$Text) { Write-Host ('[dry-run] would: ' + $Text) -ForegroundColor Cyan }

function Ask([string]$Question) {
    # Never asks in a dry run, and answers no.
    if ($DryRun) { return $false }
    $a = Read-Host ($Question + ' [y/N]')
    return ($a -match '^(y|yes)$')
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Choose the folder for the recovery key. Returns the folder, or $null to skip.
function Get-Dest {
    $root = $OutDir
    if (-not $root) {
        Say ''
        Say 'Removable drives:'
        $found = $false
        foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2')) {
            $found = $true
            $gb = 0
            if ($d.Size) { $gb = [math]::Round($d.Size / 1GB, 1) }
            Say ('  ' + $d.DeviceID + '  ' + $d.VolumeName + '  ' + $gb + ' GB')
        }
        if (-not $found) { Say '  (none found; plug in a USB drive, or type a folder path)' }
        $root = Read-Host 'Drive letter or folder to save into (empty to skip)'
        if (-not $root) { return $null }
        if ($root -match '^[A-Za-z]$') { $root = $root + ':' }
        if ($root -match '^[A-Za-z]:$') { $root = $root + '\' }
    }
    if (-not (Test-Path -LiteralPath $root)) {
        Warn ('not found: ' + $root)
        return $null
    }
    $sysDrive = $env:SystemDrive
    if ($sysDrive -and ($root.Length -ge 2) -and ($root.Substring(0, 2) -ieq $sysDrive)) {
        Warn 'That is the Windows drive. A recovery key kept only there is lost when you install Linux, and useless if you cannot unlock it.'
        if (-not (Ask 'Save there anyway?')) { return $null }
    }
    return $root
}

# ----------------------------------------------------------------------------
Say 'Prepare-SL7: read-mostly checks before installing Linux. Nothing is uploaded.'
if ($DryRun) { Say 'DRY RUN: nothing will be written and no questions asked.' }

$isAdmin = Test-Admin
if (-not $isAdmin) {
    Warn 'Not running as administrator. The BitLocker and Secure Boot steps will be skipped or incomplete.'
    Warn 'Re-run from an administrator PowerShell for the full check.'
}

# ---- 1. model ---------------------------------------------------------------
Head '1. Model, CPU and RAM'
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = @(Get-CimInstance Win32_Processor)[0]
    $ramGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 0)
    $sku = ''
    if ($cs.PSObject.Properties['SystemSKUNumber']) { $sku = [string]$cs.SystemSKUNumber }
    Say ('  Manufacturer: ' + $cs.Manufacturer)
    Say ('  Model:        ' + $cs.Model)
    Say ('  SKU:          ' + $sku)
    Say ('  CPU:          ' + $cpu.Name)
    Say ('  RAM:          ' + $ramGb + ' GB')

    $isSl7 = ($cs.Manufacturer -match 'Microsoft') -and
             (($cs.Model + ' ' + $sku) -match 'Surface[ _]Laptop[ ,_]*(7|7th)')
    if ($isSl7) {
        Say '  This is a Surface Laptop 7.'
    } else {
        Warn 'This does not look like a Surface Laptop 7. This project targets only that model.'
    }

    $family = 'unknown'
    if ($cpu.Name -match 'X1E|X Elite') { $family = 'Snapdragon X Elite' }
    elseif ($cpu.Name -match 'X1P|X Plus') { $family = 'Snapdragon X Plus' }
    Say ('  CPU family:   ' + $family)
    if ($family -eq 'Snapdragon X Plus') {
        Say '  Support: X Plus is what the project is developed and tested on (13.8 inch, 16 GB).'
    } elseif ($family -eq 'Snapdragon X Elite') {
        Say '  Support: X Elite models and the 15 inch model are untested. Expect to debug.'
    } else {
        Warn 'CPU family not recognised.'
    }
} catch {
    Warn ('model check failed: ' + $_.Exception.Message)
}

# ---- 2. BitLocker -----------------------------------------------------------
Head '2. BitLocker'
$sysDriveLetter = $env:SystemDrive
if (-not $sysDriveLetter) { $sysDriveLetter = 'C:' }
if (-not $isAdmin) {
    Say '  Skipped: manage-bde needs administrator rights.'
} else {
    try {
        $status = @(& manage-bde.exe -status $sysDriveLetter 2>&1 | ForEach-Object { [string]$_ })
        foreach ($l in $status) { Say ('  ' + $l) }
        Say ''
        Say '  If you wipe the disk and install Linux, BitLocker does not matter: the installer'
        Say '  erases the drive. Suspending or disabling BitLocker is needed only if you KEEP'
        Say '  Windows (dual boot). This script never changes BitLocker.'
        Say '  A copy of the recovery key protects your Windows data if anything goes wrong.'
        if ($DryRun) {
            Dry ('save the output of "manage-bde -protectors -get ' + $sysDriveLetter + '" to a file on a USB drive you choose')
        } elseif (Ask 'Save the BitLocker recovery key text to your USB drive?') {
            $dest = Get-Dest
            if ($dest) {
                $prot = @(& manage-bde.exe -protectors -get $sysDriveLetter 2>&1 | ForEach-Object { [string]$_ })
                $hdr = @('BitLocker protectors for ' + $sysDriveLetter,
                         'This file contains your recovery password. Keep this drive private.',
                         '')
                $path = Join-Path $dest 'BitLocker-recovery-key.txt'
                ($hdr + $prot) | Set-Content -Path $path -Encoding ASCII
                [void]$script:Saved.Add($path)
                Say ('    saved ' + $path)
            }
        }
    } catch {
        Warn ('BitLocker query failed: ' + $_.Exception.Message)
    }
}

# ---- 3. UEFI version and Secure Boot ----------------------------------------
Head '3. UEFI version and Secure Boot'
try {
    $bios = Get-CimInstance Win32_BIOS
    Say ('  UEFI/firmware: ' + $bios.Manufacturer + ' ' + $bios.SMBIOSBIOSVersion + ' (' + $bios.ReleaseDate + ')')
} catch {
    Warn ('could not read Win32_BIOS: ' + $_.Exception.Message)
}
if (-not $isAdmin) {
    Say '  Secure Boot: not checked (needs administrator rights)'
} else {
    try {
        if (Confirm-SecureBootUEFI) { Say '  Secure Boot: ON' } else { Say '  Secure Boot: off' }
    } catch {
        Say ('  Secure Boot: could not be determined (' + $_.Exception.Message + ')')
    }
}
Say ''
Say '  To turn Secure Boot off (needed to boot the installer):'
Say '    1. Shut down completely (not restart).'
Say '    2. Hold the Volume Up button and press Power; release when the Surface UEFI appears.'
Say '    3. Security > Secure Boot: set to None. Save and exit.'
Say '  Do this when you are ready to boot the installer stick.'

# ---- 4. summary -------------------------------------------------------------
Head '4. Summary'
if ($DryRun) {
    Say '  Dry run: nothing was saved.'
} elseif ($script:Saved.Count -eq 0) {
    Say '  Nothing was saved. Nothing needs to be captured from Windows for Linux.'
} else {
    Say '  Saved:'
    foreach ($s in $script:Saved) { Say ('    ' + $s) }
    Warn 'The recovery key file holds your BitLocker recovery password. Keep that drive private.'
}
Say ''
Say 'Next steps:'
Say '  1. On any Linux machine, get the firmware: tools/installer-kit/get-sl7-firmware.sh'
Say '  2. Build the installer stick: tools/installer-kit/make-install-usb.sh'
Say '  3. Turn Secure Boot off (see step 3), then boot the stick from the USB-A port.'
Say ('  Full guide: ' + $InstallUrl)
