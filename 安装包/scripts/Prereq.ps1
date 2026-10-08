# ============================================================
#  Claude Code 前置环境 检测 / 自动修复 公共库   Prereq.ps1
#  用法：由其它脚本点源加载（. "$PSScriptRoot\Prereq.ps1"），不要单独双击。
#  职责：只做「检测」与「修复动作的封装」；是否动手修，由调用方决定。
#  兼容：Windows PowerShell 5.1（不依赖 PowerShell 7 语法）。
# ============================================================

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------- 硬性要求 ----------
# 来自 Claude Code 官方包 @anthropic-ai/claude-code 的 package.json：engines.node = ">=22.0.0"
$script:PrereqMinNode    = '22.0.0'
$script:PrereqMinNpm     = '10.0.0'
$script:PrereqMinDiskGB  = 2.0        # 全局安装 + 解包大约 1GB，留 2GB 余量
$script:PrereqPinnedNode = '22.23.3'  # 与本礼包自带的 node-v22.23.3-x64.msi 保持一致
$script:PrereqLogPath    = $null
$script:PrereqOfflineDir = 'claude-code-offline'

# ============================================================
#  一、输出与日志
# ============================================================

function Start-PrereqLog($dir) {
    $target = $dir
    if (-not $target -or -not (Test-Path $target)) { $target = $env:TEMP }
    $file = Join-Path $target ('安装日志-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    try {
        [IO.File]::WriteAllText($file, ('Claude Code 安装日志  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
        $script:PrereqLogPath = $file
        return $file
    } catch {
        $script:PrereqLogPath = $null
        return $null
    }
}

function Write-Log($msg) {
    if (-not $script:PrereqLogPath) { return }
    try {
        $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + [string]$msg
        [IO.File]::AppendAllText($script:PrereqLogPath, ($line + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    } catch {}
}

function Write-Line($color, $text) {
    Write-Host $text -ForegroundColor $color
    Write-Log $text
}
function Section($t)    { Write-Host ''; Write-Line 'Cyan' ('==== ' + $t + ' ====') }
function OK($t)   { Write-Line 'Green'  ('  [OK] ' + $t) }
function BAD($t)  { Write-Line 'Red'    ('  [X ] ' + $t) }
function WARN($t) { Write-Line 'Yellow' ('  [!!] ' + $t) }
function INFO($t) { Write-Line 'Gray'   ('       ' + $t) }
function TIP($t)  { Write-Line 'DarkGray' ('       → ' + $t) }

# ============================================================
#  二、基础工具函数
# ============================================================

function ConvertTo-NumVersion($text) {
    if (-not $text) { return $null }
    $m = [regex]::Match([string]$text, '(\d+)\.(\d+)(\.(\d+))?')
    if (-not $m.Success) { return $null }
    $maj = [int]$m.Groups[1].Value
    $min = [int]$m.Groups[2].Value
    $pat = 0
    if ($m.Groups[4].Success) { $pat = [int]$m.Groups[4].Value }
    return (New-Object System.Version($maj, $min, $pat))
}

function Test-VerAtLeast($text, $min) {
    $v = ConvertTo-NumVersion $text
    $m = ConvertTo-NumVersion $min
    if (-not $v -or -not $m) { return $false }
    return ($v -ge $m)
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-InteractiveConsole {
    try { $null = [Console]::KeyAvailable; return $true } catch { return $false }
}

# 从注册表重新读取 PATH（装完 Node 后当前窗口认不到 node 的头号原因）
function Update-SessionPath {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = New-Object System.Collections.ArrayList
    foreach ($s in @($m, $u, $env:Path)) {
        if ($s) { [void]$parts.Add($s) }
    }
    $env:Path = ($parts -join ';')
    return $env:Path
}

function Expand-PathValue($p) {
    if (-not $p) { return '' }
    try { return [Environment]::ExpandEnvironmentVariables([string]$p) } catch { return [string]$p }
}

function Test-PathListContains($pathList, $dir) {
    if (-not $pathList -or -not $dir) { return $false }
    $want = (Expand-PathValue $dir).TrimEnd('\').ToLower()
    foreach ($e in ([string]$pathList -split ';')) {
        $item = (Expand-PathValue $e).Trim()
        if (-not $item) { continue }
        if ($item.TrimEnd('\').ToLower() -eq $want) { return $true }
    }
    return $false
}

function Test-InPath($dir) { return (Test-PathListContains $env:Path $dir) }

# 把目录补进「用户级 PATH」（不需要管理员），并立即刷新当前窗口
function Add-UserPathEntry($dir) {
    if (-not $dir) { return $false }
    $dir = (Expand-PathValue $dir).TrimEnd('\')
    if (-not (Test-Path $dir)) { return $false }
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (Test-PathListContains $cur $dir) {
        Update-SessionPath | Out-Null
        return $false
    }
    if ($cur -and $cur.Trim()) { $new = $cur.TrimEnd(';') + ';' + $dir } else { $new = $dir }
    try {
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
        Update-SessionPath | Out-Null
        Write-Log ('已把目录加入用户 PATH：' + $dir)
        return $true
    } catch {
        Write-Log ('写入用户 PATH 失败：' + $_.Exception.Message)
        return $false
    }
}

function Get-FreeSpaceGB($path) {
    try {
        if (-not $path) { $path = $env:SystemDrive }
        $root = [IO.Path]::GetPathRoot($path)
        if (-not $root) { return -1 }
        $d = New-Object System.IO.DriveInfo($root)
        return [math]::Round($d.AvailableFreeSpace / 1GB, 1)
    } catch { return -1 }
}

function Test-TcpPort($hostName, $port, $timeoutMs) {
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($hostName, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) { try { $client.Close() } catch {} }
    }
}

function Get-ProxyHint {
    $hints = New-Object System.Collections.ArrayList
    foreach ($n in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy')) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { [void]$hints.Add($n + '=' + $v) }
    }
    try {
        $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($ie -and $ie.ProxyEnable -eq 1 -and $ie.ProxyServer) { [void]$hints.Add('系统代理=' + $ie.ProxyServer) }
    } catch {}
    return $hints.ToArray()
}

# ============================================================
#  三、Node.js / npm 检测
# ============================================================

function Get-NodeCandidatePaths {
    $list = New-Object System.Collections.ArrayList
    $roots = New-Object System.Collections.ArrayList
    if ($env:ProgramFiles) { [void]$roots.Add($env:ProgramFiles) }
    if (${env:ProgramFiles(x86)}) { [void]$roots.Add(${env:ProgramFiles(x86)}) }
    foreach ($r in $roots) { [void]$list.Add((Join-Path $r 'nodejs\node.exe')) }
    if ($env:LOCALAPPDATA) { [void]$list.Add((Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')) }
    if ($env:APPDATA) { [void]$list.Add((Join-Path $env:APPDATA 'nvm\current\node.exe')) }
    if ($env:ProgramData) { [void]$list.Add((Join-Path $env:ProgramData 'nodejs\node.exe')) }
    [void]$list.Add('C:\nodejs\node.exe')
    [void]$list.Add('D:\nodejs\node.exe')
    # nvm-windows 的多版本目录
    if ($env:APPDATA) {
        $nvm = Join-Path $env:APPDATA 'nvm'
        if (Test-Path $nvm) {
            Get-ChildItem $nvm -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                [void]$list.Add((Join-Path $_.FullName 'node.exe'))
            }
        }
    }
    return $list.ToArray()
}

function Get-NodeInfo {
    $o = New-Object psobject -Property @{
        Found = $false; Exe = $null; Dir = $null; Version = $null
        InPath = $false; MeetsMin = $false; TooOld = $false; Source = ''
    }
    $cmd = Get-Command 'node.exe' -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command 'node' -ErrorAction SilentlyContinue }
    if ($cmd -and $cmd.Source) {
        $o.Exe = $cmd.Source; $o.InPath = $true; $o.Source = '已在 PATH 中'
    }
    if (-not $o.Exe) {
        try {
            $paths = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
            $hit = Get-ItemProperty $paths -ErrorAction SilentlyContinue |
                   Where-Object { $_.DisplayName -and $_.DisplayName -like 'Node.js*' } |
                   Select-Object -First 1
            if ($hit -and $hit.InstallLocation) {
                $cand = Join-Path (Expand-PathValue $hit.InstallLocation) 'node.exe'
                if (Test-Path $cand) { $o.Exe = $cand; $o.Source = '注册表记录（未加入 PATH）' }
            }
        } catch {}
    }
    if (-not $o.Exe) {
        foreach ($c in (Get-NodeCandidatePaths)) {
            if ($c -and (Test-Path $c)) { $o.Exe = $c; $o.Source = '默认安装目录（未加入 PATH）'; break }
        }
    }
    if ($o.Exe) {
        $o.Found = $true
        try { $o.Dir = Split-Path $o.Exe -Parent } catch {}
        $raw = $null
        try { $raw = (& $o.Exe -v 2>$null | Select-Object -First 1) } catch {}
        if ($raw) { $o.Version = ([string]$raw).Trim() }
        $o.MeetsMin = Test-VerAtLeast $o.Version $script:PrereqMinNode
        $o.TooOld = ($o.Found -and (-not $o.MeetsMin))
    }
    Write-Log ('node 检测：Found=' + $o.Found + ' Ver=' + $o.Version + ' Exe=' + $o.Exe + ' InPath=' + $o.InPath)
    return $o
}

function Get-NpmInfo($nodeInfo) {
    $o = New-Object psobject -Property @{
        Found = $false; Exe = $null; Version = $null; InPath = $false; MeetsMin = $false
    }
    $cmd = Get-Command 'npm.cmd' -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command 'npm' -ErrorAction SilentlyContinue }
    if ($cmd -and $cmd.Source) { $o.Exe = $cmd.Source; $o.InPath = $true }
    if (-not $o.Exe -and $nodeInfo -and $nodeInfo.Dir) {
        $cand = Join-Path $nodeInfo.Dir 'npm.cmd'
        if (Test-Path $cand) { $o.Exe = $cand }
    }
    if ($o.Exe) {
        $o.Found = $true
        $raw = $null
        try { $raw = (& $o.Exe -v 2>$null | Select-Object -First 1) } catch {}
        if ($raw) { $o.Version = ([string]$raw).Trim() }
        $o.MeetsMin = Test-VerAtLeast $o.Version $script:PrereqMinNpm
    }
    Write-Log ('npm 检测：Found=' + $o.Found + ' Ver=' + $o.Version + ' Exe=' + $o.Exe)
    return $o
}

function Get-NpmPrefix($npmInfo, $nodeInfo) {
    if ($npmInfo -and $npmInfo.Found -and $npmInfo.Exe) {
        $old = $env:Path
        try {
            if ($nodeInfo -and $nodeInfo.Dir -and -not (Test-InPath $nodeInfo.Dir)) { $env:Path = $nodeInfo.Dir + ';' + $env:Path }
            $p = (& $npmInfo.Exe config get prefix 2>$null | Select-Object -First 1)
            if ($p -and ([string]$p).Trim()) { return (Expand-PathValue ([string]$p).Trim()) }
        } catch {} finally { $env:Path = $old }
    }
    if ($env:APPDATA) { return (Join-Path $env:APPDATA 'npm') }
    return $null
}

# ============================================================
#  四、网络与镜像检测
# ============================================================

function Test-NpmRegistry($registryUrl, $timeoutSec) {
    $r = New-Object psobject -Property @{ Ok = $false; Url = $registryUrl; Latest = $null; EngineNode = $null; Detail = '' }
    $u = ([string]$registryUrl).TrimEnd('/') + '/@anthropic-ai/claude-code/latest'
    try {
        $resp = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec $timeoutSec
        $j = $resp.Content | ConvertFrom-Json
        $r.Ok = $true
        $r.Latest = [string]$j.version
        if ($j.engines -and $j.engines.node) { $r.EngineNode = [string]$j.engines.node }
        $r.Detail = 'HTTP ' + $resp.StatusCode
    } catch {
        $r.Detail = $_.Exception.Message
    }
    Write-Log ('npm 源探测 ' + $registryUrl + ' => ' + $r.Ok + ' latest=' + $r.Latest + ' (' + $r.Detail + ')')
    return $r
}

function Get-CurrentNpmRegistry($npmInfo, $nodeInfo) {
    if ($npmInfo -and $npmInfo.Found -and $npmInfo.Exe) {
        $old = $env:Path
        try {
            if ($nodeInfo -and $nodeInfo.Dir -and -not (Test-InPath $nodeInfo.Dir)) { $env:Path = $nodeInfo.Dir + ';' + $env:Path }
            $v = (& $npmInfo.Exe config get registry 2>$null | Select-Object -First 1)
            if ($v -and ([string]$v).Trim()) { return ([string]$v).Trim() }
        } catch {} finally { $env:Path = $old }
    }
    return $null
}

# ============================================================
#  五、Claude Code 现状 + 离线包完整性
# ============================================================

function Get-ClaudeInfo {
    $o = New-Object psobject -Property @{ Found = $false; Exe = $null; Version = $null; InPath = $false; Running = $false }
    $cmd = Get-Command 'claude' -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { $o.Exe = $cmd.Source; $o.InPath = $true }
    if ($o.Exe) {
        $o.Found = $true
        try { $o.Version = ([string](& $o.Exe --version 2>$null | Select-Object -First 1)).Trim() } catch {}
    }
    try {
        $procs = Get-Process -Name 'claude' -ErrorAction SilentlyContinue
        if ($procs) { $o.Running = $true }
    } catch {}
    return $o
}

function Test-OfflinePackage($installDir) {
    $dir = Join-Path $installDir $script:PrereqOfflineDir
    $o = New-Object psobject -Property @{ Exists = $false; Dir = $dir; Missing = @(); SizeMB = 0 }
    if (-not (Test-Path $dir)) { $o.Missing = @('整个离线包目录'); return $o }
    $o.Exists = $true
    $need = @(
        'node_modules\@anthropic-ai\claude-code\package.json',
        'node_modules\@anthropic-ai\claude-code\bin\claude.exe',
        'claude.cmd',
        'claude.ps1',
        'claude'
    )
    $missing = New-Object System.Collections.ArrayList
    foreach ($n in $need) { if (-not (Test-Path (Join-Path $dir $n))) { [void]$missing.Add($n) } }
    $o.Missing = $missing.ToArray()
    try {
        $sum = (Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        $o.SizeMB = [math]::Round($sum / 1MB, 0)
    } catch {}
    return $o
}

function Find-NodeMsi($dirs) {
    foreach ($d in $dirs) {
        if (-not $d -or -not (Test-Path $d)) { continue }
        $hit = Get-ChildItem -Path $d -Filter 'node-v*.msi' -File -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

# ============================================================
#  六、体检报告
# ============================================================

function Add-Issue($list, $id, $level, $title, $hint, $fixable) {
    [void]$list.Add((New-Object psobject -Property @{
        Id = $id; Level = $level; Title = $title; Hint = $hint; Fixable = [bool]$fixable
    }))
}

function Get-EnvReport($mode, $installDir) {
    Write-Log ('===== 开始体检 mode=' + $mode + ' =====')
    $rep = New-Object psobject -Property @{
        Mode = $mode; Admin = $false; Arch = ''; IsArm = $false; OsName = ''
        DiskFreeGB = -1; DiskPath = ''; Interactive = $false; Proxy = @()
        Node = $null; Npm = $null; NpmPrefix = $null; PrefixInPath = $false
        RegistryCurrent = $null; Mirror = $null; MirrorFallback = $null; NetOk = $false
        Claude = $null; Offline = $null; OfflinePathInPath = $false
        Issues = @()
    }

    # 系统 & 权限
    $rep.Admin = Test-Admin
    $rep.Arch = $env:PROCESSOR_ARCHITECTURE
    $rep.IsArm = ($rep.Arch -eq 'ARM64')
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) { $rep.OsName = ([string]$os.Caption).Trim() }
    } catch {}
    if (-not $rep.OsName) { $rep.OsName = [Environment]::OSVersion.VersionString }
    $rep.Interactive = Test-InteractiveConsole
    $rep.Proxy = Get-ProxyHint

    $diskTarget = $installDir
    if (-not $diskTarget -or -not (Test-Path $diskTarget)) { $diskTarget = $env:TEMP }
    $rep.DiskPath = $diskTarget
    $rep.DiskFreeGB = Get-FreeSpaceGB $diskTarget

    # Node / npm
    $rep.Node = Get-NodeInfo
    $rep.Npm = Get-NpmInfo $rep.Node
    $rep.NpmPrefix = Get-NpmPrefix $rep.Npm $rep.Node
    if ($rep.NpmPrefix) { $rep.PrefixInPath = Test-InPath $rep.NpmPrefix }

    # 网络（联网模式才会真正用到）
    $rep.RegistryCurrent = Get-CurrentNpmRegistry $rep.Npm $rep.Node
    $mirrorUrl = 'https://registry.npmmirror.com'
    $rep.Mirror = Test-NpmRegistry $mirrorUrl 20
    $rep.NetOk = $true
    if (-not $rep.Mirror.Ok) {
        if (Test-TcpPort 'registry.npmmirror.com' 443 4000) {
            $rep.Mirror.Detail = '端口通但接口没回应（可能被校园网/代理拦了 HTTPS）'
        }
        $rep.MirrorFallback = Test-NpmRegistry 'https://registry.npmjs.org' 20
        if (-not $rep.MirrorFallback.Ok) { $rep.NetOk = $false }
    }

    $rep.Claude = Get-ClaudeInfo
    $rep.Offline = Test-OfflinePackage $installDir

    # ---------------- 结论：逐条列问题 ----------------
    $issues = New-Object System.Collections.ArrayList

    if ($rep.DiskFreeGB -ge 0 -and $rep.DiskFreeGB -lt $script:PrereqMinDiskGB) {
        Add-Issue $issues 'disk-low' 'warn' ('磁盘剩余空间只有 ' + $rep.DiskFreeGB + ' GB（建议至少 ' + $script:PrereqMinDiskGB + ' GB）') 'Claude Code 装在系统盘的用户目录下，空间不足会中途失败：清一下回收站/下载文件夹再来。' $false
    }

    if (-not $rep.Node.Found) {
        Add-Issue $issues 'node-missing' 'block' ('Node.js 没有安装（Claude Code 的必需地基，要求 ' + $script:PrereqMinNode + ' 以上）') '本脚本可以自动帮你装：优先用同目录自带的 node msi，其次从国内镜像下载（约 30MB）。' $true
    } elseif (-not $rep.Node.MeetsMin) {
        Add-Issue $issues 'node-too-old' 'block' ('Node.js 版本过低：' + $rep.Node.Version + '（Claude Code 要求 >= ' + $script:PrereqMinNode + '）') 'npm 会直接拒绝安装或装完起不来：需要把 Node 升到 22 以上（本脚本可自动装新版覆盖）。' $true
    } elseif (-not $rep.Node.InPath) {
        Add-Issue $issues 'node-not-in-path' 'block' ('Node.js 装了但没在 PATH 里：' + $rep.Node.Exe) '窗口里敲 node 会提示"不是内部或外部命令"：本脚本可以自动把目录写进用户 PATH。' $true
    }

    if (-not $rep.Npm.Found) {
        Add-Issue $issues 'npm-missing' 'block' 'npm 不可用（Node.js 自带 npm，通常是一起没装好或没在 PATH 里）' '本脚本会尝试用 Node 安装包修复（重跑一次安装器）。' $true
    } elseif (-not $rep.Npm.InPath -and -not $rep.Node.InPath) {
        Add-Issue $issues 'npm-not-in-path' 'warn' 'npm 不在 PATH 里（脚本内部仍可调用，但你手动敲 npm 会失败）' '把 Node 目录写进用户 PATH 即可，本脚本可自动处理。' $true
    }

    if ($rep.NpmPrefix -and -not $rep.PrefixInPath) {
        Add-Issue $issues 'prefix-not-in-path' 'warn' ('npm 全局目录不在 PATH 里：' + $rep.NpmPrefix) '这是「claude 装好了却敲不出命令」的头号原因：本脚本会自动补进用户 PATH。' $true
    }

    if ($mode -eq 'Offline') {
        if (-not $rep.Offline.Exists) {
            Add-Issue $issues 'offline-missing' 'block' ('找不到离线安装包目录 ' + $script:PrereqOfflineDir + '（压缩包可能没解压完整）') '请改用「安装ClaudeCode-一键联网安装.bat」，或重新解压完整的礼包。' $false
        } elseif ($rep.Offline.Missing.Count -gt 0) {
            Add-Issue $issues 'offline-incomplete' 'block' ('离线安装包不完整，缺少：' + ($rep.Offline.Missing -join '、')) '重新解压礼包，或改用联网安装脚本。' $false
        }
        if ($rep.Claude.Running) {
            Add-Issue $issues 'claude-running' 'block' '检测到 claude 正在运行，离线覆盖文件会失败' '请先关掉正在运行的 Claude Code 窗口（脚本会等你确认后再动手）。' $true
        }
    }

    if ($mode -eq 'Online' -and -not $rep.NetOk) {
        Add-Issue $issues 'net-down' 'block' '连不上 npm 源（npmmirror 与 npmjs 都不通）' '开一下代理或换个网络重试；也可以用「安装ClaudeCode-离线安装.bat」完全不联网装。' $false
    } elseif ($mode -eq 'Online' -and -not $rep.Mirror.Ok -and $rep.MirrorFallback -and $rep.MirrorFallback.Ok) {
        Add-Issue $issues 'mirror-fallback' 'warn' '国内镜像 npmmirror 不通，将回退到官方 npm 源（慢一些，可能需要代理）' '校园网/公司网经常拦镜像，回退即可完成安装。' $false
    }

    if ($rep.Claude.Found) {
        $verTxt = $rep.Claude.Version
        if (-not $verTxt) { $verTxt = '（版本号读不到）' }
        if ($mode -eq 'Offline') {
            Add-Issue $issues 'claude-exists' 'warn' ('已安装 Claude Code：' + $verTxt + ' —— 离线安装会覆盖成礼包内版本') '想保持新版就改用联网安装脚本（会自动升级）。' $false
        } else {
            Add-Issue $issues 'claude-exists' 'warn' ('已安装 Claude Code：' + $verTxt + ' —— 将执行升级到最新版') '升级是安全的，配置和密钥都不受影响。' $false
        }
    }

    $rep.Issues = $issues.ToArray()
    Write-Log ('体检结束：问题数=' + $rep.Issues.Count)
    return $rep
}

function Show-EnvReport($rep) {
    Section '第一步 · 前置环境体检（这一步不装任何东西）'

    $osLine = $rep.OsName
    if ($rep.Arch) { $osLine = $osLine + ' / ' + $rep.Arch }
    if ($rep.Admin) { OK ('系统正常：' + $osLine + '（管理员权限：有）') }
    else { WARN ('系统正常：' + $osLine + '（管理员权限：无 —— 装 Node 时会弹一次 UAC，点"是"即可）') }

    if ($rep.DiskFreeGB -ge 0) {
        if ($rep.DiskFreeGB -ge $script:PrereqMinDiskGB) { OK ('磁盘剩余空间：' + $rep.DiskFreeGB + ' GB（足够）') }
        else { WARN ('磁盘剩余空间：' + $rep.DiskFreeGB + ' GB（偏小，建议先清理）') }
    }

    if ($rep.Node.Found -and $rep.Node.MeetsMin -and $rep.Node.InPath) {
        OK ('Node.js ' + $rep.Node.Version + ' 已就绪（要求 >= ' + $script:PrereqMinNode + '）')
    } elseif ($rep.Node.Found -and $rep.Node.MeetsMin -and -not $rep.Node.InPath) {
        WARN ('Node.js ' + $rep.Node.Version + ' 已装，但没进 PATH：' + $rep.Node.Exe)
    } elseif ($rep.Node.Found -and -not $rep.Node.MeetsMin) {
        BAD ('Node.js 版本过低：' + $rep.Node.Version + '（要求 >= ' + $script:PrereqMinNode + '）')
    } else {
        BAD ('Node.js 未安装（要求 >= ' + $script:PrereqMinNode + '）')
    }

    if ($rep.Npm.Found) {
        if ($rep.Npm.MeetsMin) { OK ('npm ' + $rep.Npm.Version + ' 可用') }
        else { WARN ('npm ' + $rep.Npm.Version + ' 可用，但版本偏低（建议 >= ' + $script:PrereqMinNpm + '，随 Node 22 一起装）') }
    } else { BAD 'npm 不可用' }

    if ($rep.NpmPrefix) {
        if ($rep.PrefixInPath) { OK ('npm 全局目录已在 PATH：' + $rep.NpmPrefix) }
        else { WARN ('npm 全局目录不在 PATH：' + $rep.NpmPrefix + '（装完后可能敲不出 claude）') }
    }

    if ($rep.Mode -eq 'Online') {
        if ($rep.Mirror.Ok) {
            $t = '国内镜像 npmmirror 通畅（线上最新版 ' + $rep.Mirror.Latest + '）'
            if ($rep.Mirror.EngineNode) { $t = $t + '，要求 node ' + $rep.Mirror.EngineNode }
            OK $t
        } elseif ($rep.MirrorFallback -and $rep.MirrorFallback.Ok) {
            WARN '国内镜像不通，已确认官方源可用（将自动回退）'
        } else {
            BAD '连不上任何 npm 源（npmmirror / npmjs 都不通）'
        }
        $reg = $rep.RegistryCurrent
        if ($reg) { INFO ('当前 npm 源：' + $reg) }
        if ($rep.Proxy.Count -gt 0) { INFO ('检测到代理设置：' + ($rep.Proxy -join ' / ')) }
    } else {
        if ($rep.Offline.Exists -and $rep.Offline.Missing.Count -eq 0) {
            OK ('离线安装包完整（约 ' + $rep.Offline.SizeMB + ' MB）')
        } elseif ($rep.Offline.Exists) {
            BAD ('离线安装包不完整，缺少：' + ($rep.Offline.Missing -join '、'))
        } else {
            BAD ('找不到离线安装包目录：' + $rep.Offline.Dir)
        }
    }

    if ($rep.Claude.Found) {
        INFO ('已安装 Claude Code：' + $rep.Claude.Version + '（' + $rep.Claude.Exe + '）')
        if ($rep.Claude.Running) { WARN 'Claude Code 正在运行（离线覆盖前需要先关掉）' }
    } else {
        INFO '尚未安装 Claude Code（本次就是要装它）'
    }

    Section '体检结论'
    $blocks = @($rep.Issues | Where-Object { $_.Level -eq 'block' })
    $warns  = @($rep.Issues | Where-Object { $_.Level -eq 'warn' })
    if ($rep.Issues.Count -eq 0) {
        OK '前置条件全部满足，可以直接安装。'
    } else {
        foreach ($i in $blocks) { BAD $i.Title; TIP $i.Hint }
        foreach ($i in $warns)  { WARN $i.Title; TIP $i.Hint }
        Write-Host ''
        INFO ('小结：' + $blocks.Count + ' 个必须先解决的问题，' + $warns.Count + ' 个提醒。')
    }
    return $blocks
}

# ============================================================
#  七、自动修复动作
# ============================================================

function Test-MsiSignature($msiPath) {
    try {
        $sig = Get-AuthenticodeSignature -FilePath $msiPath
        if ($sig -and $sig.Status -eq 'Valid') {
            $subj = ''
            try { $subj = $sig.SignerCertificate.Subject } catch {}
            return (New-Object psobject -Property @{ Ok = $true; Detail = $subj })
        }
        return (New-Object psobject -Property @{ Ok = $false; Detail = ('签名状态：' + $sig.Status) })
    } catch {
        return (New-Object psobject -Property @{ Ok = $false; Detail = '签名无法校验' })
    }
}

function Install-MsiPackage($msiPath, $label) {
    $o = New-Object psobject -Property @{ Ok = $false; Code = -1; Log = '' }
    if (-not (Test-Path $msiPath)) { return $o }
    $msiLog = Join-Path $env:TEMP ('msi-' + [IO.Path]::GetFileNameWithoutExtension($msiPath) + '-' + (Get-Date -Format 'HHmmss') + '.log')
    $o.Log = $msiLog
    $msiArgs = @('/i', ('"' + $msiPath + '"'), '/qb', '/norestart', '/l*v', ('"' + $msiLog + '"'))
    INFO ('正在静默安装 ' + $label + '（大约 1 分钟，中途会弹一次 UAC 请点"是"）...')
    Write-Log ('msiexec ' + ($msiArgs -join ' '))
    try {
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
        $o.Code = $p.ExitCode
    } catch {
        Write-Log ('msiexec 启动失败：' + $_.Exception.Message)
        $o.Code = -1
    }
    if ($o.Code -eq 0 -or $o.Code -eq 3010) { $o.Ok = $true; return $o }
    # 静默失败时退回带界面的安装（一路下一步，用户点得动）
    WARN ('静默安装返回代码 ' + $o.Code + '，改用带界面的安装器再试一次...')
    try {
        $p2 = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', ('"' + $msiPath + '"'), '/norestart') -Wait -PassThru
        $o.Code = $p2.ExitCode
        if ($o.Code -eq 0 -or $o.Code -eq 3010) { $o.Ok = $true }
    } catch {
        Write-Log ('带界面安装也失败：' + $_.Exception.Message)
    }
    return $o
}

function Get-NodeMsiDownloadUrls($arch) {
    $urls = New-Object System.Collections.ArrayList
    $v = $script:PrereqPinnedNode
    [void]$urls.Add(('https://mirrors.huaweicloud.com/nodejs/v{0}/node-v{0}-{1}.msi' -f $v, $arch))
    [void]$urls.Add(('https://nodejs.org/dist/v{0}/node-v{0}-{1}.msi' -f $v, $arch))
    # 兜底：查 npmmirror 的二进制镜像，取 22.x 里最新的一个
    try {
        $list = Invoke-RestMethod -Uri 'https://registry.npmmirror.com/-/binary/node/latest-v22.x/' -TimeoutSec 15
        $bestV = $null; $bestU = $null
        foreach ($f in @($list)) {
            if (-not $f.name) { continue }
            if ($f.name -notmatch ('^node-v(\d+\.\d+\.\d+)-' + $arch + '\.msi$')) { continue }
            $cv = ConvertTo-NumVersion $Matches[1]
            if (-not $bestV -or $cv -gt $bestV) { $bestV = $cv; $bestU = $f.url }
        }
        if ($bestU) { [void]$urls.Add($bestU) }
    } catch { Write-Log ('查询 npmmirror Node 版本列表失败：' + $_.Exception.Message) }
    return $urls.ToArray()
}

function Save-NodeMsi($url, $timeoutSec) {
    $dir = Join-Path $env:TEMP 'AI-Starter-Kit'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir ([IO.Path]::GetFileName(([uri]$url).AbsolutePath))
    try {
        INFO ('正在下载 Node.js 安装包：' + $url)
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -TimeoutSec $timeoutSec
        if ((Test-Path $file) -and ((Get-Item $file).Length -gt 10MB)) { return $file }
        Write-Log ('下载文件过小，视为失败：' + $file)
        return $null
    } catch {
        Write-Log ('下载失败 ' + $url + ' => ' + $_.Exception.Message)
        return $null
    }
}

function Install-NodeViaWinget {
    $o = New-Object psobject -Property @{ Ok = $false; Detail = '' }
    $wg = Get-Command 'winget' -ErrorAction SilentlyContinue
    if (-not $wg) { $o.Detail = '本机没有 winget'; return $o }
    INFO '正在用 winget 安装 Node.js LTS（可能要几分钟）...'
    try {
        $p = Start-Process -FilePath $wg.Source -ArgumentList @('install', '--id', 'OpenJS.NodeJS.LTS', '--silent', '--accept-package-agreements', '--accept-source-agreements') -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -eq 0) { $o.Ok = $true } else { $o.Detail = 'winget 退出码 ' + $p.ExitCode }
    } catch {
        $o.Detail = $_.Exception.Message
    }
    Write-Log ('winget 结果：' + $o.Ok + ' ' + $o.Detail)
    return $o
}

# 自动把 Node.js 装好（返回 $true 表示装完可用）
function Repair-NodePrereq($rep, $installDir) {
    $arch = 'x64'
    if ($rep.IsArm) { $arch = 'arm64' }

    $searchDirs = @(
        $installDir,
        (Join-Path $installDir '..'),
        (Join-Path $installDir '安装包'),
        $env:USERPROFILE,
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:TEMP 'AI-Starter-Kit')
    )
    $msi = Find-NodeMsi $searchDirs   # 本机/礼包里已有安装包就用它（ARM 机器上 x64 包也能用）

    if ($msi) {
        OK ('找到现成的 Node 安装包：' + $msi)
        $sig = Test-MsiSignature $msi
        if ($sig.Ok) { INFO ('安装包数字签名有效：' + $sig.Detail) } else { WARN ('安装包签名未通过校验（' + $sig.Detail + '）—— 非官方来源请谨慎') }
        $r = Install-MsiPackage $msi 'Node.js'
        Update-SessionPath | Out-Null
        $n = Get-NodeInfo
        if ($r.Ok -and $n.Found -and $n.MeetsMin) { return $true }
        Write-Log ('本地 msi 安装未成功，继续尝试其它途径。msi exit=' + $r.Code)
    } else {
        WARN '同目录没找到 node 安装包，改用自动下载。'
    }

    # 下载安装包
    foreach ($url in (Get-NodeMsiDownloadUrls $arch)) {
        $file = Save-NodeMsi $url 300
        if (-not $file) { continue }
        $sig = Test-MsiSignature $file
        if ($sig.Ok) { INFO ('安装包数字签名有效：' + $sig.Detail) } else { WARN ('下载包的签名未通过校验（' + $sig.Detail + '）') }
        $r = Install-MsiPackage $file 'Node.js'
        Update-SessionPath | Out-Null
        $n = Get-NodeInfo
        if ($r.Ok -and $n.Found -and $n.MeetsMin) { return $true }
    }

    # winget 兜底
    $w = Install-NodeViaWinget
    Update-SessionPath | Out-Null
    $n = Get-NodeInfo
    if ($w.Ok -and $n.Found -and $n.MeetsMin) { return $true }

    return $false
}

# 修复「装了但不在 PATH」
function Repair-NodePath($rep) {
    $fixed = $false
    if ($rep.Node.Found -and $rep.Node.Dir -and -not (Test-InPath $rep.Node.Dir)) {
        if (Add-UserPathEntry $rep.Node.Dir) { OK ('已把 Node 目录加入用户 PATH：' + $rep.Node.Dir + '（新开的窗口都生效）'); $fixed = $true }
    }
    if ($rep.NpmPrefix -and -not (Test-InPath $rep.NpmPrefix)) {
        if (Add-UserPathEntry $rep.NpmPrefix) { OK ('已把 npm 全局目录加入用户 PATH：' + $rep.NpmPrefix); $fixed = $true }
    }
    return $fixed
}

# 修复 npm 缺失：用 Node 安装包做一次修复安装
function Repair-NpmPrereq($rep, $installDir) {
    $searchDirs = @($installDir, (Join-Path $installDir '..'), $env:USERPROFILE, (Join-Path $env:USERPROFILE 'Downloads'))
    $msi = Find-NodeMsi $searchDirs
    if (-not $msi) { WARN '找不到 Node 安装包，无法自动修复 npm。'; return $false }
    INFO '正在用 Node 安装包做一次「修复安装」（补回 npm）...'
    $log = Join-Path $env:TEMP ('msi-repair-' + (Get-Date -Format 'HHmmss') + '.log')
    try {
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/fa', ('"' + $msi + '"'), '/qb', '/norestart', '/l*v', ('"' + $log + '"')) -Wait -PassThru
        Update-SessionPath | Out-Null
        $n = Get-NpmInfo (Get-NodeInfo)
        if ($n.Found) { OK ('npm 已恢复：' + $n.Version); return $true }
        Write-Log ('修复安装退出码 ' + $p.ExitCode)
    } catch { Write-Log ('修复安装失败：' + $_.Exception.Message) }
    return $false
}

function Stop-ClaudeProcess {
    try {
        $procs = Get-Process -Name 'claude' -ErrorAction SilentlyContinue
        if (-not $procs) { return $true }
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $left = Get-Process -Name 'claude' -ErrorAction SilentlyContinue
        return (-not $left)
    } catch { return $false }
}

function Open-NodeDownloadPage {
    try { Start-Process 'https://nodejs.org/zh-cn/download' } catch {}
}
