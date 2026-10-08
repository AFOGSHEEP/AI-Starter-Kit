@echo off
title AI Setup Wizard (log window)
echo ============================================================
echo   AI Setup Wizard
echo   The GUIDE PAGE has been opened in your browser
echo   automatically (Zhi Yin Ye Mian Yi Da Kai).
echo   This black window only shows the work log - keep it
echo   open until the browser page shows DONE.
echo   If your antivirus asks, please ALLOW it.
echo ============================================================
for %%f in ("%~dp0*.html") do start "" "%%f"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0wizard.ps1"
echo.
echo (Wizard finished. You may close this window.)
pause >nul
