<#
.SYNOPSIS
    Frees disk space on the system drive by running a tiered, safe cleanup.

.DESCRIPTION
    Called by Invoke-Win11Upgrade.ps1 when free space is below the required
    threshold for the in-place upgrade. Runs cleanup tiers from cheapest/
    safest to heavier, re-checking free space after each tier and stopping
    as soon as the target is reached.

    Tiers (in order):
      Temp                 - %TEMP%, C:\Windows\Temp, per-user AppData Temp
      RecycleBin           - Empties recycle bin on all drives
      DeliveryOptimization - Windows Update peer-to-peer cache
      WindowsUpdate        - C:\Windows\SoftwareDistribution\Download (cache)
      CrashDumps           - Memory.dmp, Minidump, WER, per-user CrashDumps
      ComponentStore       - DISM /StartComponentCleanup /ResetBase (slow)
      UpgradeArtifacts     - Windows.old, $WINDOWS.~BT/~WS, $GetCurrent

    Nothing under user profile Documents/Downloads/Desktop is touched.

.PARAMETER TargetFreeGB
    Stop cleaning as soon as this many GB are free on the system drive.

.PARAMETER Tiers
    Ordered list of tier names to run. Omit any you don't trust.

.PARAMETER LogCallback
    ScriptBlock used for logging. Must accept a string message and an optional
    level ('INFO'|'WARN'|'ERROR'|'OK'). If null, writes to host.

.OUTPUTS
    PSCustomObject with StartFreeGB, EndFreeGB, FreedGB, TargetReached, TiersRun.
#>

[CmdletBinding()]
param(
    [int] $TargetFreeGB = 30,
    [string[]] $Tiers = @('Temp','RecycleBin','DeliveryOptimization','WindowsUpdate','CrashDumps','ComponentStore','UpgradeArtifacts'),
    [scriptblock] $LogCallback
)

$ErrorActionPreference = 'Continue'

function Log {
    param([string] $Message, [string] $Level = 'INFO')
    if ($LogCallback) {
        & $LogCallback $Message $Level
    } else {
        Write-Host "[$Level] $Message"
    }
}

function Get-FreeGB {
    $drive = ($env:SystemDrive).TrimEnd(':')
    [math]::Floor((Get-PSDrive -Name $drive).Free / 1GB)
}

function Remove-PathSafe {
    param([string] $Path, [int] $OlderThanDays = 0)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $before = Get-FreeGB
    try {
        if ($OlderThanDays -gt 0) {
            $cutoff = (Get-Date).AddDays(-$OlderThanDays)
            Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $cutoff } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        } else {
            Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Log "  Remove-PathSafe error on ${Path}: $_" 'WARN'
    }
    $after = Get-FreeGB
    return ($after - $before)
}

function Invoke-Takeown {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    & takeown.exe /f $Path /r /d y  | Out-Null
    & icacls.exe  $Path /grant "*S-1-5-32-544:(F)" /t /c /q | Out-Null
}

# ---- Tier implementations ----
function Tier-Temp {
    Log 'Tier: Temp'
    $paths = @(
        $env:TEMP,
        $env:TMP,
        "$env:SystemRoot\Temp"
    )
    foreach ($p in Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue) {
        $paths += Join-Path $p.FullName 'AppData\Local\Temp'
    }
    $paths = $paths | Where-Object { $_ } | Sort-Object -Unique
    foreach ($p in $paths) {
        Log "  clearing $p"
        [void](Remove-PathSafe -Path $p -OlderThanDays 1)
    }
}

function Tier-RecycleBin {
    Log 'Tier: RecycleBin'
    try {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    } catch {
        Log "  Clear-RecycleBin failed: $_" 'WARN'
    }
}

function Tier-DeliveryOptimization {
    Log 'Tier: DeliveryOptimization'
    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        try { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue } catch { Log "  $_" 'WARN' }
    } else {
        # Fallback: clear the cache directory directly
        [void](Remove-PathSafe -Path "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization")
    }
}

function Tier-WindowsUpdate {
    Log 'Tier: WindowsUpdate cache'
    $services = @('wuauserv','bits','dosvc')
    foreach ($s in $services) { try { Stop-Service $s -Force -ErrorAction SilentlyContinue } catch {} }
    Start-Sleep -Seconds 2
    [void](Remove-PathSafe -Path "$env:SystemRoot\SoftwareDistribution\Download")
    foreach ($s in $services) { try { Start-Service $s -ErrorAction SilentlyContinue } catch {} }
}

function Tier-CrashDumps {
    Log 'Tier: CrashDumps'
    $dmp = "$env:SystemRoot\MEMORY.DMP"
    if (Test-Path -LiteralPath $dmp) {
        Remove-Item -LiteralPath $dmp -Force -ErrorAction SilentlyContinue
    }
    [void](Remove-PathSafe -Path "$env:SystemRoot\Minidump")
    [void](Remove-PathSafe -Path "$env:ProgramData\Microsoft\Windows\WER\ReportArchive")
    [void](Remove-PathSafe -Path "$env:ProgramData\Microsoft\Windows\WER\ReportQueue")
    foreach ($p in Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue) {
        [void](Remove-PathSafe -Path (Join-Path $p.FullName 'AppData\Local\CrashDumps'))
    }
}

function Tier-ComponentStore {
    Log 'Tier: ComponentStore (DISM, may take 5-15 minutes)'
    $out = & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1
    foreach ($line in $out) { Log "  dism: $line" }
}

function Tier-UpgradeArtifacts {
    Log 'Tier: UpgradeArtifacts'
    $targets = @(
        'C:\Windows.old',
        'C:\$WINDOWS.~BT',
        'C:\$WINDOWS.~WS',
        'C:\$GetCurrent',
        'C:\$Windows.~Q'
    )
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t)) { continue }
        Log "  clearing $t"
        try {
            Invoke-Takeown -Path $t
            Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Log "  failed on ${t}: $_" 'WARN'
        }
    }
}

# ---- Orchestration ----
$start = Get-FreeGB
Log "Cleanup start: ${start} GB free (target ${TargetFreeGB} GB)"

$tiersRun = @()
foreach ($tier in $Tiers) {
    if ((Get-FreeGB) -ge $TargetFreeGB) {
        Log "Target reached (${TargetFreeGB} GB). Skipping remaining tiers." 'OK'
        break
    }
    $fnName = "Tier-$tier"
    if (-not (Get-Command $fnName -ErrorAction SilentlyContinue)) {
        Log "Unknown tier '$tier' - skipping" 'WARN'
        continue
    }
    $beforeTier = Get-FreeGB
    try {
        & $fnName
    } catch {
        Log "Tier $tier threw: $_" 'WARN'
    }
    $afterTier = Get-FreeGB
    $delta = $afterTier - $beforeTier
    Log ("Tier {0} done: {1:N0} GB -> {2:N0} GB (freed {3:N0} GB)" -f $tier, $beforeTier, $afterTier, $delta) 'OK'
    $tiersRun += $tier
}

$end = Get-FreeGB
$result = [pscustomobject]@{
    StartFreeGB    = $start
    EndFreeGB      = $end
    FreedGB        = $end - $start
    TargetReached  = ($end -ge $TargetFreeGB)
    TiersRun       = $tiersRun
}
Log ("Cleanup done: freed {0:N0} GB, {1} GB free, target reached: {2}" -f $result.FreedGB, $result.EndFreeGB, $result.TargetReached) 'OK'
return $result
