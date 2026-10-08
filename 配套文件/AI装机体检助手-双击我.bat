@echo off
title AI Setup Doctor (AI ZhuangJi TiJian ZhuShou)
echo ============================================================
echo   AI Setup Doctor - starting local health check...
echo   (AI ZhuangJian TiJian ZhuShou - ben di yun xing)
echo ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-ai.ps1"
echo.
echo (Window will close after you press a key...)
pause >nul
