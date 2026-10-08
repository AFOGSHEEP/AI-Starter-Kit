# ============================================================
#  Claude Code 安装助手 v2.0   install-cc.ps1
#  被 安装包 下的三个 .bat 调用（双击 .bat 即可，不要直接双击本文件）：
#    安装ClaudeCode-一键联网安装.bat   ->  -Mode Online
#    安装ClaudeCode-离线安装.bat       ->  -Mode Offline
#    安装ClaudeCode-只检测环境.bat     ->  -Mode Check
#  相比 v1.0 的变化：先做完整前置体检（Node 版本 / npm / PATH / 磁盘 / 网络 / 离线包），
#  缺什么就先提醒、再自动补齐，然后再安装；全程写日志，失败会告诉你具体卡在哪一步。
# ============================================================
param(
    [ValidateSet('Online', 'Offline', 'Check')][string]$Mode = 'Online',
    [switch]$AutoYes,
    [switch]$DryRun,
    [switch]$Elevated,
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$script:ExitCode = 0
$script:InstallDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'Prereq.ps1')

# ============================================================
#  小工具
# ============================================================

function Write-Child($line) {
    $s = [string]$line
    if (-not $s.Trim()) { return }
    Write-Host ('       ' + $s) -ForegroundColor DarkGray
    Write-Log ('  | ' + $s)
}

function Confirm-WithCountdown($question, $seconds) {
    if ($AutoYes) {
        INFO ($question + ' → 已自动确认（-AutoYes）')
        return $true
    }
    if (-not (Test-InteractiveConsole)) {
        INFO ($question + ' → 非交互环境，按默认继续')
        return $true
    }
    Write-Host ('   ' + $question + '  [Y/n]   ' + $seconds + ' 秒后自动继续') -ForegroundColor Yellow
    $end = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $end) {
        try {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq [ConsoleKey]::N) { Write-Host '   （你选择了取消）' -ForegroundColor Yellow; return $false }
                if ($k.Key -eq [ConsoleKey]::Y -or $k.Key -eq [ConsoleKey]::Enter) { Write-Host '   （已确认）' -ForegroundColor Green; return $true }
            }
        } catch {}
        Start-Sleep -Milliseconds 120
    }
    Write-Host '   （超时，按默认继续）' -ForegroundColor Gray
    return $true
}

function Show-Banner($text) {
    $line = '=' * 60
    Write-Host ''
    Write-Line 'Cyan' $line
    Write-Line 'Cyan' ('  ' + $text)
    Write-Line 'Cyan' $line
}

# ============================================================
#  安装动作
# ============================================================

function Invoke-OnlineInstall($rep) {
    $npmExe = $rep.Npm.Exe
    if (-not $npmExe) { BAD 'npm 不可用，无法联网安装'; return $false }

    $primary = 'https://registry.npmmirror.com'
    $backup  = 'https://registry.npmjs.org'
    if (-not $rep.Mirror.Ok) {
        $tmp = $primary; $primary = $backup; $backup = $tmp
    }

    foreach ($registry in @($primary, $backup)) {
        INFO ('使用 npm 源：' + $registry)
        $setOut = & $npmExe config set registry $registry 2>&1
        foreach ($l in @($setOut)) { Write-Child $l }

        INFO '正在安装 @anthropic-ai/claude-code（1~3 分钟，请勿关闭本窗口）...'
        & $npmExe install -g '@anthropic-ai/claude-code' --no-fund --no-audit 2>&1 | ForEach-Object { Write-Child $_ }
        $code = $LASTEXITCODE
        Write-Log ('npm install 退出码=' + $code + ' registry=' + $registry)

        if ($code -eq 0) {
            Update-SessionPath | Out-Null
            $c = Get-ClaudeInfo
            if ($c.Found) { return $true }
            WARN 'npm 报告成功，但本窗口还认不到 claude 命令，继续尝试修复 PATH。'
            return $true
        }
        WARN ('这次没成功（退出码 ' + $code + '），换一个源再试一次...')
    }
    return $false
}

