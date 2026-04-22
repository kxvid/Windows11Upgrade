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
│   └── Invoke-Win11Upgrade.ps1 <- main script (invoked by the .bat)
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
user warning, then exits before mounting or starting Setup.

## What the script does (end-to-end)

1. Requires admin; refuses to run otherwise.
2. Reads current edition + build. If already on the target build
   (`TargetBuild` in config, default `26100` = 24H2), exits clean.
3. Picks the matching ISO (LTSC vs non-LTSC).
4. Verifies free disk space (`MinFreeDiskGB`, default 25 GB) and AC power
   (`RequireAC`).
5. Optionally copies the ISO to `C:\ProgramData\Win11Upgrade\stage` for a
   more reliable install than running setup over SMB.
6. Sends `msg * /TIME:<n> /W <message>` to every active session - pops a
   dialog on the user's screen with a "save your work" warning and a countdown.
   Auto-dismisses after `WarningSeconds` (default 600 = 10 min).
7. Mounts the ISO, runs `setup.exe /auto upgrade /quiet /eula accept
   /dynamicupdate disable /showoobe none /telemetry disable /compat
   IgnoreWarning /copylogs <local log dir>`.
8. Windows Setup stages files and **reboots the machine automatically** to
   finish the upgrade. Total wall time: 30-90 min depending on disk.
9. Logs to `C:\ProgramData\Win11Upgrade\logs\upgrade-<timestamp>.log` on the
   endpoint, and copies to `NetworkLogShare` if configured.

## Config reference (`config\upgrade.config.json`)

| Key                         | What it does                                                                 |
| --------------------------- | ---------------------------------------------------------------------------- |
| `IsoPaths.NonLTSC`          | Relative (to share root) or absolute path to the non-LTSC ISO.               |
| `IsoPaths.LTSC`             | Same, for LTSC.                                                              |
| `TargetBuild`               | Build number that counts as "already upgraded". `26100` = Win11 24H2.        |
| `CopyIsoLocally`            | If true, copies the ISO to the endpoint before mounting. Strongly recommended. |
| `LocalStagingPath`          | Where the local copy goes.                                                   |
| `LogRoot`                   | Where endpoint logs go.                                                      |
| `NetworkLogShare`           | Optional UNC for aggregated logs. Empty = skip.                              |
| `UserWarning.Enabled`       | Turn the user message on/off.                                                |
| `UserWarning.WarningSeconds`| Countdown length in seconds.                                                 |
| `UserWarning.Message`       | Message text. `{MINUTES}` is replaced at runtime.                            |
| `SetupArgs`                 | Arguments passed to `setup.exe`. Edit with care.                             |
| `MinFreeDiskGB`             | Abort if system drive has less than this.                                    |
| `RequireAC`                 | Abort on laptops running on battery.                                         |
| `SkipIfAlreadyBuild`        | Skip machines already at/past `TargetBuild`.                                 |

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
