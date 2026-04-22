<#
.SYNOPSIS
    In-place upgrade to Windows 11, auto-selecting LTSC vs non-LTSC media,
    with self-healing retry on setup failures.

.DESCRIPTION
    Designed to be launched from Deploy-Win11Upgrade.bat on a network share.
    Detects current edition, selects the matching ISO, stages it locally (in
    parallel with the user warning countdown), mounts the ISO, and invokes
    setup.exe in unattended upgrade mode.

    If setup.exe returns non-zero, the script:
      1. Tails setuperr.log / setupact.log into the upgrade log.
      2. Parses the Panther logs to pinpoint the error code + phase.
      3. Applies a targeted remediation (DISM RestoreHealth, WU reset,
         upgrade-artifact cleanup, extra disk cleanup, unsupported-hw
         bypass, re-stage ISO, or transient retry).
      4. Retries setup.exe up to MaxAttemptsPerRun in-session, persisting
         attempt state to C:\ProgramData\Win11Upgrade\state.json so repeat
         invocations from RMM/GPO pick up where they left off (up to
         MaxAttemptsTotal).

    Windows Setup handles reboots.

.PARAMETER ConfigPath
    Full path to upgrade.config.json.

.PARAMETER ShareRoot
    Root of the deployment share. Used to resolve relative ISO paths.

.PARAMETER Preflight
    Run preflight only - detect edition, validate ISO, warn user, then exit
    before mounting or launching Setup. Emits a JSON summary to stdout.

.PARAMETER ResetState
    Wipe the persisted retry state before running. Useful for manual re-runs
    after an operator has fixed something the script can't fix itself.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ConfigPath,
    [Parameter(Mandatory)] [string] $ShareRoot,
    [switch] $Preflight,
    [switch] $ResetState
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---------- Exit codes (see README) ----------
$EXIT = @{
    Success            = 0
    ConfigInvalid      = 2
    DiskSpace          = 3
    NotOnAC            = 4
    NotElevated        = 5
    IsoNotFound        = 6
    MountFailure       = 7
    RetriesExhausted   = 8
    Unrecoverable      = 9
    RetryNextRun       = 10
    Unhandled          = 99
}

# ---------- Config load + validation ----------
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "[ERROR] Config not found: $ConfigPath"
    exit $EXIT.ConfigInvalid
}
try {
    $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
} catch {
    Write-Host "[ERROR] Config JSON parse failed: $_"
    exit $EXIT.ConfigInvalid
}

function Assert-ConfigKey {
    param([object] $Obj, [string] $Path, [string[]] $Required)
    foreach ($k in $Required) {
        if (-not ($Obj.PSObject.Properties.Name -contains $k)) {
            throw "Config key missing: $Path.$k"
        }
    }
}
try {
    Assert-ConfigKey $Config '' @('IsoPaths','TargetBuild','LocalStagingPath','LogRoot','SetupArgs','MinFreeDiskGB')
    Assert-ConfigKey $Config.IsoPaths 'IsoPaths' @('NonLTSC','LTSC')
} catch {
    Write-Host "[ERROR] $_"
    exit $EXIT.ConfigInvalid
}

# ---------- Logging (single StreamWriter, flushed on each line) ----------
$HostName   = $env:COMPUTERNAME
$TimeStamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$LocalLogDir = $Config.LogRoot
New-Item -ItemType Directory -Force -Path $LocalLogDir | Out-Null
$LogFile = Join-Path $LocalLogDir "upgrade-$TimeStamp.log"
$script:LogWriter = [System.IO.StreamWriter]::new($LogFile, $true, [System.Text.UTF8Encoding]::new($false))
$script:LogWriter.AutoFlush = $true

