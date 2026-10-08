@echo off
setlocal
title Install Claude Code - OFFLINE (pre-check + auto fix)
echo ============================================================
echo   Install Claude Code - OFFLINE edition  (installer v2.0)
echo ------------------------------------------------------------
echo   No internet needed. Everything comes from this folder.
echo   What it does now:
echo     STEP A. Pre-check: Node.js version, npm, PATH, disk space,
echo             integrity of the bundled offline package.
echo     STEP B. If Node.js / npm is missing it TELLS you first, then
echo             installs it FOR you automatically (Node.js included).
echo     STEP C. Copy the bundled Claude Code, then verify it works.
echo   Keep this window open until it prints DONE.
echo ============================================================
echo.
cd /d "%~dp0"
set "PS1=scripts\install-cc.ps1"
if not exist "%PS1%" set "PS1=%~dp0scripts\install-cc.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode Offline
if errorlevel 9009 (
  echo.
  echo [X] Cannot start PowerShell on this computer.
  echo     Read the install guide txt in this folder, section "Plan C",
  echo     for pure manual steps that always work.
  pause
)
endlocal
