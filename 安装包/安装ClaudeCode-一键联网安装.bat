@echo off
title Install Claude Code (China mirror, one click)
echo ============================================================
echo   Install Claude Code - one click (via npmmirror China CDN)
echo   (An Zhuang Claude Code: Yi Jian Lian Wang An Zhuang)
echo   STEP 1: install node-v22.23.3-x64.msi (same folder) FIRST
echo   STEP 2: run THIS file
echo ============================================================
echo.

where node >nul 2>nul
if errorlevel 1 (
  echo [X] Node.js NOT found!
  echo     Please double-click  node-v22.23.3-x64.msi  in this folder,
  echo     click Next-Next-Install, finish it, THEN run this file again.
  echo.
  pause
  exit /b 1
)

echo [1/4] Node.js detected:
node -v
echo.

echo [2/4] Switching npm to China mirror (npmmirror.com) ...
call npm config set registry https://registry.npmmirror.com
echo       done.
echo.

echo [3/4] Installing Claude Code, please wait 1-3 minutes ...
call npm install -g @anthropic-ai/claude-code
if errorlevel 1 (
  echo.
  echo [X] Install failed. Check your internet and run this file again.
  echo     If it keeps failing, use the "AI ZhuangJi TiJian ZhuShou" menu 2.
  echo.
  pause
  exit /b 1
)
echo.

echo [4/4] Verifying installation ...
call claude --version
echo.
echo ============================================================
echo   [OK] Claude Code installed successfully!
echo   (An Zhuang cheng gong!)
echo.
echo   NEXT STEPS:
echo   1. Install  CC-Switch-v4.0.4-Windows.msi  (same folder)
echo   2. Open CC Switch, add DeepSeek provider with your sk- key
echo   3. Run "AI ZhuangJi TiJian ZhuShou" in folder 配套文件
echo      to verify everything is GREEN.
echo.
echo   Remember: a black terminal window is NORMAL for Claude Code.
echo   Just type and chat. No coding needed.
echo ============================================================
echo.
pause
