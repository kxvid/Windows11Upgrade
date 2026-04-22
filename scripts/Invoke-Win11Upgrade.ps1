<#
.SYNOPSIS
    In-place upgrade to Windows 11, auto-selecting LTSC vs non-LTSC media.

.DESCRIPTION
    Designed to be launched from Deploy-Win11Upgrade.bat on a network share.
    Detects current edition, selects the matching ISO, warns the logged-on
    user, mounts the ISO, and invokes setup.exe in unattended upgrade mode.
    Windows Setup handles reboots.

.PARAMETER ConfigPath
    Full path to upgrade.config.json.

.PARAMETER ShareRoot
    Root of the deployment share (the folder containing this repo layout).
    Used to resolve ISO paths in the config relative to the share.

.PARAMETER Preflight
    Run preflight only - detect edition, validate ISO, warn user, then exit
    before mounting or launching Setup. Useful for pilot testing.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ConfigPath,
    [Parameter(Mandatory)] [string] $ShareRoot,
    [switch] $Preflight
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---------- Load config ----------
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}
$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

# ---------- Logging ----------
$HostName   = $env:COMPUTERNAME
$TimeStamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$LocalLogDir = $Config.LogRoot
New-Item -ItemType Directory -Force -Path $LocalLogDir | Out-Null
$LogFile = Join-Path $LocalLogDir "upgrade-$TimeStamp.log"

function Write-Log {
    param([string] $Message, [ValidateSet('INFO','WARN','ERROR','OK')] [string] $Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $line | Tee-Object -FilePath $LogFile -Append | Write-Host
}

function Copy-LogToShare {
    if (-not $Config.NetworkLogShare) { return }
    try {
        $target = Join-Path $Config.NetworkLogShare "$HostName-$TimeStamp.log"
        Copy-Item -LiteralPath $LogFile -Destination $target -Force -ErrorAction Stop
        Write-Log "Log copied to $target" 'OK'
    } catch {
        Write-Log "Failed to copy log to network share: $_" 'WARN'
    }
}

trap {
    Write-Log "Unhandled error: $_" 'ERROR'
    Copy-LogToShare
    exit 99
}

Write-Log "=== Windows 11 Upgrade starting on $HostName ==="
Write-Log "Share root: $ShareRoot"
Write-Log "Config: $ConfigPath"

# ---------- Require elevation ----------
$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log 'Script is not elevated. Aborting.' 'ERROR'
    exit 5
}

# ---------- Detect current OS / edition ----------
$os         = Get-CimInstance Win32_OperatingSystem
$cv         = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$buildNum   = [int]$cv.CurrentBuildNumber
$editionId  = $cv.EditionID                 # e.g. Enterprise, EnterpriseS, IoTEnterpriseS
$productName = $cv.ProductName               # e.g. "Windows 10 Enterprise LTSC"
Write-Log "Current OS: $productName (build $buildNum, EditionID=$editionId)"

# LTSC/LTSB EditionIDs: EnterpriseS, EnterpriseSN, IoTEnterpriseS, IoTEnterpriseSK ...
# The 'S' marker sits before any optional N/K suffix. ProductName is the fallback.
$isLtsc = ($editionId -match 'S[NK]?$') -or ($productName -match '(?i)LTSC|LTSB')
Write-Log ("Detected LTSC: {0}" -f $isLtsc)

# Already on target build? Skip.
$targetBuild = [int]$Config.TargetBuild
if ($Config.SkipIfAlreadyBuild -and $buildNum -ge $targetBuild) {
    Write-Log "Already on build $buildNum (>= target $targetBuild). Nothing to do." 'OK'
    Copy-LogToShare
    exit 0
}

# ---------- Resolve ISO path ----------
$relIso = if ($isLtsc) { $Config.IsoPaths.LTSC } else { $Config.IsoPaths.NonLTSC }
if (-not $relIso) { throw "No ISO configured for edition (LTSC=$isLtsc)" }

$isoPath = if ([System.IO.Path]::IsPathRooted($relIso)) {
    $relIso
} else {
    Join-Path $ShareRoot $relIso
}
Write-Log "Selected ISO: $isoPath"

if (-not (Test-Path -LiteralPath $isoPath)) {
    throw "ISO not found: $isoPath"
}

# ---------- Preflight: disk space (with optional auto-cleanup) ----------
$systemDrive = ($env:SystemDrive).TrimEnd(':')
$freeGB = [math]::Floor((Get-PSDrive -Name $systemDrive).Free / 1GB)
$minGB  = [int]$Config.MinFreeDiskGB
Write-Log "Free space on ${systemDrive}: ${freeGB} GB (min ${minGB} GB)"

