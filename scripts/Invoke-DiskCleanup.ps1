<#
.SYNOPSIS
    Frees disk space on the system drive by running a tiered, safe cleanup.

.DESCRIPTION
    Called by Invoke-Win11Upgrade.ps1 when free space is below the required
    threshold for the in-place upgrade. Runs cleanup tiers from cheapest /
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

    Nothing under user profile Documents / Downloads / Desktop is touched.

.PARAMETER TargetFreeGB
    Stop cleaning as soon as this many GB are free on the system drive.

.PARAMETER Tiers
    Ordered list of tier names to run.

.PARAMETER LogFile
    Path of an upgrade log to append each line to. If omitted, logs go to host only.

.PARAMETER LogCallback
    (Back-compat) ScriptBlock invoked with (message, level) for every line.

.PARAMETER WhatIf
    Report what each tier would do without actually deleting anything.

.OUTPUTS
    PSCustomObject { StartFreeGB, EndFreeGB, FreedGB, TargetReached, TiersRun }
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int]         $TargetFreeGB = 30,
    [string[]]    $Tiers        = @('Temp','RecycleBin','DeliveryOptimization','WindowsUpdate','CrashDumps','ComponentStore','UpgradeArtifacts'),
    [string]      $LogFile,
    [scriptblock] $LogCallback
)

$ErrorActionPreference = 'Continue'

function Log {
    param([string] $Message, [string] $Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($LogFile) {
        try { Add-Content -LiteralPath $LogFile -Value $line -ErrorAction SilentlyContinue } catch { }
    }
    if ($LogCallback) {
        try { & $LogCallback $Message $Level } catch { }
    }
    Write-Host $line
}

function Get-FreeGB {
    $drive = ($env:SystemDrive).TrimEnd(':')
    [math]::Floor((Get-PSDrive -Name $drive).Free / 1GB)
}

# Enumerate user profile dirs once - reused by Tier-Temp and Tier-CrashDumps.
$script:UserProfiles = @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)

function Remove-PathSafe {
    param([string] $Path, [int] $OlderThanDays = 0)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Delete')) { return }
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
}

# ---- Tier implementations ----
function Tier-Temp {
    Log 'Tier: Temp'
    $paths = @($env:TEMP, $env:TMP, "$env:SystemRoot\Temp")
    foreach ($p in $script:UserProfiles) { $paths += Join-Path $p.FullName 'AppData\Local\Temp' }
    $paths = $paths | Where-Object { $_ } | Sort-Object -Unique
    foreach ($p in $paths) {
        Log "  clearing $p"
        Remove-PathSafe -Path $p -OlderThanDays 1
    }
}

function Tier-RecycleBin {
    Log 'Tier: RecycleBin'
    if (-not $PSCmdlet.ShouldProcess('All drives', 'Clear-RecycleBin')) { return }
    try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch { Log "  Clear-RecycleBin failed: $_" 'WARN' }
}

function Tier-DeliveryOptimization {
    Log 'Tier: DeliveryOptimization'
    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess('DeliveryOptimization cache', 'Delete')) {
            try { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue } catch { Log "  $_" 'WARN' }
        }
    } else {
        Remove-PathSafe -Path "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization"
    }
}

function Tier-WindowsUpdate {
    Log 'Tier: WindowsUpdate cache'
    $services = @('wuauserv','bits','dosvc')
    if ($PSCmdlet.ShouldProcess('wuauserv/bits/dosvc','Stop for cache clear')) {
        foreach ($s in $services) { try { Stop-Service $s -Force -ErrorAction SilentlyContinue } catch {} }
        Start-Sleep -Seconds 2
        Remove-PathSafe -Path "$env:SystemRoot\SoftwareDistribution\Download"
        foreach ($s in $services) { try { Start-Service $s -ErrorAction SilentlyContinue } catch {} }
    }
}

function Tier-CrashDumps {
    Log 'Tier: CrashDumps'
    $dmp = "$env:SystemRoot\MEMORY.DMP"
    if (Test-Path -LiteralPath $dmp) {
        if ($PSCmdlet.ShouldProcess($dmp,'Delete')) {
            Remove-Item -LiteralPath $dmp -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-PathSafe -Path "$env:SystemRoot\Minidump"
    Remove-PathSafe -Path "$env:ProgramData\Microsoft\Windows\WER\ReportArchive"
    Remove-PathSafe -Path "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
    foreach ($p in $script:UserProfiles) {
        Remove-PathSafe -Path (Join-Path $p.FullName 'AppData\Local\CrashDumps')
    }
}

function Tier-ComponentStore {
    Log 'Tier: ComponentStore (DISM, may take 5-15 minutes)'
    if (-not $PSCmdlet.ShouldProcess('Component Store','DISM /StartComponentCleanup /ResetBase')) { return }
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
        if (-not $PSCmdlet.ShouldProcess($t,'Remove')) { continue }
        Log "  clearing $t"

        # Try the cheap path first; takeown/icacls on a 20-GB tree costs minutes.
        Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $t)) { continue }

        Log "  plain delete left residue; escalating with takeown/icacls"
        try {
            & takeown.exe /f $t /r /d y  | Out-Null
            & icacls.exe  $t /grant "*S-1-5-32-544:(F)" /t /c /q | Out-Null
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
    try { & $fnName } catch { Log "Tier $tier threw: $_" 'WARN' }
    $afterTier = Get-FreeGB
    Log ("Tier {0} done: {1:N0} GB -> {2:N0} GB (freed {3:N0} GB)" -f $tier, $beforeTier, $afterTier, ($afterTier - $beforeTier)) 'OK'
    $tiersRun += $tier
}

$end = Get-FreeGB
$result = [pscustomobject]@{
    StartFreeGB   = $start
    EndFreeGB     = $end
    FreedGB       = $end - $start
    TargetReached = ($end -ge $TargetFreeGB)
    TiersRun      = $tiersRun
}
Log ("Cleanup done: freed {0:N0} GB, {1} GB free, target reached: {2}" -f $result.FreedGB, $result.EndFreeGB, $result.TargetReached) 'OK'
return $result
