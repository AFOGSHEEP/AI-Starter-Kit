# ============================================================
#  AI 装机体检助手 v1.0  (AI Setup Doctor)
#  用途：真实检查本机的 AI 装机状态（Claude Code / CC Switch / DSH / 配置文件 / 密钥），
#        并提供：一键写入推荐配置（自动备份）、打开官方下载页、联网密钥体检。
#  说明：脚本只在你的电脑本地运行；密钥仅用于直连 DeepSeek 官方接口验证，不发送给任何第三方。
# ============================================================

$ErrorActionPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$CfgPath   = Join-Path $env:USERPROFILE '.claude\settings.json'
$ClaudeDir = Join-Path $env:USERPROFILE '.claude'
$DshHome   = Join-Path $env:USERPROFILE '.dsh'
$RecommendedUrl = 'https://api.deepseek.com/anthropic'

function W($c,$t){ Write-Host $t -ForegroundColor $c }
function OK($t){ W 'Green'  ("  [OK] " + $t) }
function BAD($t){ W 'Red'    ("  [X ] " + $t) }
function WARN($t){ W 'Yellow' ("  [!!] " + $t) }
function INFO($t){ W 'Gray'  ("       " + $t) }
function Section($t){ Write-Host ""; W 'Cyan' ('==== ' + $t + ' ====') }
function Pause-Here { INFO '（按回车键继续...）'; $null = Read-Host }

function Mask($k){ if(-not $k){return '(空)'}; $t=$k.Trim(); if($t.Length -le 8){ return ('*' * $t.Length) }; return ($t.Substring(0,5) + '****' + $t.Substring($t.Length-4)) }

function Get-InstalledViaRegistry($namePart){
    $paths = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $hits = Get-ItemProperty $paths | Where-Object { $_.DisplayName -and ($_.DisplayName -like $namePart) }
    return $hits
}

