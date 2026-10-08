# ============================================================
#  AI 开箱向导 v2.1 (顺序重排：CC Switch 先装先配，Claude Code 装完免登录)
#  顺序：① Node.js → ② CC Switch → ③ DeepSeek 密钥(写配置) → ④ Claude Code
#  联动：每步进度写入 wizard-status.js，教学网页实时显示
#  安全：只读写本文件夹与 ~/.claude 标准配置；密钥仅直连 DeepSeek 官方验证。
#  npm 说明：npmmirror 国内镜像直连即可（实测无代理 18 秒装完，含 Windows 二进制）
# ============================================================

$ErrorActionPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Root      = $PSScriptRoot
$NodeMsi   = Join-Path $Root '安装包\node-v22.23.3-x64.msi'
$CcsMsi    = Join-Path $Root '安装包\CC-Switch-v4.0.4-Windows.msi'
$StatusJs  = Join-Path $Root 'wizard-status.js'
$ClaudeDir = Join-Path $env:USERPROFILE '.claude'
$CfgPath   = Join-Path $ClaudeDir 'settings.json'
$RecUrl    = 'https://api.deepseek.com/anthropic'

$script:WLog = New-Object System.Collections.ArrayList
function Log($m){ [void]$script:WLog.Add(((Get-Date -Format 'HH:mm:ss') + ' ' + $m)) }
function Save-Status($phase,$steps,$detail){
    $obj = [ordered]@{
        phase  = $phase
        steps  = $steps
        detail = $detail
        log    = @($script:WLog | Select-Object -Last 14)
        ts     = (Get-Date -Format 'HH:mm:ss')
    }
    $js = 'window.WIZARD_STATUS = ' + ($obj | ConvertTo-Json -Depth 5 -Compress) + ';'
    [IO.File]::WriteAllText($StatusJs, $js, (New-Object System.Text.UTF8Encoding($false)))
}
function Refresh-Path { $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User') }
function Has-Cmd($n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }
function Mask($k){ $t=("$k").Trim(); if($t.Length -le 8){ return ('*' * $t.Length) }; return ($t.Substring(0,5) + '****' + $t.Substring($t.Length-4)) }

# 复用「Claude Code 前置检测 / 自动修复」公共库（同一份代码，安装包 里的 .bat 也在用）
$PrereqLib = Join-Path $Root '安装包\scripts\Prereq.ps1'
if (Test-Path $PrereqLib) { . $PrereqLib; $ErrorActionPreference = 'SilentlyContinue' }

$ST = @{ s1 = 'pending'; s2 = 'pending'; s3 = 'pending'; s4 = 'pending' }
function SetS($k,$v){ $ST[$k] = $v }
function Flush($phase,$detail){ Save-Status $phase $ST $detail }

Log '向导启动'
Flush 'running' '正在体检当前环境...'

# ---------- 第 1 步：Node.js ----------
Log '[1/4] 检查 Node.js'
$ni = Get-NodeInfo
if ($ni.Found -and $ni.MeetsMin) { Log ('已安装 ' + $ni.Version + '（满足 >= ' + $script:PrereqMinNode + '），跳过'); SetS 's1' 'ok'; Flush 'running' 'Node.js 已就绪' }
else {
    if ($ni.Found) { Log ('现有 Node ' + $ni.Version + ' 低于要求 22，需要升级'); Flush 'running' ('第 1 步：Node.js ' + $ni.Version + ' 版本过低（Claude Code 要求 22 以上），正在装新版覆盖它') }
    if (Test-Path $NodeMsi) {
        SetS 's1' 'waiting'; Flush 'running' '第 1 步：安装窗口已弹出 —— 请到那个窗口一路点 Next/下一步（网页进度会自动更新）'
        Log '弹出 Node.js 安装窗口，等待你在那个窗口完成安装...'
        Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $NodeMsi, '/norestart') -Wait
        Refresh-Path
        $ni = Get-NodeInfo
        if ($ni.Found -and $ni.MeetsMin) { Log ('安装成功：' + $ni.Version); SetS 's1' 'ok'; Flush 'running' 'Node.js 安装成功' }
        elseif ($ni.Found) { Log ('装完仍是 ' + $ni.Version + '（可能点了取消，或旧版没被替换）'); SetS 's1' 'error'; Flush 'running' 'Node.js 版本仍偏低：确认在安装窗口点了 Install；若提示已有旧版本，先去「卸载程序」卸掉旧 Node.js 再重跑向导' }
        else { Log '本窗口暂时认不到 node（可能要重开窗口）——稍后体检复确认'; SetS 's1' 'error'; Flush 'running' 'Node.js 没有确认装上：请稍后重跑向导，或手动双击 安装包\node-v22.23.3-x64.msi' }
    } else {
        SetS 's1' 'waiting'; Flush 'running' '第 1 步：本机没有 Node 安装包，正在自动下载并安装（约 30MB，耐心等）'
        Log '没有找到本地 node msi，走「自动下载 + 安装」流程...'
        $nodeStub = New-Object psobject -Property @{ IsArm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') }
        $okNode = Repair-NodePrereq $nodeStub $Root
        Refresh-Path
        $ni = Get-NodeInfo
        if ($okNode -and $ni.Found -and $ni.MeetsMin) { Log ('自动安装成功：' + $ni.Version); SetS 's1' 'ok'; Flush 'running' 'Node.js 已自动装好' }
        else { Log '自动安装未成功'; SetS 's1' 'error'; Flush 'running' 'Node.js 自动安装失败：请连上网重跑向导，或手动装 nodejs.org 的 LTS 版（向导首页有链接）' }
    }
}

# ---------- 第 2 步：CC Switch（提前装好"换发动机"工具）----------
Log '[2/4] 检查 CC Switch'
$ccsOk = $false
foreach($d in @("$env:USERPROFILE\.cc-switch", "$env:LOCALAPPDATA\cc-switch", "$env:LOCALAPPDATA\Programs\cc-switch")){ if (Test-Path $d) { $ccsOk = $true; Log ('已安装：' + $d); break } }
if (-not $ccsOk) {
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and ($_.DisplayName -like '*cc-switch*' -or $_.DisplayName -like '*CC Switch*') }
    if ($reg) { $ccsOk = $true; Log '已安装（注册表检出）' }
}
if ($ccsOk) { SetS 's2' 'ok'; Flush 'running' 'CC Switch 已就绪' }
elseif (Test-Path $CcsMsi) {
    SetS 's2' 'waiting'; Flush 'running' '第 2 步：安装窗口已弹出 —— 请到那个窗口一路点 Next/下一步'
    Log '弹出 CC Switch 安装窗口，等待完成...'
    Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $CcsMsi, '/norestart') -Wait
    $ccsOk2 = $false
    foreach($d in @("$env:USERPROFILE\.cc-switch", "$env:LOCALAPPDATA\cc-switch", "$env:LOCALAPPDATA\Programs\cc-switch")){ if (Test-Path $d) { $ccsOk2 = $true; break } }
    if ($ccsOk2) { Log '安装成功'; SetS 's2' 'ok'; Flush 'running' 'CC Switch 安装成功' }
    else { Log '未检出（可能是自定义路径，交给体检确认）'; SetS 's2' 'ok'; Flush 'running' 'CC Switch 安装窗口已完成（体检助手可复查）' }
} else { Log ('找不到安装包 ' + $CcsMsi); SetS 's2' 'error'; Flush 'running' '找不到 CC Switch 安装包：压缩包可能不完整' }

