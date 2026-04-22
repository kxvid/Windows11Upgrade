@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM =====================================================================
REM  Windows 11 In-Place Upgrade Launcher
REM  Place this .bat + sibling folders on a network share. Run as admin
REM  (or deliver via RMM/GPO scheduled task running as SYSTEM).
REM =====================================================================

set "SHARE_ROOT=%~dp0"
if "%SHARE_ROOT:~-1%"=="\" set "SHARE_ROOT=%SHARE_ROOT:~0,-1%"

set "PS_SCRIPT=%SHARE_ROOT%\scripts\Invoke-Win11Upgrade.ps1"
set "CONFIG=%SHARE_ROOT%\config\upgrade.config.json"

REM ----- Require elevation -----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [Win11Upgrade] Elevation required. Relaunching as administrator...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b 0
)

REM ----- Sanity checks -----
if not exist "%PS_SCRIPT%" (
    echo [Win11Upgrade] ERROR: Cannot find %PS_SCRIPT%
    exit /b 2
)
if not exist "%CONFIG%" (
    echo [Win11Upgrade] ERROR: Cannot find %CONFIG%
    exit /b 2
)

echo [Win11Upgrade] Launching upgrade from %SHARE_ROOT%

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" ^
    -ConfigPath "%CONFIG%" ^
    -ShareRoot "%SHARE_ROOT%" %*

set "RC=%ERRORLEVEL%"
echo [Win11Upgrade] Script exited with code %RC%
exit /b %RC%