function Read-ClaudeConfig {
    if (-not (Test-Path $CfgPath)) { return $null }
    try { return (Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return 'PARSE_ERROR' }
}

function Get-EnvValue($cfg,$name){
    if (-not $cfg -or $cfg -is [string]) { return $null }
    $p = $cfg.env.PSObject.Properties[$name]
    if ($p) { return [string]$p.Value }
    return $null
}

function Full-Check {
    Clear-Host
    W 'Cyan' '=================================================='
    W 'Cyan' '        AI 装机体检助手  v1.0   (本地运行)'
    W 'Cyan' '=================================================='
    $issues = 0

    Section '第 1 部分 · 软件装了没有'

    # 1 Node.js（命令行版 Claude Code 的地基：官方要求 node >= 22）
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $nv = ([string](& node -v 2>$null)).Trim()
        $nodeOkVer = $false
        if ($nv -match '^v?(\d+)\.(\d+)') { if ([int]$Matches[1] -ge 22) { $nodeOkVer = $true } }
        if ($nodeOkVer) { OK ("Node.js 已安装 " + $nv + "（满足 Claude Code 要求的 22 以上）") }
        else { BAD ("Node.js 版本过低：" + $nv + " —— Claude Code 要求 22 以上，npm 会拒绝安装或装完起不来。修法：双击 安装包\安装ClaudeCode-一键联网安装.bat（会自动升级 Node）"); $issues++ }
    }
    else { WARN 'Node.js 未安装（只用桌面版 + CC Switch 可以不管它；要命令行版就双击 安装包\安装ClaudeCode-一键联网安装.bat，它会自动装好 Node 再装 Claude Code）' }

    # 1b npm（Node 自带；单独缺了通常是 PATH 或安装不完整）
    $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($node -and -not $npmCmd) { WARN 'npm 命令不在 PATH 里 —— 重跑 安装包\安装ClaudeCode-一键联网安装.bat 可以自动修复（它会把 npm 全局目录补进 PATH）' }

    # 2 Claude Code CLI
    $cc = Get-Command claude -ErrorAction SilentlyContinue
    if ($cc) { $cv = (& claude --version 2>$null); OK ("Claude Code 命令行已安装：" + $cv) }
    else { INFO 'Claude Code 命令行未检出（如果你装的是桌面版，这是正常的，看下一项）' }

    # 3 Claude 桌面版（best effort）
    $deskHit = $false
    $deskDirs = @("$env:LOCALAPPDATA\AnthropicClaude", "$env:LOCALAPPDATA\Programs\Claude", "$env:LOCALAPPDATA\Programs\claude-code", "$env:ProgramFiles\Claude")
    foreach($d in $deskDirs){ if (Test-Path $d) { $deskHit = $true; OK ("检测到 Claude 桌面版目录：" + $d); break } }
    if (-not $deskHit) {
        $reg = Get-InstalledViaRegistry '*Claude*'
        if ($reg) { $deskHit = $true; OK ('检测到 Claude 相关程序：' + (($reg | Select-Object -First 1).DisplayName)) }
    }
    if (-not $deskHit) { BAD '未检出 Claude 桌面版 —— 去 claude.ai/download 下载 Windows x64 安装包（菜单 2 可直接打开）'; $issues++ }

    # 4 CC Switch
    $ccsHit = $false
    $ccsDirs = @("$env:USERPROFILE\.cc-switch", "$env:LOCALAPPDATA\cc-switch", "$env:LOCALAPPDATA\Programs\cc-switch", "$env:LOCALAPPDATA\Programs\CC Switch")
    foreach($d in $ccsDirs){ if (Test-Path $d) { $ccsHit = $true; OK ("检测到 CC Switch：" + $d); break } }
    if (-not $ccsHit) {
        $reg2 = Get-InstalledViaRegistry '*cc-switch*'
        $reg3 = Get-InstalledViaRegistry '*CC Switch*'
        if ($reg2 -or $reg3) { $ccsHit = $true; OK '检测到 CC Switch（注册表）' }
    }
    if (-not $ccsHit) { BAD '未检出 CC Switch —— 这是给 Claude Code 换发动机的图形化配置器（必装）。GitHub: farion1231/cc-switch（菜单 2 可打开下载页）'; $issues++ }

    # 5 DSH
    if (Test-Path $DshHome) { OK ('检测到 DSH 主目录：' + $DshHome) }
    elseif (Get-Command dsh -ErrorAction SilentlyContinue) { OK '检测到 dsh 命令' }
    else { WARN '未检出 DSH —— 它是选装的体验项目（教学程序第 3 步），不影响 Claude Code 使用' }

    Section '第 2 部分 · 配置写对没有（这才是关键）'

    if (-not (Test-Path $ClaudeDir)) { BAD ('连 .claude 文件夹都不存在（' + $ClaudeDir + '）—— 先装 Claude Code，再用 CC Switch 写入配置，或用本助手菜单 1 一键写入'); $issues++ }
    else {
        $cfg = Read-ClaudeConfig
        if ($null -eq $cfg) { BAD ('没有找到配置文件 settings.json —— 用 CC Switch 写入，或用本助手菜单 1 一键写入'); $issues++ }
        elseif ($cfg -is [string]) { BAD 'settings.json 存在但内容不是合法 JSON（多半是手动改坏了）。建议：用 CC Switch 重写，或菜单 1 覆盖（会自动备份旧的）'; $issues++ }
        else {
            $url = Get-EnvValue $cfg 'ANTHROPIC_BASE_URL'
            $tok = Get-EnvValue $cfg 'ANTHROPIC_AUTH_TOKEN'
            if (-not $tok) { $tok = Get-EnvValue $cfg 'ANTHROPIC_API_KEY' }
            $model = Get-EnvValue $cfg 'ANTHROPIC_MODEL'

            if ($url -eq $RecommendedUrl) { OK ('服务器地址正确：' + $url) }
            elseif ($url -and $url -like '*api.anthropic.com*') { BAD ('服务器还指向 Anthropic 官方（' + $url + '）—— 这就是「要求登录/付款」的根本原因。用 CC Switch 切到 DeepSeek，或菜单 1 一键修复'); $issues++ }
            elseif ($url) { WARN ('服务器指向了别家服务：' + $url + ' —— 如果你确实在用别家就算了，否则建议切回 DeepSeek') }
            else { BAD '配置文件里没有服务器地址（ANTHROPIC_BASE_URL）—— 用 CC Switch 写入，或菜单 1 一键写入'; $issues++ }

            if ($tok) {
                $tok = $tok.Trim()
                if ($tok -match '^sk-[A-Za-z0-9]{20,64}$') { OK ('密钥已配置：' + (Mask $tok)) }
                else { BAD ('密钥格式可疑：' + (Mask $tok) + ' —— 正常应是 sk- 开头的一长串。可能复制不全或混入空格'); $issues++ }
            } else { BAD '没有配置密钥（ANTTHROPIC_AUTH_TOKEN / API_KEY）—— 用 CC Switch 填入，或菜单 1 一键写入'; $issues++ }

            if ($model) { INFO ('当前模型设置：' + $model + '（提示：deepseek-flash 系是日常推荐；CC Switch 本地路由模式下不要手动加 [1m] 后缀）') }
        }
    }

    Section '体检结论'
    if ($issues -eq 0) { W 'Green' '  全绿！你的 Claude Code + DeepSeek 链路配置正确，可以开工了。' }
    else { W 'Yellow' ('  发现 ' + $issues + ' 个需要处理的问题。按上面的提示逐条解决，或用下面的菜单。') }
    W 'Gray' '  提示：本检测为尽力而为（自定义安装路径可能漏检）。最终标准：Claude Code 里发一句「你好」能收到回复。'
}

