<#
.SYNOPSIS
    Diagnoses a failed Windows Setup run and recommends / applies a remediation.

.DESCRIPTION
    Parses setuperr.log / setupact.log under $WINDOWS.~BT\Sources\Panther and
    the CompatData_*.xml blocker reports. Extracts the primary error code,
    extended code, and install phase. Maps the combination to a known
    remediation (RestoreHealth, ResetWindowsUpdate, FreeAdditionalDiskSpace,
    CleanUpgradeArtifacts, RefreshLocalIso, EnableUnsupportedHardwareBypass,
    RetryTransient, or None).

    Exports:
      Get-SetupFailureInfo    - parse-only (no side effects)
      Invoke-SetupRemediation - apply a named remediation

.NOTES
    Error code references:
      https://learn.microsoft.com/windows/deployment/upgrade/upgrade-error-codes
      https://learn.microsoft.com/windows/deployment/upgrade/resolution-procedures
#>

[CmdletBinding()]
param()

$script:PantherRoots = @(
    'C:\$WINDOWS.~BT\Sources\Panther',
    'C:\$WINDOWS.~BT\Sources\Rollback',
    'C:\Windows\Panther'
)

function Write-DiagLog {
    param([string] $Message, [string] $Level = 'INFO', [scriptblock] $LogCallback)
    if ($LogCallback) { & $LogCallback $Message $Level }
    else { Write-Host "[$Level] $Message" }
}

function Get-PantherLogPaths {
    $hits = @()
    foreach ($root in $script:PantherRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($name in 'setuperr.log','setupact.log') {
            $p = Join-Path $root $name
            if (Test-Path -LiteralPath $p) { $hits += Get-Item -LiteralPath $p }
        }
    }
    return $hits | Sort-Object LastWriteTime -Descending
}

