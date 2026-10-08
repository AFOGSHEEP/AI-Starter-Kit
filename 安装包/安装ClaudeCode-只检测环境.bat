@echo off
setlocal
title Claude Code - Pre-check only (installs NOTHING)
echo ============================================================
echo   Claude Code - PRE-CHECK ONLY  (check mode, nothing is installed)
echo ------------------------------------------------------------
echo   Checks everything Claude Code needs BEFORE installing:
echo     Node.js (version must be 22 or newer), npm, PATH entries,
echo     free disk space, network / npm mirror, the offline package,
echo     and whether Claude Code is already installed.
echo.
echo   This mode INSTALLS NOTHING and CHANGES NOTHING.
echo   Use it when you just want to know what is missing.
echo ============================================================
echo.
cd /d "%~dp0"
set "PS1=scripts\install-cc.ps1"
if not exist "%PS1%" set "PS1=%~dp0scripts\install-cc.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode Check
if errorlevel 9009 (
  echo.
  echo [X] Cannot start PowerShell on this computer.
  pause
)
endlocal