function Write-Recommended {
    W 'Cyan' ''
    W 'Cyan' '-- 一键写入推荐配置（Claude Code × DeepSeek）--'
    $key = Read-Host '请粘贴你的 DeepSeek API Key（sk- 开头；直接回车取消）'
    $key = $key.Trim()
    if (-not $key) { WARN '已取消（没有输入密钥）'; return }
    if ($key -notmatch '^sk-[A-Za-z0-9]{20,64}$') { BAD '密钥格式不像 DeepSeek 的（应以 sk- 开头）——为安全起见不写入。请回平台重新复制。'; return }

    if (-not (Test-Path $ClaudeDir)) { New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null }
    if (Test-Path $CfgPath) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $bak = Join-Path $ClaudeDir ('settings.backup-' + $stamp + '.json')
        Copy-Item $CfgPath $bak -Force
        OK ('已备份原配置到：' + $bak)
    }
    $envObj = [ordered]@{
        ANTHROPIC_BASE_URL              = $RecommendedUrl
        ANTHROPIC_AUTH_TOKEN            = $key
        ANTHROPIC_MODEL                 = 'deepseek-flash[1m]'
        ANTHROPIC_DEFAULT_SONNET_MODEL  = 'deepseek-flash[1m]'
        ANTHROPIC_DEFAULT_OPUS_MODEL    = 'deepseek-flash[1m]'
        ANTHROPIC_DEFAULT_HAIKU_MODEL   = 'deepseek-flash'
        CLAUDE_CODE_SUBAGENT_MODEL      = 'deepseek-flash'
    }
    $cfgObj = [ordered]@{ env = $envObj }
    $json = $cfgObj | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($CfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    OK ('已写入推荐配置：' + $CfgPath)
    INFO '来源：DeepSeek 官方 Claude Code 接入文档推荐的环境变量组合。'
    WARN '注意：如果你同时在用 CC Switch，切换供应商时它会把这份文件整体重写（本助手写入前都会备份）。'
    INFO '现在去打开/重启 Claude Code，发送「你好」验收。'
}