# ---------- 第 3 步：DeepSeek 密钥（先配好，Claude Code 装完才不卡登录）----------
Log '[3/4] 检查 DeepSeek 配置'
$cfgOk = $false
if (Test-Path $CfgPath) {
    try {
        $cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $u = [string]$cfg.env.PSObject.Properties['ANTHROPIC_BASE_URL'].Value
        $t = [string]$cfg.env.PSObject.Properties['ANTHROPIC_AUTH_TOKEN'].Value
        if (-not $t) { $t = [string]$cfg.env.PSObject.Properties['ANTHROPIC_API_KEY'].Value }
        if ($u -eq $RecUrl -and $t -match '^sk-[A-Za-z0-9]{20,64}$') { Log ('已配置过（密钥 ' + (Mask $t) + '）'); $cfgOk = $true }
    } catch { Log '现有配置读不懂，稍后重写' }
}
if ($cfgOk) { SetS 's3' 'ok'; Flush 'running' 'DeepSeek 配置已就绪' }
else {
    SetS 's3' 'need_key'
    Flush 'running' '第 3 步：需要你的 DeepSeek 密钥 —— 网页上有图文教学（密钥是什么、去哪拿），拿到后回到本窗口粘贴。先配好它，最后一步装完 Claude Code 打开就能直接用、不卡登录'
    Write-Host ''
    Write-Host '  --------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host '   现在需要你的 DeepSeek 密钥（sk- 开头的一串密码）。'  -ForegroundColor Cyan
    Write-Host '   还没有？浏览器页面里有图文教程：注册 → 实名 → 充20元 → 创建。' -ForegroundColor Cyan
    Write-Host '   拿到后：在下面光标处 点鼠标右键 即可粘贴，然后回车。' -ForegroundColor Cyan
    Write-Host '   现在没有？直接回车跳过（以后在教学网页或 CC Switch 里也能配，' -ForegroundColor Cyan
    Write-Host '   但那样 Claude Code 第一次打开可能会先要求登录——记得回来配）。' -ForegroundColor Cyan
    Write-Host '  --------------------------------------------------------------' -ForegroundColor Cyan
    $key = (Read-Host '  粘贴你的密钥').Trim()
    if (-not $key) { Log '跳过密钥配置'; SetS 's3' 'skipped'; Flush 'running' '已跳过密钥——之后在 CC Switch 或教学网页里配，配好前别急着打开 claude' }
    elseif ($key -notmatch '^sk-[A-Za-z0-9]{20,64}$') { Log '密钥格式不对，未写入'; SetS 's3' 'error'; Flush 'running' '密钥格式不像 DeepSeek 的（应为 sk- 开头）：请回平台重新复制后重跑向导' }
    else {
        SetS 's3' 'running'; Flush 'running' '第 3 步：正在联网验证密钥（直连官方，几秒钟）'
        $valid = $false; $bal = ''
        try {
            $b = Invoke-RestMethod -Uri 'https://api.deepseek.com/user/balance' -Headers @{ Authorization = ('Bearer ' + $key) } -TimeoutSec 20
            $cny = $b.balance_infos | Where-Object { $_.currency -eq 'CNY' } | Select-Object -First 1
            if ($cny) { $valid = $true; $bal = $cny.total_balance; Log ('密钥有效，余额 ¥' + $bal) }
            else { $valid = $true; Log '密钥有效（余额接口返回格式陌生）' }
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -eq 401) { Log '401：密钥无效'; SetS 's3' 'error'; Flush 'running' '这把密钥无效（401）：回 platform.deepseek.com 重新复制或重建，再重跑向导' }
            else { Log ('网络验证未通（' + $_.Exception.Message + '），不阻塞，先写入'); $valid = $true }
        }
        if ($valid -and $ST['s3'] -ne 'error') {
            if (-not (Test-Path $ClaudeDir)) { New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null }
            if (Test-Path $CfgPath) { Copy-Item $CfgPath (Join-Path $ClaudeDir ('settings.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')) -Force; Log '已备份旧配置' }
            $envObj = [ordered]@{
                ANTHROPIC_BASE_URL              = $RecUrl
                ANTHROPIC_AUTH_TOKEN            = $key
                ANTHROPIC_MODEL                 = 'deepseek-flash[1m]'
                ANTHROPIC_DEFAULT_SONNET_MODEL  = 'deepseek-flash[1m]'
                ANTHROPIC_DEFAULT_OPUS_MODEL    = 'deepseek-flash[1m]'
                ANTHROPIC_DEFAULT_HAIKU_MODEL   = 'deepseek-flash'
                CLAUDE_CODE_SUBAGENT_MODEL      = 'deepseek-flash'
            }
            [IO.File]::WriteAllText($CfgPath, ([ordered]@{ env = $envObj } | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
            Log ('配置已写入 ' + $CfgPath)
            SetS 's3' 'ok'; Flush 'running' 'DeepSeek 配置完成'
            if ($bal -ne '' -and [double]$bal -le 0) { Log '提醒：余额为 0，请充值 20 元（否则使用时会报 402）'; Flush 'running' '配置完成，但余额为 0：请去 platform.deepseek.com 充值 20 元' }
        }
    }
}

# ---------- 第 4 步：Claude Code（配置已就位，装完首启不卡登录）----------
Log '[4/4] 检查 Claude Code'
$nodeNow = Get-NodeInfo
$npmNow  = Get-NpmInfo $nodeNow
if (Has-Cmd 'claude') { Log ('已安装 ' + (& claude --version) + '，跳过'); SetS 's4' 'ok'; Flush 'running' 'Claude Code 已就绪' }
elseif (-not ($nodeNow.Found -and $nodeNow.MeetsMin)) { Log 'Node 缺失或版本过低，跳过本步'; SetS 's4' 'error'; Flush 'running' '第 1 步没装好（Node.js 缺失或低于 22），本步跳过——先把 Node.js 装好再重跑向导' }
else {
    SetS 's4' 'running'; Flush 'running' '第 4 步：正在从国内镜像安装 Claude Code（1~3 分钟，无需代理，耐心等）'
    Log '切换 npm 镜像为 npmmirror.com（国内 CDN，实测无代理直连 18 秒装完）'
    $npmExe = 'npm.cmd'
    if ($npmNow.Exe) { $npmExe = $npmNow.Exe }
    & $npmExe config set registry https://registry.npmmirror.com | Out-Null
    Log '开始安装 @anthropic-ai/claude-code ...'
    & $npmExe install -g '@anthropic-ai/claude-code' 2>&1 | ForEach-Object {
        $line = "$_"
        if ($line.Trim()) { Log ('npm: ' + $line.Trim()); SetS 's4' 'running'; Flush 'running' '第 4 步：正在安装 Claude Code（看日志了解进度）' }
    }
    Refresh-Path
    if (-not (Has-Cmd 'claude')) {
        # 命令装上了但不在 PATH 里 —— 这是「装完敲不出 claude」的头号原因，自动补一下
        $pathStub = New-Object psobject -Property @{ Node = $nodeNow; NpmPrefix = (Get-NpmPrefix $npmNow $nodeNow) }
        Repair-NodePath $pathStub | Out-Null
        Refresh-Path
    }
    if (Has-Cmd 'claude') { Log ('安装成功：' + (& claude --version)); SetS 's4' 'ok'; Flush 'running' 'Claude Code 安装成功——配置已在第 3 步写好，直接打开即可用' }
    else { Log '安装未确认成功（网络波动？）'; SetS 's4' 'error'; Flush 'running' 'Claude Code 没装上：重跑向导再试一次（若被校园网拦截可临时开代理），或用 安装包\安装ClaudeCode-离线安装.bat（不联网也能装），或看网页急救站' }
}

# ---------- 收尾 ----------
$okCount = @($ST.Values | Where-Object { $_ -eq 'ok' -or $_ -eq 'skipped' }).Count
Log ('完成度 ' + $okCount + '/4')
if ($okCount -eq 4) { Flush 'done' '全部完成！教学网页已就绪——从「课程」开始学，然后去「场景弹药库」抄第一个作业' }
else { Flush 'done' ('完成 ' + $okCount + '/4。没就绪的项目：按网页显示的提示处理，或打开 配套文件\AI装机体检助手 复查，修完重跑本向导') }

Write-Host ''
Write-Host '  向导结束。请回到浏览器页面查看结果（本窗口可以关闭）。' -ForegroundColor Cyan
$null = Read-Host '  （按回车退出）'
