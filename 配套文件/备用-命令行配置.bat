@echo off
title Claude Code - DeepSeek API setup (backup method)
echo ============================================================
echo  [IMPORTANT] BEFORE running this file:
echo  1. Right-click this file, choose "Edit"
echo  2. Replace  sk-REPLACE-ME-WITH-YOUR-DEEPSEEK-KEY  below
echo     with your REAL DeepSeek API key (from platform.deepseek.com)
echo  3. Save, then double-click to run.
echo  See "AI KaiXiang JiaoShi" app - ZhuangJi XiangDao Step 2 / JiJiuZhan
echo ============================================================
echo.
setx ANTHROPIC_BASE_URL "https://api.deepseek.com/anthropic"
setx ANTHROPIC_AUTH_TOKEN "sk-REPLACE-ME-WITH-YOUR-DEEPSEEK-KEY"
setx ANTHROPIC_MODEL "deepseek-flash[1m]"
setx ANTHROPIC_DEFAULT_SONNET_MODEL "deepseek-flash[1m]"
setx ANTHROPIC_DEFAULT_OPUS_MODEL "deepseek-flash[1m]"
setx ANTHROPIC_DEFAULT_HAIKU_MODEL "deepseek-flash"
setx CLAUDE_CODE_SUBAGENT_MODEL "deepseek-flash"
echo.
echo  Done! Please RESTART Claude Code for changes to take effect.
echo  (PeiZhi wan cheng! Qing zhongqi Claude Code hou sheng xiao.)
echo.
pause