function Online-Check {
    W 'Cyan' ''
    W 'Cyan' '-- 联网体检：密钥有效性 + 余额 + 点火测试 --'
    $key = Read-Host '请粘贴你的 DeepSeek API Key（直接回车取消）'
    $key = $key.Trim()
    if (-not $key) { return }
    if ($key -notmatch '^sk-[A-Za-z0-9]{20,64}$') { BAD '格式不像 DeepSeek 密钥（应以 sk- 开头）'; return }
    $H1 = @{ Authorization = ('Bearer ' + $key) }

    INFO '正在直连 api.deepseek.com 查询余额...'
    try {
        $bal = Invoke-RestMethod -Uri 'https://api.deepseek.com/user/balance' -Headers $H1 -TimeoutSec 20
        $b = $bal.balance_infos | Where-Object { $_.currency -eq 'CNY' } | Select-Object -First 1
        if ($b) { OK ('密钥有效，余额：' + $b.total_balance + ' ' + $b.currency) ; if ([double]$b.total_balance -le 0) { WARN '余额为 0：先充值（否则 Claude Code 里会报 402）' } }
        else { WARN ('余额接口返回异常：' + ($bal | ConvertTo-Json -Compress)) }
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 401) { BAD '401：密钥无效——重新完整复制，或重建一把 Key' ; return }
        WARN ('查询失败：' + $_.Exception.Message + '（网络问题不等于配置问题）')
    }

    INFO '正在发送一条真实测试消息（点火测试）...'
    try {
        $body = @{ model = 'deepseek-flash'; max_tokens = 20; stream = $false; messages = @(@{ role='user'; content='这是一次连接测试，请只回复四个字：连接成功' }) } | ConvertTo-Json -Depth 5
        $r = Invoke-RestMethod -Uri 'https://api.deepseek.com/chat/completions' -Method Post -ContentType 'application/json; charset=utf-8' -Headers $H1 -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30
        $rep = $r.choices[0].message.content
        $pt = [int]$r.usage.prompt_tokens; $ct = [int]$r.usage.completion_tokens
        $cost = [math]::Round($pt/1000000*1 + $ct/1000000*4, 6)
        OK ('模型回复：' + $rep)
        INFO ('本次消耗：输入 ' + $pt + ' + 输出 ' + $ct + ' tokens，约 ¥' + $cost + '（flash 空闲档价）——这就是按 token 计费')
        W 'Green' '  点火成功：密钥、余额、接口全部正常。剩下的就是让 Claude Code 用上这把钥匙（看体检第 2 部分）。'
    } catch {
        $code2 = $_.Exception.Response.StatusCode.value__
        if ($code2 -eq 402) { WARN '402：余额不足——充值后重试' }
        elseif ($code2 -eq 429) { WARN '429：限速，一分钟后再试' }
        else { BAD ('点火失败：' + $_.Exception.Message) }
    }
}

function Open-Downloads {
    W 'Cyan' ''
    W 'Cyan' '-- 打开官方下载页 --'
    W 'Gray'  '  [1] Claude Code 桌面版（claude.ai/download，选 Windows x64）'
    W 'Gray'  '  [2] CC Switch（github.com/farion1231/cc-switch 的 Releases，下载 .exe 安装）'
    W 'Gray'  '  [3] DSH 桌面版（github.com/rye567/dsh-desktop 的 Releases）'
    W 'Gray'  '  [4] DeepSeek 开放平台（充值/密钥/用量）'
    W 'Gray'  '  [0] 返回'
    $c = Read-Host '打开哪个？'
    switch ($c) {
        '1' { Start-Process 'https://claude.ai/download' }
        '2' { Start-Process 'https://github.com/farion1231/cc-switch/releases' }
        '3' { Start-Process 'https://www.deepseek.com' }
        '4' { Start-Process 'https://platform.deepseek.com' }
    }
    INFO '浏览器已打开；下载安装完成后，回本助手重新体检（菜单 4）。'
}

# ---------------- 主循环 ----------------
Full-Check
while ($true) {
    W 'Cyan' ''
    W 'Cyan' '======== 主菜单 ========'
    W 'Gray'  '  [1] 一键写入推荐配置（自动备份旧的）'
    W 'Gray'  '  [2] 打开官方下载页'
    W 'Gray'  '  [3] 联网体检（密钥 + 余额 + 点火测试）'
    W 'Gray'  '  [4] 重新全面体检'
    W 'Gray'  '  [0] 退出'
    $c = Read-Host '请选择'
    switch ($c) {
        '1' { Write-Recommended }
        '2' { Open-Downloads }
        '3' { Online-Check }
        '4' { Full-Check }
        '0' { break }
    }
}
W 'Cyan' '再见！记住：最终验收 = Claude Code 里发「你好」能收到回复。'