function Get-SetupFailureInfo {
<#
.SYNOPSIS
    Parses Panther logs and returns a structured failure report.
.OUTPUTS
    [pscustomobject] @{
        ErrorCode, ExtendedCode, Phase, BlockingApps, BlockingDrivers,
        LogLineSample, Remediation, Retryable, Reason
    }
#>
    [CmdletBinding()]
    param([scriptblock] $LogCallback)

    $info = [ordered]@{
        ErrorCode        = $null
        ExtendedCode     = $null
        Phase            = $null
        BlockingApps     = @()
        BlockingDrivers  = @()
        LogLineSample    = @()
        Remediation      = 'None'
        Retryable        = $false
        Reason           = 'No Panther logs found.'
    }

    $logs = Get-PantherLogPaths
    if (-not $logs) {
        return [pscustomobject]$info
    }

    # Hex code extractor (primary error + optional extended code "0xC1900101 - 0x20017")
    $primaryPattern = '(0x[0-9A-Fa-f]{8})(?:\s*[-–]\s*(0x[0-9A-Fa-f]{4,8}))?'
    $phasePattern   = '(SafeOS|FirstBoot|SecondBoot|Preinstall|Downlevel|Rollback)'

    $errContent = $logs | Where-Object { $_.Name -eq 'setuperr.log' } |
        Select-Object -First 1 |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 400 -ErrorAction SilentlyContinue }
    $actContent = $logs | Where-Object { $_.Name -eq 'setupact.log' } |
        Select-Object -First 1 |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 800 -ErrorAction SilentlyContinue }

    $sample = @()
    if ($errContent) {
        # Scan from the end - the final error is the one we care about.
        for ($i = $errContent.Count - 1; $i -ge 0 -and -not $info.ErrorCode; $i--) {
            $line = $errContent[$i]
            if ($line -match $primaryPattern) {
                $info.ErrorCode    = $Matches[1].ToUpper()
                $info.ExtendedCode = if ($Matches[2]) { $Matches[2].ToUpper() } else { $null }
                $sample += $line
            }
        }
        if ($errContent.Count) {
            $sample += ($errContent | Select-Object -Last 10)
        }
    }
    if ($actContent -and -not $info.ErrorCode) {
        for ($i = $actContent.Count - 1; $i -ge 0 -and -not $info.ErrorCode; $i--) {
            $line = $actContent[$i]
            if ($line -match 'Result\s*=\s*' + $primaryPattern) {
                $info.ErrorCode    = $Matches[1].ToUpper()
                $info.ExtendedCode = if ($Matches[2]) { $Matches[2].ToUpper() } else { $null }
                $sample += $line
            }
        }
    }
    if ($actContent) {
        foreach ($line in $actContent) {
            if ($line -match $phasePattern) {
                $info.Phase = $Matches[1]
            }
        }
    }
    $info.LogLineSample = $sample | Select-Object -Last 20

    # Compat blockers (CompatData_*.xml)
    foreach ($root in $script:PantherRoots) {
        $xmlDir = $root
        if (-not (Test-Path -LiteralPath $xmlDir)) { continue }
        $xmls = Get-ChildItem -LiteralPath $xmlDir -Filter 'CompatData_*.xml' -ErrorAction SilentlyContinue
        foreach ($x in $xmls) {
            try {
                [xml]$doc = Get-Content -LiteralPath $x.FullName -Raw -ErrorAction Stop
                foreach ($pkg in $doc.SelectNodes('//Program')) {
                    if ($pkg.Name) { $info.BlockingApps += $pkg.Name }
                }
                foreach ($drv in $doc.SelectNodes('//Driver')) {
                    if ($drv.ServiceName) { $info.BlockingDrivers += $drv.ServiceName }
                }
            } catch { }
        }
    }
    $info.BlockingApps    = @($info.BlockingApps    | Select-Object -Unique)
    $info.BlockingDrivers = @($info.BlockingDrivers | Select-Object -Unique)

    # ---- Map code -> remediation -----------------------------------------
    $map = switch ($info.ErrorCode) {
        '0xC1900101' {
            # Driver error (most common). Extended code narrows the phase
            # but the remediation is the same: heal component store + wipe
            # the partial upgrade artifacts, then retry.
            @{ Remediation='RestoreHealth+CleanArtifacts'; Retryable=$true
               Reason="Driver-related setup failure (C1900101/$($info.ExtendedCode))." }
        }
        '0xC1900107' {
            @{ Remediation='CleanUpgradeArtifacts'; Retryable=$true
               Reason='Previous upgrade cleanup pending - clearing $WINDOWS.~BT/~WS and retrying.' }
        }
        '0xC1900200' { @{ Remediation='EnableUnsupportedHardwareBypass'; Retryable=$true; Reason='System does not meet Win11 minimums; will attempt TPM/CPU bypass registry key.' } }
        '0xC1900202' { @{ Remediation='EnableUnsupportedHardwareBypass'; Retryable=$true; Reason='System does not meet Win11 minimums; will attempt TPM/CPU bypass registry key.' } }
        '0xC1900208' {
            @{ Remediation='None'; Retryable=$false
               Reason=("Incompatible app(s) blocking upgrade: {0}" -f (($info.BlockingApps | Select-Object -First 10) -join ', ')) }
        }
        '0x80070070' { @{ Remediation='FreeAdditionalDiskSpace'; Retryable=$true; Reason='Out of disk space during setup; re-running cleanup at a higher target.' } }
        '0x80073712' { @{ Remediation='RestoreHealth';          Retryable=$true; Reason='Component store corruption; running DISM RestoreHealth + sfc.' } }
        '0x80240017' { @{ Remediation='ResetWindowsUpdate';     Retryable=$true; Reason='Windows Update client error; resetting WU components.' } }
        '0x80240020' { @{ Remediation='None';                   Retryable=$false; Reason='Setup blocked by an active interactive session. Schedule outside logon window.' } }
        '0x80070002' { @{ Remediation='RefreshLocalIso';        Retryable=$true; Reason='Setup reported missing files; re-staging ISO from share.' } }
        '0x80070003' { @{ Remediation='RefreshLocalIso';        Retryable=$true; Reason='Setup reported missing path; re-staging ISO from share.' } }
        '0x8007042B' { @{ Remediation='RetryTransient';         Retryable=$true; Reason='Setup process terminated unexpectedly; retrying.' } }
        '0x800F0922' { @{ Remediation='CleanUpgradeArtifacts';  Retryable=$true; Reason='Install-stage failure; clearing artifacts and retrying.' } }
        default {
            if ($info.ErrorCode) {
                @{ Remediation='RestoreHealth+CleanArtifacts'; Retryable=$true
                   Reason="Unrecognized setup error $($info.ErrorCode); attempting generic repair + retry." }
            } else {
                @{ Remediation='RetryTransient'; Retryable=$true
                   Reason='No explicit error code located in Panther; assuming transient and retrying once.' }
            }
        }
    }

    $info.Remediation = $map.Remediation
    $info.Retryable   = [bool]$map.Retryable
    $info.Reason      = $map.Reason

    return [pscustomobject]$info
}

# --------------------------- Remediations ---------------------------------

function Repair-ComponentStore {
    param([scriptblock] $LogCallback)
    Write-DiagLog 'DISM /Online /Cleanup-Image /RestoreHealth (may take several minutes)' 'INFO' $LogCallback
    & dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1 | ForEach-Object { Write-DiagLog "  dism: $_" 'INFO' $LogCallback }
    Write-DiagLog 'sfc /scannow' 'INFO' $LogCallback
    & sfc.exe /scannow 2>&1 | ForEach-Object { Write-DiagLog "  sfc: $_" 'INFO' $LogCallback }
}