function Write-Log {
    param([string] $Message, [ValidateSet('INFO','WARN','ERROR','OK','DEBUG')] [string] $Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { $script:LogWriter.WriteLine($line) } catch { }
    Write-Host $line
}
$script:LogCallback = { param($m, $l = 'INFO') Write-Log -Message $m -Level $l }.GetNewClosure()

function Close-Log {
    try { if ($script:LogWriter) { $script:LogWriter.Flush(); $script:LogWriter.Dispose(); $script:LogWriter = $null } } catch { }
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

function Exit-WithCode {
    param([int] $Code)
    Copy-LogToShare
    Close-Log
    exit $Code
}

trap {
    Write-Log "Unhandled error: $_" 'ERROR'
    Exit-WithCode $EXIT.Unhandled
}

# Rotate old logs (>30 days) to keep LogRoot from ballooning
try {
    Get-ChildItem -LiteralPath $LocalLogDir -Filter 'upgrade-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

Write-Log "=== Windows 11 Upgrade starting on $HostName ==="
Write-Log "Share root: $ShareRoot"
Write-Log "Config:     $ConfigPath"

# ---------- Load diagnostics module ----------
$diagModule = Join-Path $PSScriptRoot 'Invoke-SetupDiagnostics.ps1'
if (-not (Test-Path -LiteralPath $diagModule)) {
    Write-Log "Diagnostics helper missing: $diagModule" 'ERROR'
    Exit-WithCode $EXIT.ConfigInvalid
}
. $diagModule

$cleanupScript = Join-Path $PSScriptRoot 'Invoke-DiskCleanup.ps1'

# ---------- Require elevation ----------
$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log 'Script is not elevated. Aborting.' 'ERROR'
    Exit-WithCode $EXIT.NotElevated
}

# ---------- Retry state ----------
$StateFile = Join-Path $LocalLogDir 'state.json'
if ($ResetState -and (Test-Path -LiteralPath $StateFile)) {
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    Write-Log 'State file reset by -ResetState switch.' 'OK'
}
function Load-State {
    if (Test-Path -LiteralPath $StateFile) {
        try { return Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{
        FirstAttemptUtc     = (Get-Date).ToUniversalTime().ToString('o')
        LastAttemptUtc      = $null
        Attempts            = 0
        AppliedRemediations = @()
        LastErrorCode       = $null
        LastExtendedCode    = $null
        LastPhase           = $null
        LastSetupRc         = $null
    }
}
function Save-State { param($State) $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StateFile -Encoding UTF8 }
function Clear-State { if (Test-Path -LiteralPath $StateFile) { Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue } }
$State = Load-State

$maxTotal = if ($Config.Retry -and $Config.Retry.MaxAttemptsTotal) { [int]$Config.Retry.MaxAttemptsTotal } else { 5 }
$maxPerRun = if ($Config.Retry -and $Config.Retry.MaxAttemptsPerRun) { [int]$Config.Retry.MaxAttemptsPerRun } else { 2 }

if ($State.Attempts -ge $maxTotal) {
    Write-Log ("Retry budget exhausted ({0}/{1}). Operator intervention required. Rerun with -ResetState to clear." -f $State.Attempts, $maxTotal) 'ERROR'
    Exit-WithCode $EXIT.RetriesExhausted
}

# ---------- Detect current OS / edition ----------
$cv          = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$buildNum    = [int]$cv.CurrentBuildNumber
$editionId   = $cv.EditionID
$productName = $cv.ProductName
$displayVer  = $cv.DisplayVersion
$ubr         = $cv.UBR
Write-Log ("Current OS: {0} (build {1}.{2}, DisplayVersion={3}, EditionID={4})" -f $productName, $buildNum, $ubr, $displayVer, $editionId)

$isLtsc = ($editionId -match 'S[NK]?$') -or ($productName -match '(?i)LTSC|LTSB')
Write-Log ("Detected LTSC: {0}" -f $isLtsc)

# Skip logic: prefer DisplayVersion match, fall back to build number.
$targetBuild       = [int]$Config.TargetBuild
$targetDisplayVer  = if ($Config.PSObject.Properties['TargetDisplayVersion']) { [string]$Config.TargetDisplayVersion } else { $null }
$alreadyUpgraded = $false
if ($Config.SkipIfAlreadyBuild) {
    if ($targetDisplayVer -and $displayVer -eq $targetDisplayVer) { $alreadyUpgraded = $true }
    elseif ($buildNum -ge $targetBuild) { $alreadyUpgraded = $true }
}
if ($alreadyUpgraded) {
    Write-Log ("Already on {0}/{1} (target {2}/{3}). Nothing to do." -f $displayVer, $buildNum, $targetDisplayVer, $targetBuild) 'OK'
    Clear-State
    Exit-WithCode $EXIT.Success
}

# ---------- Resolve ISO path ----------
$relIso = if ($isLtsc) { $Config.IsoPaths.LTSC } else { $Config.IsoPaths.NonLTSC }
if (-not $relIso) {
    Write-Log "No ISO configured for edition (LTSC=$isLtsc)" 'ERROR'
    Exit-WithCode $EXIT.ConfigInvalid
}
$isoPath = if ([System.IO.Path]::IsPathRooted($relIso)) { $relIso } else { Join-Path $ShareRoot $relIso }
Write-Log "Selected ISO: $isoPath"
if (-not (Test-Path -LiteralPath $isoPath)) {
    Write-Log "ISO not found: $isoPath" 'ERROR'
    Exit-WithCode $EXIT.IsoNotFound
}

# ---------- Preflight: disk space (with optional auto-cleanup) ----------
$systemDrive = ($env:SystemDrive).TrimEnd(':')
function Get-FreeGB { [math]::Floor((Get-PSDrive -Name $systemDrive).Free / 1GB) }
$freeGB = Get-FreeGB
$minGB  = [int]$Config.MinFreeDiskGB
Write-Log "Free space on ${systemDrive}: ${freeGB} GB (min ${minGB} GB)"

$cleanupTiers = if ($Config.AutoCleanup -and $Config.AutoCleanup.Tiers) { @($Config.AutoCleanup.Tiers) } else { @('Temp','RecycleBin','DeliveryOptimization','WindowsUpdate','CrashDumps','ComponentStore','UpgradeArtifacts') }
$cleanupTarget = if ($Config.AutoCleanup -and $Config.AutoCleanup.TargetFreeGB) { [int]$Config.AutoCleanup.TargetFreeGB } else { $minGB + 5 }

function Invoke-Cleanup {
    param([int] $TargetGB)
    if (-not (Test-Path -LiteralPath $cleanupScript)) { throw "Auto-cleanup enabled but script missing: $cleanupScript" }
    Write-Log "Running disk cleanup (target ${TargetGB} GB)..."
    $result = & $cleanupScript -TargetFreeGB $TargetGB -Tiers $cleanupTiers -LogFile $LogFile
    $f = Get-FreeGB
    Write-Log ("Post-cleanup free: ${f} GB (freed {0} GB, tiers run: {1})" -f $result.FreedGB, ($result.TiersRun -join ',')) 'OK'
    return $f
}

if ($freeGB -lt $minGB) {
    if ($Config.AutoCleanup -and $Config.AutoCleanup.Enabled) {
        $freeGB = Invoke-Cleanup -TargetGB $cleanupTarget
    }
    if ($freeGB -lt $minGB) {
        Write-Log "Insufficient free space on $systemDrive (have ${freeGB} GB, need ${minGB} GB)." 'ERROR'
        Exit-WithCode $EXIT.DiskSpace
    }
}

# ---------- Preflight: AC power ----------
if ($Config.RequireAC) {
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($battery) {
        # BatteryStatus: 1=discharging, 2=AC, 6-11=charging variants
        $acStatuses = @(2,6,7,8,9,11)
        $onAC = @($battery.BatteryStatus) | Where-Object { $_ -in $acStatuses } | Select-Object -First 1
        if (-not $onAC) {
            Write-Log 'Laptop is on battery power. Plug in AC adapter and retry.' 'ERROR'
            Exit-WithCode $EXIT.NotOnAC
        }
        Write-Log 'AC power confirmed.' 'OK'
    } else {
        Write-Log 'No battery detected (desktop).'
    }
}

# ---------- Stage ISO locally (robocopy, idempotent) ----------
# Self-contained scriptblock so it can run inside Start-Job without closure issues.
$IsoStageBlock = {
    param([string] $SourceIso, [string] $StagingDir)
    New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null
    $localIso = Join-Path $StagingDir ([System.IO.Path]::GetFileName($SourceIso))

    if (Test-Path -LiteralPath $localIso) {
        $src = Get-Item -LiteralPath $SourceIso
        $dst = Get-Item -LiteralPath $localIso
        if ($src.Length -eq $dst.Length -and $src.LastWriteTimeUtc -eq $dst.LastWriteTimeUtc) {
            return [pscustomobject]@{ Path = $localIso; Skipped = $true; RobocopyRc = 0 }
        }
    }

    $srcDir  = Split-Path -Parent $SourceIso
    $srcFile = Split-Path -Leaf   $SourceIso
    $rcArgs  = @($srcDir, $StagingDir, $srcFile,
                 '/J','/MT:8','/R:2','/W:5','/NP','/NDL','/NS','/NC','/NJS','/NJH')
    $rc = (Start-Process -FilePath robocopy.exe -ArgumentList $rcArgs -PassThru -Wait -WindowStyle Hidden).ExitCode
    if ($rc -ge 8) { throw "robocopy failed with exit code $rc while staging $SourceIso" }
    return [pscustomobject]@{ Path = $localIso; Skipped = $false; RobocopyRc = $rc }
}

function Invoke-IsoStage {
    param([string] $SourceIso, [string] $StagingDir)
    $r = & $IsoStageBlock $SourceIso $StagingDir
    if ($r.Skipped) {
        Write-Log 'Staged ISO already matches source (size+mtime). Skipping copy.' 'OK'
    } else {
        Write-Log ("robocopy staging complete (exit {0})" -f $r.RobocopyRc) 'OK'
    }
    return $r.Path
}

$workingIso = $isoPath
$stagingJob = $null
if ($Config.CopyIsoLocally) {
    Write-Log "Starting background ISO staging (robocopy /J /MT:8)..."
    $stagingJob = Start-Job -Name 'Win11IsoStage' -ScriptBlock $IsoStageBlock `
        -ArgumentList $isoPath, $Config.LocalStagingPath
}

# ---------- User warning (runs in parallel with staging above) ----------
if ($Config.UserWarning.Enabled) {
    $secs = [int]$Config.UserWarning.WarningSeconds
    $mins = [math]::Ceiling($secs / 60)
    $msg  = ($Config.UserWarning.Message -replace '\{MINUTES\}', $mins)
    Write-Log "Warning logged-on users for $secs seconds (ISO stage runs concurrently)..."
    try {
        & msg.exe * /TIME:$secs /W $msg 2>&1 | ForEach-Object { Write-Log $_ }
    } catch {
        Write-Log "msg.exe failed ($_). Sleeping $secs seconds instead." 'WARN'
        Start-Sleep -Seconds $secs
    }
}

# ---------- Wait for staging job to finish ----------
if ($stagingJob) {
    Write-Log "Waiting for ISO staging job to finish (if not already)..."
    $stagingJob | Wait-Job | Out-Null
    try {
        $stageResult = Receive-Job -Job $stagingJob -ErrorAction Stop
        $workingIso  = $stageResult.Path
        if ($stageResult.Skipped) {
            Write-Log "Staged ISO already matched source - no copy needed." 'OK'
        } else {
            Write-Log ("Staging complete (robocopy exit {0}): {1}" -f $stageResult.RobocopyRc, $workingIso) 'OK'
        }
    } catch {
        Write-Log "ISO staging failed: $_" 'ERROR'
        Remove-Job -Job $stagingJob -Force -ErrorAction SilentlyContinue
        Exit-WithCode $EXIT.IsoNotFound
    }
    Remove-Job -Job $stagingJob -Force -ErrorAction SilentlyContinue
}

if ($Preflight) {
    $report = [pscustomobject]@{
        Host                 = $HostName
        EditionID            = $editionId
        ProductName          = $productName
        DisplayVersion       = $displayVer
        Build                = "$buildNum.$ubr"
        DetectedLtsc         = $isLtsc
        SelectedIso          = $isoPath
        StagedIso            = $workingIso
        FreeGB               = (Get-FreeGB)
        OnAC                 = $true
        TargetBuild          = $targetBuild
        TargetDisplayVersion = $targetDisplayVer
        WouldSkip            = $alreadyUpgraded
        State                = $State
    }
    Write-Log 'Preflight mode: checks complete, exiting before mount/setup.' 'OK'
    ($report | ConvertTo-Json -Depth 5) | Write-Host
    Exit-WithCode $EXIT.Success
}

# =====================================================================
# Setup retry loop with self-healing diagnostics
# =====================================================================

function Mount-SetupIso {
    param([string] $Path)
    Write-Log "Mounting $Path ..."
    $mount = Mount-DiskImage -ImagePath $Path -PassThru
    # Poll for drive letter up to ~15s. Mount is async on some systems.
    $letter = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        $v = Get-Volume -DiskImage $mount -ErrorAction SilentlyContinue
        if ($v -and $v.DriveLetter) { $letter = $v.DriveLetter; break }
    }
    if (-not $letter) { throw 'Could not determine drive letter for mounted ISO after 15s.' }
    Write-Log ("Mounted at {0}: ({1}:\setup.exe)" -f $letter, $letter)
    return @{ Mount = $mount; DriveLetter = $letter }
}

function Get-SetupErrTail {
    param([int] $TailLines = 30)
    $panther = 'C:\$WINDOWS.~BT\Sources\Panther\setuperr.log'
    if (-not (Test-Path -LiteralPath $panther)) { return @() }
    try { return Get-Content -LiteralPath $panther -Tail $TailLines -ErrorAction Stop } catch { return @() }
}

function Invoke-SetupOnce {
    param([string] $IsoPath)
    $mounted = $null
    try {
        $mounted = Mount-SetupIso -Path $IsoPath
        $setupExe = "$($mounted.DriveLetter):\setup.exe"
        if (-not (Test-Path -LiteralPath $setupExe)) {
            throw "setup.exe not found on mounted ISO at $setupExe"
        }
        $setupArgs = @($Config.SetupArgs) + @('/copylogs', $LocalLogDir)
        Write-Log ("Launching: {0} {1}" -f $setupExe, ($setupArgs -join ' '))
        $proc = Start-Process -FilePath $setupExe -ArgumentList $setupArgs -PassThru -Wait
        $rc = $proc.ExitCode
        Write-Log "setup.exe exited with code $rc"
        return $rc
    } finally {
        if ($mounted) {
            try {
                Dismount-DiskImage -ImagePath $IsoPath | Out-Null
                Write-Log 'ISO dismounted.'
            } catch {
                Write-Log "Dismount failed (non-fatal): $_" 'WARN'
            }
        }
    }
}

$finalRc = $null
$diag    = $null

for ($attempt = 1; $attempt -le $maxPerRun; $attempt++) {
    $State.Attempts++
    $State.LastAttemptUtc = (Get-Date).ToUniversalTime().ToString('o')
    Save-State $State
    Write-Log ("--- Setup attempt {0} (session {1}/{2}, total {3}/{4}) ---" -f `
        $attempt, $attempt, $maxPerRun, $State.Attempts, $maxTotal)

    try {
        $finalRc = Invoke-SetupOnce -IsoPath $workingIso
    } catch {
        Write-Log "Mount/setup infra failure: $_" 'ERROR'
        $finalRc = -1
    }

    if ($finalRc -eq 0) {
        Write-Log 'Upgrade phase 1 complete. Windows Setup will reboot automatically.' 'OK'
        Clear-State
        Exit-WithCode $EXIT.Success
    }

    # Tail Panther into our log for at-a-glance triage.
    $tail = Get-SetupErrTail -TailLines 30
    if ($tail) {
        Write-Log '--- setuperr.log (last 30 lines) ---'
        foreach ($l in $tail) { Write-Log "  $l" }
        Write-Log '--- end setuperr.log ---'
    } else {
        Write-Log 'setuperr.log not found (setup may have failed pre-staging).' 'WARN'
    }

    # Diagnose + persist state.
    $diag = Get-SetupFailureInfo -LogCallback $script:LogCallback
    Write-Log ("Diagnosis: Err={0} Ext={1} Phase={2} => {3}" -f `
        $diag.ErrorCode, $diag.ExtendedCode, $diag.Phase, $diag.Remediation) 'WARN'
    Write-Log ("  reason: {0}" -f $diag.Reason)
    if ($diag.BlockingApps.Count)    { Write-Log ("  blocking apps: {0}" -f ($diag.BlockingApps -join ', ')) 'WARN' }
    if ($diag.BlockingDrivers.Count) { Write-Log ("  blocking drivers: {0}" -f ($diag.BlockingDrivers -join ', ')) 'WARN' }

    $State.LastErrorCode    = $diag.ErrorCode
    $State.LastExtendedCode = $diag.ExtendedCode
    $State.LastPhase        = $diag.Phase
    $State.LastSetupRc      = $finalRc
    Save-State $State

    if (-not $diag.Retryable) {
        Write-Log 'Failure is not auto-recoverable. Exiting for operator review.' 'ERROR'
        Exit-WithCode $EXIT.Unrecoverable
    }

    if ($State.Attempts -ge $maxTotal) {
        Write-Log ("Retry budget exhausted across runs ({0}/{1}). Operator review required." -f $State.Attempts, $maxTotal) 'ERROR'
        Exit-WithCode $EXIT.RetriesExhausted
    }

    if ($attempt -eq $maxPerRun) {
        Write-Log ("Per-run retry limit reached ({0}). Remediation will be applied, then script exits so RMM/GPO can rerun." -f $maxPerRun) 'WARN'
    } else {
        Write-Log 'Applying remediation and retrying in-session...'
    }

    $already = @($State.AppliedRemediations)
    if ($already -contains $diag.Remediation -and $diag.Remediation -ne 'RetryTransient') {
        Write-Log ("Remediation {0} already applied previously. Escalating to RestoreHealth+CleanArtifacts." -f $diag.Remediation) 'WARN'
        $diag = [pscustomobject]@{
            ErrorCode       = $diag.ErrorCode
            ExtendedCode    = $diag.ExtendedCode
            Phase           = $diag.Phase
            BlockingApps    = $diag.BlockingApps
            BlockingDrivers = $diag.BlockingDrivers
            LogLineSample   = $diag.LogLineSample
            Remediation     = 'RestoreHealth+CleanArtifacts'
            Retryable       = $true
            Reason          = "Escalated after repeated $($diag.Remediation)"
        }
    }

    $ctx = @{
        LogFile           = $LogFile
        LogCallback       = $script:LogCallback
        CleanupScriptPath = $cleanupScript
        ExtraTargetGB     = ($cleanupTarget + 10)
        Tiers             = $cleanupTiers
        StagedIsoPath     = $workingIso
    }
    try {
        Invoke-SetupRemediation -Name $diag.Remediation -Context $ctx
    } catch {
        Write-Log "Remediation threw: $_" 'WARN'
    }
    $State.AppliedRemediations = @($State.AppliedRemediations) + $diag.Remediation
    Save-State $State

    # If we wiped the staged ISO, re-stage before the next attempt.
    if ($diag.Remediation -eq 'RefreshLocalIso' -and $Config.CopyIsoLocally) {
        try {
            $workingIso = Invoke-IsoStage -SourceIso $isoPath -StagingDir $Config.LocalStagingPath
        } catch {
            Write-Log "Re-stage failed: $_" 'ERROR'
            Exit-WithCode $EXIT.IsoNotFound
        }
    }

    if ($attempt -eq $maxPerRun) {
        Write-Log 'Exiting now - next scheduled run will resume with remediation already applied.' 'WARN'
        Exit-WithCode $EXIT.RetryNextRun
    }
}

# Fall-through (shouldn't reach here).
Write-Log 'Unexpected fall-through of retry loop.' 'ERROR'
Exit-WithCode $EXIT.Unhandled
