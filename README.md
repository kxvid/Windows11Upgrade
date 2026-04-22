# Windows 11 In-Place Upgrade (LTSC + non-LTSC)

Automates the Windows 11 in-place upgrade for enterprise endpoints. Auto-detects
whether the target needs **LTSC** or **non-LTSC** media from the current edition,
warns the logged-on user, then launches Windows Setup unattended. Windows Setup
handles reboots.

## Repo layout

```
Windows11Upgrade\
├── Deploy-Win11Upgrade.bat     <- entry point (run from share)
├── config\
│   └── upgrade.config.json     <- paths, timings, setup flags
├── scripts\
│   ├── Invoke-Win11Upgrade.ps1     <- main script (invoked by the .bat)
│   ├── Invoke-DiskCleanup.ps1      <- tiered auto-cleanup, called on low disk
│   └── Invoke-SetupDiagnostics.ps1 <- Panther log parser + remediation table
├── ISOs\
│   ├── README.txt
│   ├── Win11_Enterprise.iso       (you provide - gitignored)
│   └── Win11_Enterprise_LTSC.iso  (you provide - gitignored)
└── logs\                        <- local runtime logs (gitignored)
```

## One-time setup

1. **Clone / copy this folder onto a network share** reachable by every endpoint,
   e.g. `\\fileserver\IT\Win11Upgrade\`.
2. **Drop your ISOs** into the `ISOs\` folder on the share:
   - `Win11_Enterprise.iso` - your regular Win11 Enterprise/Pro media.
   - `Win11_Enterprise_LTSC.iso` - IoT Enterprise LTSC 2024 (or whatever LTSC
     build you are standardising on).
   - If you prefer different filenames, edit `config\upgrade.config.json`.
3. **Grant the machine accounts (or a dedicated deployment account) read access**
   to the share. If you deliver via RMM/GPO running as SYSTEM, give `Domain
   Computers` read access.
4. **(Optional)** Set `NetworkLogShare` in `upgrade.config.json` to a writable
   UNC path so each endpoint drops its upgrade log there for audit.

## How edition detection works

The script reads `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\EditionID`
and `ProductName`. EditionIDs ending in `S` (e.g. `EnterpriseS`,
`IoTEnterpriseS`) and any product name containing `LTSC`/`LTSB` are treated as
LTSC and receive the LTSC ISO. Everything else gets the non-LTSC ISO. No
hostname/OU rules required.

## Deploying

Any mechanism that can run a `.bat` on the endpoint with admin rights will work.
Three common options:

### Option A - Interactive (admin right-clicks and runs it)
Just have an admin open `\\fileserver\IT\Win11Upgrade\Deploy-Win11Upgrade.bat`
with "Run as administrator". The bat self-elevates if needed.

### Option B - GPO scheduled task (recommended for mass rollout)
Create a Group Policy preference scheduled task that runs as `NT AUTHORITY\SYSTEM`:
- **Program**: `\\fileserver\IT\Win11Upgrade\Deploy-Win11Upgrade.bat`
- **Run with highest privileges**: yes
- **Trigger**: at logon, or a specific window (e.g. 22:00 Tue)
- Give `Domain Computers` read on the share.

### Option C - RMM / SCCM / Intune Win32 app
Point the agent at the bat. Agent already runs as SYSTEM.

## Test run

On one pilot box, open an elevated cmd and:

```
\\fileserver\IT\Win11Upgrade\Deploy-Win11Upgrade.bat
```

To preflight without actually upgrading:

```
powershell -ExecutionPolicy Bypass -File ^
  \\fileserver\IT\Win11Upgrade\scripts\Invoke-Win11Upgrade.ps1 ^
  -ConfigPath \\fileserver\IT\Win11Upgrade\config\upgrade.config.json ^
  -ShareRoot  \\fileserver\IT\Win11Upgrade ^
  -Preflight