function Reset-WindowsUpdateStack {
    param([scriptblock] $LogCallback)
    $services = 'wuauserv','cryptsvc','bits','msiserver','appidsvc','dosvc'
    foreach ($s in $services) { try { Stop-Service $s -Force -ErrorAction SilentlyContinue } catch {} }
    Start-Sleep -Seconds 2
    $renames = @(
        "$env:SystemRoot\SoftwareDistribution",
        "$env:SystemRoot\System32\catroot2"
    )
    foreach ($p in $renames) {
        if (Test-Path -LiteralPath $p) {
            $bak = "$p.old-$(Get-Date -Format yyyyMMddHHmmss)"
            try { Rename-Item -LiteralPath $p -NewName (Split-Path $bak -Leaf) -ErrorAction Stop; Write-DiagLog "Renamed $p -> $bak" 'OK' $LogCallback }
            catch { Write-DiagLog "Rename $p failed: $_" 'WARN' $LogCallback }
        }
    }
    foreach ($s in $services) { try { Start-Service $s -ErrorAction SilentlyContinue } catch {} }
}

function Clear-UpgradeArtifacts {
    param([scriptblock] $LogCallback)
    $targets = 'C:\$WINDOWS.~BT','C:\$WINDOWS.~WS','C:\$GetCurrent','C:\$Windows.~Q'
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t)) { continue }
        Write-DiagLog "Removing $t" 'INFO' $LogCallback
        # Try the cheap path first; only escalate to takeown if it fails.
        Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $t) {
            Write-DiagLog "  plain delete left residue; escalating with takeown/icacls" 'WARN' $LogCallback
            & takeown.exe /f $t /r /d y  | Out-Null
            & icacls.exe  $t /grant "*S-1-5-32-544:(F)" /t /c /q | Out-Null
            Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Enable-UnsupportedHardwareBypass {
    param([scriptblock] $LogCallback)
    $key = 'HKLM:\SYSTEM\Setup\MoSetup'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -PropertyType DWord -Value 1 -Force | Out-Null
    Write-DiagLog 'Set AllowUpgradesWithUnsupportedTPMOrCPU = 1 under MoSetup.' 'OK' $LogCallback
}

function Invoke-ExtraDiskCleanup {
    param(
        [int] $ExtraTargetGB,
        [string[]] $Tiers,
        [string] $LogFile,
        [scriptblock] $LogCallback,
        [string] $CleanupScriptPath
    )
    if (-not (Test-Path -LiteralPath $CleanupScriptPath)) {
        Write-DiagLog "Cleanup script missing at $CleanupScriptPath" 'ERROR' $LogCallback
        return
    }
    Write-DiagLog "Re-running cleanup with target ${ExtraTargetGB} GB" 'INFO' $LogCallback
    & $CleanupScriptPath -TargetFreeGB $ExtraTargetGB -Tiers $Tiers -LogFile $LogFile | Out-Null
}

function Invoke-SetupRemediation {
<#
.SYNOPSIS
    Applies a named remediation returned by Get-SetupFailureInfo.
.PARAMETER Name
    One of: RestoreHealth, ResetWindowsUpdate, CleanUpgradeArtifacts,
    RestoreHealth+CleanArtifacts, FreeAdditionalDiskSpace,
    EnableUnsupportedHardwareBypass, RefreshLocalIso, RetryTransient, None.
.PARAMETER Context
    Hashtable carrying remediation-specific parameters:
      LogFile, LogCallback, CleanupScriptPath, ExtraTargetGB, Tiers,
      StagedIsoPath (for RefreshLocalIso)
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [hashtable] $Context
    )

    $cb = $Context.LogCallback

    switch ($Name) {
        'None'              { Write-DiagLog 'No remediation available - failure is not auto-recoverable.' 'WARN' $cb }
        'RetryTransient'    { Write-DiagLog 'Transient failure assumed - retrying without remediation.' 'INFO' $cb }
        'RestoreHealth'     { Repair-ComponentStore -LogCallback $cb }
        'ResetWindowsUpdate'{ Reset-WindowsUpdateStack -LogCallback $cb }
        'CleanUpgradeArtifacts' { Clear-UpgradeArtifacts -LogCallback $cb }
        'RestoreHealth+CleanArtifacts' {
            Clear-UpgradeArtifacts -LogCallback $cb
            Repair-ComponentStore  -LogCallback $cb
        }
        'FreeAdditionalDiskSpace' {
            Invoke-ExtraDiskCleanup `
                -ExtraTargetGB $Context.ExtraTargetGB `
                -Tiers $Context.Tiers `
                -LogFile $Context.LogFile `
                -LogCallback $cb `
                -CleanupScriptPath $Context.CleanupScriptPath
        }
        'EnableUnsupportedHardwareBypass' {
            Enable-UnsupportedHardwareBypass -LogCallback $cb
        }
        'RefreshLocalIso' {
            if ($Context.StagedIsoPath -and (Test-Path -LiteralPath $Context.StagedIsoPath)) {
                Remove-Item -LiteralPath $Context.StagedIsoPath -Force -ErrorAction SilentlyContinue
                Write-DiagLog "Deleted stale staged ISO $($Context.StagedIsoPath); caller will re-stage." 'OK' $cb
            }
        }
        default { Write-DiagLog "Unknown remediation '$Name' - skipping." 'WARN' $cb }
    }
}