if ($freeGB -lt $minGB) {
    $cleanupCfg = $Config.AutoCleanup
    if ($cleanupCfg -and $cleanupCfg.Enabled) {
        $target = if ($cleanupCfg.TargetFreeGB) { [int]$cleanupCfg.TargetFreeGB } else { $minGB + 5 }
        Write-Log "Below threshold - running auto-cleanup (target ${target} GB)..."
        $cleanupScript = Join-Path $PSScriptRoot 'Invoke-DiskCleanup.ps1'
        if (-not (Test-Path -LiteralPath $cleanupScript)) {
            throw "Auto-cleanup enabled but script missing: $cleanupScript"
        }
        $tiers = if ($cleanupCfg.Tiers) { @($cleanupCfg.Tiers) } else { @('Temp','RecycleBin','DeliveryOptimization','WindowsUpdate','CrashDumps','ComponentStore','UpgradeArtifacts') }
        $logFileRef = $LogFile
        $logCallback = {
            param($m, $l = 'INFO')
            $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $l, $m
            Add-Content -LiteralPath $logFileRef -Value $line -ErrorAction SilentlyContinue
            Write-Host $line
        }.GetNewClosure()
        $result = & $cleanupScript -TargetFreeGB $target -Tiers $tiers -LogCallback $logCallback
        $freeGB = [math]::Floor((Get-PSDrive -Name $systemDrive).Free / 1GB)
        Write-Log ("Post-cleanup free space: ${freeGB} GB (freed {0} GB, tiers run: {1})" -f $result.FreedGB, ($result.TiersRun -join ',')) 'OK'
    }
    if ($freeGB -lt $minGB) {
        throw "Insufficient free space on $systemDrive (have ${freeGB} GB, need ${minGB} GB). Cleanup did not free enough - manual intervention required."
    }
}

# ---------- Preflight: AC power ----------
if ($Config.RequireAC) {
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($battery) {
        # BatteryStatus 2 = on AC
        $onAC = ($battery | ForEach-Object { $_.BatteryStatus } | Where-Object { $_ -eq 2 }).Count -gt 0
        if (-not $onAC) {
            throw 'Laptop is on battery power. Plug in AC adapter and retry.'
        }
        Write-Log 'AC power confirmed.' 'OK'
    } else {
        Write-Log 'No battery detected (desktop).' 'INFO'
    }
}

# ---------- Stage ISO locally (optional but recommended) ----------
$workingIso = $isoPath
if ($Config.CopyIsoLocally) {
    New-Item -ItemType Directory -Force -Path $Config.LocalStagingPath | Out-Null
    $localIso = Join-Path $Config.LocalStagingPath ([System.IO.Path]::GetFileName($isoPath))
    Write-Log "Copying ISO locally to $localIso ..."
    Copy-Item -LiteralPath $isoPath -Destination $localIso -Force
    $workingIso = $localIso
    Write-Log 'ISO copied.' 'OK'
}

# ---------- User warning ----------
if ($Config.UserWarning.Enabled) {
    $secs = [int]$Config.UserWarning.WarningSeconds
    $mins = [math]::Ceiling($secs / 60)
    $msg  = ($Config.UserWarning.Message -replace '\{MINUTES\}', $mins)
    Write-Log "Warning logged-on users for $secs seconds..."
    try {
        # msg * sends to every active session; /W waits up to /TIME seconds or user click.
        & msg.exe * /TIME:$secs /W $msg 2>&1 | ForEach-Object { Write-Log $_ }
    } catch {
        Write-Log "msg.exe failed ($_). Sleeping $secs seconds instead." 'WARN'
        Start-Sleep -Seconds $secs
    }
}

if ($Preflight) {
    Write-Log 'Preflight mode: checks complete, exiting before mount/setup.' 'OK'
    Copy-LogToShare
    exit 0
}

# ---------- Mount ISO ----------
Write-Log "Mounting $workingIso ..."
$mount = Mount-DiskImage -ImagePath $workingIso -PassThru
Start-Sleep -Seconds 2
$driveLetter = (Get-Volume -DiskImage $mount).DriveLetter
if (-not $driveLetter) {
    throw "Could not determine drive letter for mounted ISO"
}
$setupExe = "${driveLetter}:\setup.exe"
Write-Log "Mounted at ${driveLetter}: ($setupExe)"

if (-not (Test-Path -LiteralPath $setupExe)) {
    throw "setup.exe not found on mounted ISO at $setupExe"
}

# ---------- Launch setup ----------
$setupArgs = @($Config.SetupArgs) + @('/copylogs', $LocalLogDir)
Write-Log ("Launching: {0} {1}" -f $setupExe, ($setupArgs -join ' '))

try {
    $proc = Start-Process -FilePath $setupExe -ArgumentList $setupArgs -PassThru -Wait
    $rc = $proc.ExitCode
    Write-Log "setup.exe exited with code $rc"
} catch {
    Write-Log "setup.exe launch failed: $_" 'ERROR'
    $rc = 1
}

# ---------- Cleanup mount ----------
try {
    Dismount-DiskImage -ImagePath $workingIso | Out-Null
    Write-Log 'ISO dismounted.'
} catch {
    Write-Log "Dismount failed (non-fatal): $_" 'WARN'
}

# Setup.exe exit codes: 0 = success, others = various. See Microsoft docs.
# With /auto upgrade, system is set to reboot itself when ready.
if ($rc -eq 0) {
    Write-Log 'Upgrade phase 1 complete. Windows Setup will reboot automatically.' 'OK'
} else {
    Write-Log "Setup returned non-zero ($rc). See $LocalLogDir and C:\`$WINDOWS.~BT\Sources\Panther\." 'ERROR'
}

Copy-LogToShare
exit $rc