```

`-Preflight` runs edition detection, ISO resolution, disk/power checks and the
user warning, then exits before mounting or starting Setup. It emits a JSON
summary (host, edition, build, free GB, chosen ISO, current retry state,
would-skip flag) to stdout so pilot rollouts can aggregate results.

Pass `-ResetState` to wipe the persisted retry state — useful after an
operator has fixed a blocker the script can't resolve itself (e.g. uninstalled
a blocking app).

## What the script does (end-to-end)

1. Requires admin; refuses to run otherwise.
2. Reads current edition, build, and `DisplayVersion`. If already on the target
   release (`TargetDisplayVersion` match, else `TargetBuild`), exits clean.
3. Picks the matching ISO (LTSC vs non-LTSC).
4. Verifies free disk space (`MinFreeDiskGB`, default 25 GB). If below, runs
   `Invoke-DiskCleanup.ps1` in tiered order, stopping as soon as
   `AutoCleanup.TargetFreeGB` is reached. Aborts only if cleanup still can't
   reach `MinFreeDiskGB`. Verifies AC power (`RequireAC`).
5. Optionally stages the ISO locally to `C:\ProgramData\Win11Upgrade\stage`
   using **robocopy `/J /MT:8`** (far faster than `Copy-Item` over SMB). Skips
   the copy entirely if the local file already matches source size + mtime.
   Staging runs **in a background job** so the user-warning countdown in the
   next step overlaps with it — wall time is `max(warn, copy)` instead of the
   sum.
6. Sends `msg * /TIME:<n> /W <message>` to every active session — pops a
   dialog on the user's screen with a "save your work" warning and a countdown.
   Auto-dismisses after `WarningSeconds` (default 600 = 10 min).
7. Mounts the ISO (polls up to 15 s for a drive letter), runs
   `setup.exe /auto upgrade /quiet /eula accept /dynamicupdate disable
   /showoobe none /telemetry disable /compat IgnoreWarning /copylogs
   <local log dir>`, then dismounts in a `finally` block so a killed script
   can't leave the ISO mounted.
8. **If setup.exe fails**, the self-healing loop kicks in (see next section).
9. On success, Windows Setup stages files and **reboots the machine
   automatically** to finish the upgrade. Total wall time: 30-90 min depending
   on disk.
10. Logs to `C:\ProgramData\Win11Upgrade\logs\upgrade-<timestamp>.log` on the
    endpoint, and copies to `NetworkLogShare` if configured. Logs older than
    30 days in `LogRoot` are auto-rotated on each run.

## Self-healing / auto-retry

On any non-zero `setup.exe` exit the script:

1. **Tails** `C:\$WINDOWS.~BT\Sources\Panther\setuperr.log` into the upgrade
   log so you see the final 30 lines at a glance.
2. **Diagnoses** the failure: extracts the primary error code, extended code,
   phase (SafeOS / FirstBoot / SecondBoot / Rollback), and any blocking apps
   or drivers from `CompatData_*.xml`.
3. **Applies a targeted remediation** from the table below.
4. **Retries** `setup.exe` in-session up to `Retry.MaxAttemptsPerRun`.
5. **Persists state** to `C:\ProgramData\Win11Upgrade\logs\state.json`. If the
   in-run budget is exhausted, the script exits with code `10` and the *next*
   run (RMM / scheduled task) resumes from where it left off, until
   `Retry.MaxAttemptsTotal` is reached. Clear state manually with `-ResetState`.

### Error → remediation mapping

| Setup error                                | Remediation applied                             | Retryable |
| ------------------------------------------ | ----------------------------------------------- | --------- |
| `0xC1900101` (any ext — driver failure)    | `CleanUpgradeArtifacts` + DISM `RestoreHealth` + `sfc`  | yes |
| `0xC1900107` (prior upgrade pending)       | `CleanUpgradeArtifacts` (wipes `$WINDOWS.~BT/~WS`)      | yes |
| `0xC1900200` / `0xC1900202` (req not met)  | Sets `AllowUpgradesWithUnsupportedTPMOrCPU = 1`         | yes |
| `0xC1900208` (incompatible app blocker)    | Logs blocking apps from `CompatData_*.xml` and stops    | **no**, operator must uninstall |
| `0x80070070` (disk full mid-install)       | Re-runs `Invoke-DiskCleanup.ps1` at `TargetFreeGB + 10` | yes |
| `0x80073712` (corrupt component store)     | DISM `RestoreHealth` + `sfc /scannow`                   | yes |
| `0x80240017` (WU client error)             | Resets WU stack (stop services, rename `SoftwareDistribution` + `catroot2`) | yes |
| `0x80240020` (active interactive session)  | Stops (schedule outside logon window)                   | **no** |
| `0x80070002` / `0x80070003` (missing files)| Deletes staged ISO; next attempt re-stages from share   | yes |
| `0x8007042B` (process died)                | Plain retry — treated as transient                      | yes |
| `0x800F0922` (install-stage failure)       | `CleanUpgradeArtifacts` + retry                         | yes |
| unknown / missing error                    | Escalates to `RestoreHealth + CleanUpgradeArtifacts`, then retry | yes |

The script never auto-uninstalls apps, resizes partitions, or force-installs
drivers — it surfaces those blockers in the log for operator action.

If the same remediation has already been applied in an earlier attempt, the
script escalates to `RestoreHealth + CleanUpgradeArtifacts` rather than
looping.

### Exit codes

| Code | Meaning                                                         |
| ---- | --------------------------------------------------------------- |
| `0`  | Upgrade phase 1 complete (reboot pending) or already on target. |
| `2`  | Config file missing / invalid JSON / missing required key.      |
| `3`  | Disk space insufficient, cleanup didn't recover enough.         |
| `4`  | On battery (RequireAC was set).                                 |
| `5`  | Not elevated.                                                   |
| `6`  | ISO not found at the configured path.                           |
| `7`  | Mount / dismount infrastructure failure.                        |
| `8`  | Retry budget (`MaxAttemptsTotal`) exhausted. Operator review.   |
| `9`  | Unrecoverable setup failure (e.g. blocking apps).               |
| `10` | Per-run retry budget used; next scheduled run will resume.      |
| `99` | Unhandled exception (check log).                                |

## Config reference (`config\upgrade.config.json`)

| Key                         | What it does                                                                 |
| --------------------------- | ---------------------------------------------------------------------------- |
| `IsoPaths.NonLTSC`          | Relative (to share root) or absolute path to the non-LTSC ISO.               |
| `IsoPaths.LTSC`             | Same, for LTSC.                                                              |
| `TargetBuild`               | Build number that counts as "already upgraded". `26100` = Win11 24H2.        |
| `TargetDisplayVersion`      | Optional. `DisplayVersion` string (e.g. `"24H2"`, `"25H2"`). Matched before `TargetBuild`. |
| `CopyIsoLocally`            | If true, copies the ISO to the endpoint before mounting. Strongly recommended. |
| `LocalStagingPath`          | Where the local copy goes.                                                   |
| `LogRoot`                   | Where endpoint logs go.                                                      |
| `NetworkLogShare`           | Optional UNC for aggregated logs. Empty = skip.                              |
| `UserWarning.Enabled`       | Turn the user message on/off.                                                |
| `UserWarning.WarningSeconds`| Countdown length in seconds.                                                 |
| `UserWarning.Message`       | Message text. `{MINUTES}` is replaced at runtime.                            |
| `SetupArgs`                 | Arguments passed to `setup.exe`. Edit with care.                             |
| `MinFreeDiskGB`             | Abort if system drive has less than this after any cleanup.                  |
| `RequireAC`                 | Abort on laptops running on battery.                                         |
| `SkipIfAlreadyBuild`        | Skip machines already at/past `TargetBuild`.                                 |
| `AutoCleanup.Enabled`       | If true and free disk < `MinFreeDiskGB`, run tiered cleanup before aborting. |
| `AutoCleanup.TargetFreeGB`  | Cleanup stops as soon as this many GB are free. Default 30.                  |
| `AutoCleanup.Tiers`         | Ordered list of tiers to run (remove any you don't want - see below).        |
| `Retry.MaxAttemptsPerRun`   | setup.exe attempts within a single invocation before exiting (default `2`).  |
| `Retry.MaxAttemptsTotal`    | Total attempts across all invocations before giving up (default `5`).        |

## Auto-cleanup tiers

Run by `scripts\Invoke-DiskCleanup.ps1` in order; stops as soon as
`TargetFreeGB` is reached. Never touches Documents, Downloads, Desktop, or
anything under user profiles except temp/crash-dump caches.

| Tier                   | What it deletes                                                    | Typical gain |
| ---------------------- | ------------------------------------------------------------------ | ------------ |
| `Temp`                 | `%TEMP%`, `C:\Windows\Temp`, per-user AppData\Local\Temp (>1 day)  | 0.5-3 GB     |
| `RecycleBin`           | All drives                                                          | varies       |
| `DeliveryOptimization` | Win Update peer cache                                              | 0-5 GB       |
| `WindowsUpdate`        | `C:\Windows\SoftwareDistribution\Download` (stops wuauserv/bits)   | 1-10 GB      |
| `CrashDumps`           | MEMORY.DMP, Minidump, WER queues, per-user CrashDumps              | 0-20 GB      |
| `ComponentStore`       | `DISM /StartComponentCleanup /ResetBase` (slow, 5-15 min)          | 1-5 GB       |
| `UpgradeArtifacts`     | `C:\Windows.old`, `$WINDOWS.~BT`, `$WINDOWS.~WS`, `$GetCurrent`    | 10-30 GB     |

Remove tiers from `AutoCleanup.Tiers` to disable them. Running
`UpgradeArtifacts` deletes `C:\Windows.old`, which removes the ability to roll
back to the *previous* Windows install - the new upgrade creates a fresh
Windows.old, so this is safe before an upgrade but not between upgrades.

## Troubleshooting

- **`setup.exe` returns non-zero**: check `C:\$WINDOWS.~BT\Sources\Panther\setuperr.log`
  and `setupact.log`. The script also copies setup logs to `LogRoot`.
- **`msg.exe` not found**: Win11 Home lacks it. Enterprise/Pro/LTSC all have it.
- **Mount fails over SMB**: set `CopyIsoLocally: true` (default).
- **Bypassing TPM/CPU checks**: `/compat IgnoreWarning` is already in the
  default `SetupArgs`. If Setup still refuses on unsupported hardware, the
  regulated workaround is the `HKLM\SYSTEM\Setup\MoSetup\AllowUpgradesWithUnsupportedTPMOrCPU`
  DWORD = 1. Add that separately via GPO - not set here because most enterprise
  fleets meet requirements.
- **Non-admin user runs the bat**: it self-elevates via UAC. For silent mass
  deployment run it as SYSTEM (Option B or C above).