function Invoke-OfflineInstall($rep) {
    $src = Join-Path $script:InstallDir 'claude-code-offline'
    if (-not (Test-Path $src)) { BAD ('找不到离线包目录：' + $src); return $false }

    $prefix = $rep.NpmPrefix
    if (-not $prefix) { $prefix = Join-Path $env:APPDATA 'npm' }
    if (-not (Test-Path $prefix)) { New-Item -ItemType Directory -Path $prefix -Force | Out-Null }
    $destMod = Join-Path $prefix 'node_modules'

    INFO ('正在复制文件到：' + $prefix + '（约 245MB，1 分钟左右）...')
    & robocopy (Join-Path $src 'node_modules') $destMod /E /NFL /NDL /NJH /NJS /R:2 /W:1 | Out-Null
    $rc = $LASTEXITCODE
    Write-Log ('robocopy 退出码=' + $rc)
    if ($rc -ge 8) {
        BAD ('复制失败（robocopy 退出码 ' + $rc + '）：可能是文件被占用或磁盘空间不足。')
        if ($rep.Claude.Running) { INFO '正在运行的 claude 会占用文件：关掉它再重跑本脚本。' }
        return $false
    }

    foreach ($f in @('claude.cmd', 'claude.ps1', 'claude')) {
        $s = Join-Path $src $f
        if (Test-Path $s) {
            try { Copy-Item $s (Join-Path $prefix $f) -Force } catch { Write-Log ('复制 ' + $f + ' 失败：' + $_.Exception.Message) }
        }
    }
    Update-SessionPath | Out-Null
    return $true
}

function Test-ClaudeReady($rep) {
    Update-SessionPath | Out-Null
    $c = Get-ClaudeInfo
    if ($c.Found -and $c.Version) { return $c }

    $prefix = $rep.NpmPrefix
    if ($prefix) {
        $abs = Join-Path $prefix 'claude.cmd'
        if (Test-Path $abs) {
            $v = $null
            try { $v = ([string](& $abs --version 2>$null | Select-Object -First 1)).Trim() } catch {}
            if ($v) {
                $c.Found = $true; $c.Exe = $abs; $c.Version = $v; $c.InPath = (Test-InPath $prefix)
            }
        }
    }
    return $c
}

# ============================================================
#  主流程
# ============================================================

$modeName = '联网安装（国内镜像）'
if ($Mode -eq 'Offline') { $modeName = '离线安装（完全不用网络）' }
if ($Mode -eq 'Check')   { $modeName = '只体检，不安装任何东西' }

$logFile = Start-PrereqLog $script:InstallDir
Show-Banner ('Claude Code 安装助手 v2.0   ·   ' + $modeName)
INFO ('礼包位置：' + $script:InstallDir)
if ($logFile) { INFO ('本次日志：' + $logFile) }
if ($DryRun) { WARN '演练模式（-DryRun）：只打印计划，不做任何改动。' }

# ---------- 第一步：体检 ----------
$rep = Get-EnvReport $Mode $script:InstallDir
$blocks = @(Show-EnvReport $rep)

# ---------- 只体检模式 ----------
if ($Mode -eq 'Check') {
    Section '体检结束（没有安装任何东西）'
    if ($blocks.Count -eq 0) {
        OK '前置环境没问题，可以放心安装 Claude Code 了。'
    } else {
        BAD ('有 ' + $blocks.Count + ' 项必须先解决（上面已列出）。')
        INFO '不用你手动装：直接双击同目录的 安装ClaudeCode-一键联网安装.bat，'
        INFO '它会把这些前置一项一项自动补齐，然后再装 Claude Code。'
    }
    $script:ExitCode = 0
    if ($blocks.Count -gt 0) { $script:ExitCode = 1 }
    Write-Host ''
    if (-not $NoPause -and (Test-InteractiveConsole)) { INFO '（按回车键关闭本窗口...）'; $null = Read-Host }
    exit $script:ExitCode
}

# ---------- 无法自动解决的前置问题 ----------
$unfixable = @($blocks | Where-Object { -not $_.Fixable })
if ($unfixable.Count -gt 0) {
    Section '先手动处理这几件事（脚本没法替你做）'
    foreach ($i in $unfixable) {
        BAD $i.Title
        TIP $i.Hint
    }
    if ($Mode -eq 'Offline') {
        INFO '建议：改用 安装ClaudeCode-一键联网安装.bat（不需要离线包）。'
    } else {
        INFO '建议：改用 安装ClaudeCode-离线安装.bat（不需要网络）。'
    }
    $script:ExitCode = 1
    Write-Host ''
    if (-not $NoPause -and (Test-InteractiveConsole)) { INFO '（按回车键关闭本窗口...）'; $null = Read-Host }
    exit $script:ExitCode
}

# ---------- 第二步：把缺口列出来，问一句，然后自动补 ----------
$todo = New-Object System.Collections.ArrayList
foreach ($i in $blocks) {
    if ($i.Id -eq 'node-missing')      { [void]$todo.Add('安装 Node.js（自动：优先本地安装包，其次国内镜像下载）') }
    if ($i.Id -eq 'node-too-old')      { [void]$todo.Add('升级 Node.js 到 ' + $script:PrereqMinNode + ' 以上（自动）') }
    if ($i.Id -eq 'node-not-in-path')  { [void]$todo.Add('把 Node.js 目录写进用户 PATH（自动）') }
    if ($i.Id -eq 'npm-missing')       { [void]$todo.Add('修复 npm（用 Node 安装包做一次修复安装）') }
    if ($i.Id -eq 'npm-not-in-path')   { [void]$todo.Add('把 Node.js 目录写进用户 PATH（自动）') }
    if ($i.Id -eq 'prefix-not-in-path'){ [void]$todo.Add('把 npm 全局目录写进用户 PATH（自动）') }
    if ($i.Id -eq 'claude-running')    { [void]$todo.Add('关闭正在运行的 Claude Code（离线覆盖前必须）') }
}
$todo = @($todo | Select-Object -Unique)

$needAdmin = @($blocks | Where-Object { $_.Id -eq 'node-missing' -or $_.Id -eq 'node-too-old' -or $_.Id -eq 'npm-missing' }).Count -gt 0

if ($todo.Count -eq 0) {
    Section '第二步 · 前置条件已满足，不需要补装'
} else {
    Section '第二步 · 修复计划（脚本要替你做的事）'
    $n = 0
    foreach ($t in $todo) { $n++; INFO ('' + $n + '. ' + $t) }

    if (-not (Confirm-WithCountdown '现在开始自动补齐这些前置，可以吗？' 15)) {
        WARN '已取消。你可以双击 安装ClaudeCode-只检测环境.bat 查看体检结果，或按「安装说明.txt」手动安装。'
        exit 1
    }

    # 需要管理员权限时自提权重启
    if ($needAdmin -and -not (Test-Admin) -and -not $Elevated) {
        WARN '装 Node.js 需要管理员权限：马上会弹一次 UAC，请点「是」。'
        $argStr = '-Mode ' + $Mode + ' -AutoYes -Elevated'
        $elevated = $false
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" ' + $argStr) | Out-Null
            $elevated = $true
        } catch {
            Write-Log ('提权失败：' + $_.Exception.Message)
        }
        if ($elevated) {
            INFO '已经在新的管理员窗口里继续（本窗口可以关掉）。'
            INFO '那个窗口会自己跑完：补前置 → 装 Claude Code → 告诉你结果。'
            exit 0
        }
        WARN '提权被拒绝，继续用普通权限尝试（Node 安装可能失败）。'
    }

    Section '第三步 · 自动补齐前置（缺什么装什么）'

    # 1) Node：没装 / 版本过低
    if (@($blocks | Where-Object { $_.Id -eq 'node-missing' -or $_.Id -eq 'node-too-old' }).Count -gt 0) {
        if ($rep.Node.TooOld) {
            WARN ('检测到旧版 Node.js ' + $rep.Node.Version + '，将安装新版覆盖它。')
        }
        $ok = Repair-NodePrereq $rep $script:InstallDir
        Update-SessionPath | Out-Null
        $rep.Node = Get-NodeInfo
        $rep.Npm  = Get-NpmInfo $rep.Node
        $rep.NpmPrefix = Get-NpmPrefix $rep.Npm $rep.Node
        if ($ok -and $rep.Node.Found -and $rep.Node.MeetsMin) {
            OK ('Node.js 已就绪：' + $rep.Node.Version + '（' + $rep.Node.Exe + '）')
        } else {
            BAD 'Node.js 还是不可用，先停在这里，别继续往下装（装了也用不了）。'
            INFO '手动兜底（一定能成）：'
            TIP '1. 到 nodejs.org/zh-cn/download 下载 LTS 版（.msi），双击一路「下一步」装完'
            TIP '   （礼包里若带 node-v22.23.3-x64.msi，直接双击它也一样）'
            TIP '2. 如果提示已有旧版本：控制面板 →「卸载程序」先卸掉旧 Node.js，再装'
            TIP '3. 装完关掉本窗口，重新双击本脚本'
            INFO '还不行就去下载页手动拿最新的 LTS：'
            Open-NodeDownloadPage
            $script:ExitCode = 1
            Write-Host ''
            if (-not $NoPause -and (Test-InteractiveConsole)) { INFO '（按回车键关闭本窗口...）'; $null = Read-Host }
            exit $script:ExitCode
        }
    }

    # 2) npm 不可用
    if (-not $rep.Npm.Found) {
        Repair-NpmPrereq $rep $script:InstallDir | Out-Null
        $rep.Npm = Get-NpmInfo $rep.Node
        $rep.NpmPrefix = Get-NpmPrefix $rep.Npm $rep.Node
        if ($rep.Npm.Found) { OK ('npm 已恢复：' + $rep.Npm.Version) }
        else { WARN 'npm 仍未恢复，联网安装会失败；离线安装不受影响。' }
    }

    # 3) PATH 缺项
    Repair-NodePath $rep | Out-Null
    Update-SessionPath | Out-Null

    # 4) claude 正在运行（离线覆盖前要关）
    if (@($blocks | Where-Object { $_.Id -eq 'claude-running' }).Count -gt 0) {
        WARN '检测到 Claude Code 正在运行，离线覆盖前需要先关掉它。'
        if (Confirm-WithCountdown '现在自动关掉正在运行的 Claude Code，可以吗？' 15) {
            if (Stop-ClaudeProcess) { OK '已关闭。' } else { WARN '没能关闭，请手动关掉 Claude Code 窗口后重跑本脚本。' }
        } else {
            BAD '没有关闭：文件被占用时离线覆盖会失败。'
            exit 1
        }
    }
}

# ---------- 演练模式（-DryRun）在这里就停住，绝不真的装 ----------
if ($DryRun) {
    Section '演练结束（-DryRun：本次没有做任何改动）'
    if ($todo.Count -gt 0) { INFO '真实运行时：上面的缺口会先自动补齐，然后' } else { INFO '真实运行时：' }
    INFO ('执行 → ' + $modeName + ' → 再用 claude --version 验证一遍是否真的装上了。')
    Write-Host ''
    if (-not $NoPause -and (Test-InteractiveConsole)) { INFO '（按回车键关闭本窗口...）'; $null = Read-Host }
    exit 0
}

# ---------- 第四步：安装 Claude Code ----------
Section ('第四步 · 安装 Claude Code（' + $modeName + '）')

if ($rep.Mode -eq 'Offline') {
    $installed = Invoke-OfflineInstall $rep
} else {
    $installed = Invoke-OnlineInstall $rep
}

if (-not $installed) { WARN '安装过程没有成功完成，继续做一次结果验证...' }

# ---------- 第五步：验证 ----------
Section '第五步 · 验证安装结果'
$claude = Test-ClaudeReady $rep

if (-not $claude.Found) {
    WARN '本窗口还认不到 claude 命令，尝试补 PATH 再验一次...'
    if ($rep.NpmPrefix) { Add-UserPathEntry $rep.NpmPrefix | Out-Null }
    if ($rep.Node.Dir) { Add-UserPathEntry $rep.Node.Dir | Out-Null }
    Update-SessionPath | Out-Null
    $claude = Test-ClaudeReady $rep
}

if ($claude.Found -and $claude.Version) {
    OK ('Claude Code 已安装：' + $claude.Version)
    INFO ('程序位置：' + $claude.Exe)
    Write-Line 'Green' '  安装完成！Claude Code 已经在你电脑上了。'
    Write-Host ''
    Write-Line 'Cyan' '  接下来（顺序别乱）：'
    Write-Line 'Gray' '  1. 双击同目录的 CC-Switch-v4.0.4-Windows.msi 装好'
    Write-Line 'Gray' '  2. 打开 CC Switch → 右上角「+」→ 预设选 DeepSeek → 粘贴 sk- 密钥 → 保存并切换'
    Write-Line 'Gray' '  3. 新开一个终端窗口（重要：老窗口认不到新命令），输入 claude 回车验收'
    Write-Line 'Gray' '  4. 最后跑 配套文件\AI装机体检助手-双击我.bat，全绿就毕业'
    Write-Host ''
    Write-Line 'Gray' '  提示：Claude Code 是黑色终端界面，这是正常的，不用害怕。'
    $script:ExitCode = 0
} else {
    BAD 'Claude Code 没有被确认装上。'
    INFO '按下面顺序排查（日志里能看到每一步）：'
    TIP '1. 关掉本窗口重新双击本脚本（PATH 改动要新窗口才生效）'
    TIP '2. 联网安装失败：临时开一下代理重跑，或改用 安装ClaudeCode-离线安装.bat'
    TIP '3. 离线安装失败：确认礼包解压完整（安装包\claude-code-offline 文件夹要在）'
    TIP '4. 还不行就跑 配套文件\AI装机体检助手-双击我.bat，把结果发给帮你的人'
    if ($logFile) { INFO ('把日志一起发过去会有用：' + $logFile) }
    $script:ExitCode = 1
}

if ($logFile) { INFO ('日志文件：' + $logFile) }
Write-Host ''
if (-not $NoPause -and (Test-InteractiveConsole)) { INFO '（按回车键关闭本窗口...）'; $null = Read-Host }
exit $script:ExitCode
