@echo off
rem ============================================================
rem  WPS Tune v2 - single file launcher
rem  Constraints: pure ASCII here, CRLF line endings, no BOM.
rem  All Chinese text lives in the embedded PowerShell section,
rem  which is extracted to a temp .ps1 (with BOM) at runtime.
rem ============================================================
setlocal EnableExtensions

rem -- already admin? then run directly
net session >nul 2>&1
if errorlevel 1 goto elevate
goto run

:elevate
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
if errorlevel 1 (
    echo [!] UAC declined - continuing without admin rights.
    goto run
)
exit /b 0

:run
cd /d "%~dp0"
set "WPSTUNE_DIR=%~dp0"
set "WPSTUNE_PS=%TEMP%\wps-tune-%RANDOM%.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText('%~f0');$a=('#PS'+'-BEGIN');$b=('#PS'+'-END');$s=$t.IndexOf($a);$s=$t.IndexOf([char]10,$s)+1;$e=$t.IndexOf($b);$e=$t.LastIndexOf([char]10,$e)+1;[IO.File]::WriteAllText('%WPSTUNE_PS%',$t.Substring($s,$e-$s),[Text.Encoding]::UTF8)"
if not exist "%WPSTUNE_PS%" (
    echo [!] Failed to extract embedded script.
    pause
    exit /b 1
)
chcp 65001 >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%WPSTUNE_PS%"
set "RC=%errorlevel%"
del /q "%WPSTUNE_PS%" >nul 2>&1
exit /b %RC%

rem #PS-BEGIN
# ============================================================
#  WPS 优化工具 v2.0 —— 业务脚本段
#  本段由上方 BAT 自动提取为临时 ps1 运行,不要手动执行。
#  所有路径自动探测,不绑定机器;状态与备份落在 BAT 同目录。
# ============================================================
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$ProgressPreference = 'SilentlyContinue'

$Script:Version   = '2.0.0'
$Script:Root      = if ($env:WPSTUNE_DIR) { $env:WPSTUNE_DIR.TrimEnd('\') } else { (Get-Location).Path }
$Script:StateFile = Join-Path $Script:Root 'wps-tune-state.json'
$Script:BackupDir = Join-Path $Script:Root 'backups'
$Script:FreedMB   = 0.0
$Script:Actions   = @()
$Script:Install   = $null

# WPS 全家桶常见进程名
$Script:WpsProcNames = @(
    'wps', 'et', 'wpp', 'wpsoffice', 'ksolaunch', 'ksomisc',
    'wpscloudsvr', 'wpscenter', 'wpslingxi', 'wpspdf', 'wpsupdate'
)

# ---------------------------------------------------------------- 输出

$Script:Bar = '=' * 46

function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host $Script:Bar -ForegroundColor DarkGray
    Write-Host (" {0}" -f $Text) -ForegroundColor Cyan
    Write-Host $Script:Bar -ForegroundColor DarkGray
}
function Write-Ok([string]$Text)   { Write-Host ("  [OK] {0}" -f $Text) -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host ("       {0}" -f $Text) -ForegroundColor Gray }
function Write-Warn2([string]$Text){ Write-Host ("  [!!] {0}" -f $Text) -ForegroundColor Yellow }
function Write-Err2([string]$Text) { Write-Host ("  [XX] {0}" -f $Text) -ForegroundColor Red }
function Write-Plan([string]$Text) { Write-Host ("  [..] {0}" -f $Text) -ForegroundColor Magenta }

function Pause-Menu {
    $null = Read-Host "`n  按回车返回菜单"
}

# ---------------------------------------------------------------- 基础工具

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-DirSizeMB {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0 }
        return [math]::Round([double]$sum / 1MB, 1)
    } catch { return 0 }
}

function Get-RealAllocMB {
    # 真实磁盘占用:GetCompressedFileSizeW 对云盘占位文件返回实际分配大小
    param([string]$Path, $Files = $null)
    if (-not ('WpsTune.Native' -as [type])) {
        Add-Type -Namespace WpsTune -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);
'@ -ErrorAction SilentlyContinue
    }
    if (-not ('WpsTune.Native' -as [type])) { return $null }
    if (-not $Files) {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $Files = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue
    }
    $total = [double]0
    foreach ($f in $Files) {
        $hi = [uint32]0
        $lo = [WpsTune.Native]::GetCompressedFileSizeW($f.FullName, [ref]$hi)
        if ($lo -eq [uint32]::MaxValue -and $hi -eq [uint32]::MaxValue) { continue }
        $total += ([double]$hi * 4294967296 + [double]$lo)
    }
    return [math]::Round($total / 1MB, 1)
}

function Get-DirStats {
    # 一遍遍历同时得到逻辑大小与真实占用;文件数超 5 万时跳过真实占用统计
    param([string]$Path)
    $r = [PSCustomObject]@{ LogicalMB = 0.0; RealMB = $null; Count = 0 }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $r }
    try {
        $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
        $r.Count = $files.Count
        $sum = ($files | Measure-Object -Property Length -Sum).Sum
        if ($null -ne $sum) { $r.LogicalMB = [math]::Round([double]$sum / 1MB, 1) }
        if ($r.Count -gt 0 -and $r.Count -le 50000) {
            $r.RealMB = Get-RealAllocMB -Path $Path -Files $files
        }
    } catch { }
    return $r
}

function Get-WpsProcesses {
    Get-Process -Name $Script:WpsProcNames -ErrorAction SilentlyContinue
}

function Get-PathMediaType {
    # 路径所在物理盘是 SSD 还是 HDD;判不了时如实返回「未知」
    param([string]$Path)
    $letter = (Split-Path -Path $Path -Qualifier) -replace ':$', ''
    if ([string]::IsNullOrWhiteSpace($letter)) { return $null }
    $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $part) { return $null }
    $name = $null; $media = $null
    $pd = Get-PhysicalDisk -ErrorAction SilentlyContinue |
          Where-Object { $_.DeviceId -eq $part.DiskNumber } | Select-Object -First 1
    if ($pd) { $name = $pd.FriendlyName; $media = $pd.MediaType }
    if (-not $name -or -not $media) {
        $disk = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue
        if ($disk) {
            if (-not $name) { $name = $disk.FriendlyName }
            if (-not $media) { $media = $disk.MediaType }
        }
    }
    if ([string]::IsNullOrWhiteSpace($media) -or $media -eq 'Unspecified') {
        $disk = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue
        if ($disk -and $disk.BusType -eq 'NVMe') { $media = 'SSD' } else { $media = '未知' }
    }
    if (-not $name) { $name = '磁盘' + $part.DiskNumber }
    return [PSCustomObject]@{ Name = $name; MediaType = $media }
}

function Close-Wps {
    # 关闭全部 WPS 进程。调用方负责事先向用户确认过。
    $procs = Get-WpsProcesses
    if (-not $procs) { return $true }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $left = Get-WpsProcesses
    if ($left) {
        $left | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    return [bool](-not (Get-WpsProcesses))
}

# ---------------------------------------------------------------- 安装探测

function Get-WpsInstall {
    # 返回 Root / CurrentDir / Version / Exe / Source;全部从注册表与磁盘推断
    if ($Script:Install) { return $Script:Install }
    $cands = @()

    $commonKeys = @(
        'HKCU:\Software\Kingsoft\Office\6.0\Common',
        'HKLM:\SOFTWARE\WOW6432Node\Kingsoft\Office\6.0\common',
        'HKLM:\SOFTWARE\Kingsoft\Office\6.0\common'
    )
    foreach ($k in $commonKeys) {
        if (-not (Test-Path $k)) { continue }
        $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if ($p -and $p.InstallRoot -and (Test-Path -LiteralPath $p.InstallRoot)) {
            $cands += [PSCustomObject]@{
                Dir = $p.InstallRoot.TrimEnd('\'); Version = $p.PersonalVersionNumber; Source = '注册表'
            }
        }
    }

    $uninstRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($r in $uninstRoots) {
        Get-ItemProperty -Path $r -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'WPS' -and $_.UninstallString } |
            ForEach-Object {
                $u = $_.UninstallString.Trim('"')
                $u = ($u -split '\s+')[0].Trim('"')
                if ($u -match 'uninst\.exe$' -and (Test-Path -LiteralPath $u)) {
                    $verDir = Split-Path (Split-Path $u -Parent) -Parent
                    if (Test-Path -LiteralPath $verDir) {
                        $cands += [PSCustomObject]@{
                            Dir = $verDir.TrimEnd('\'); Version = $_.DisplayVersion; Source = '卸载项'
                        }
                    }
                }
            }
    }

    $fallbackRoots = @(
        "$env:ProgramFiles\WPS Office",
        "${env:ProgramFiles(x86)}\WPS Office",
        "$env:LOCALAPPDATA\Kingsoft\WPS Office",
        "$env:LOCALAPPDATA\WPS Office"
    )
    foreach ($fr in $fallbackRoots) {
        if (-not (Test-Path -LiteralPath $fr)) { continue }
        Get-ChildItem -LiteralPath $fr -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+(\.\d+){2,3}$' } |
            ForEach-Object {
                $cands += [PSCustomObject]@{ Dir = $_.FullName.TrimEnd('\'); Version = $_.Name; Source = '默认路径' }
            }
    }

    $valid = @()
    foreach ($c in $cands) {
        $exe = Join-Path $c.Dir 'office6\wps.exe'
        if (Test-Path -LiteralPath $exe) {
            $valid += [PSCustomObject]@{
                Root       = (Split-Path $c.Dir -Parent).TrimEnd('\')
                CurrentDir = $c.Dir
                Version    = $(if ($c.Version) { $c.Version } else { Split-Path $c.Dir -Leaf })
                Exe        = $exe
                Source     = $c.Source
            }
        }
    }
    if (-not $valid) { return $null }
    $best = $valid | Sort-Object -Property @{ Expression = {
                try { [version]($_.Version) } catch { [version]'0.0.0' }
            } } -Descending | Select-Object -First 1
    $Script:Install = $best
    return $best
}

# ---------------------------------------------------------------- 可逆状态

function Save-State {
    param($Install)
    $state = [ordered]@{
        toolVersion = $Script:Version
        capturedAt  = (Get-Date).ToString('s')
        install     = [ordered]@{
            root = $Install.Root; currentDir = $Install.CurrentDir
            version = $Install.Version; source = $Install.Source
        }
        actions = $Script:Actions
        notes   = '云服务通过重命名 exe 禁用;WPS 升级可能重新生成该文件,届时重跑「一键优化」'
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -Path $Script:StateFile -Encoding UTF8
}

function Read-State {
    if (Test-Path -LiteralPath $Script:StateFile) {
        try { return Get-Content -LiteralPath $Script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    return $null
}

function Add-Action {
    # 记录一条已执行的可逆动作,并同步写入状态文件(不存在则新建)
    param([hashtable]$Entry)
    $item = [ordered]@{ at = (Get-Date).ToString('s') }
    foreach ($k in $Entry.Keys) { $item[$k] = $Entry[$k] }
    $Script:Actions += @($item)
    $st = Read-State
    if (-not $st) {
        $st = [ordered]@{
            toolVersion = $Script:Version
            capturedAt  = (Get-Date).ToString('s')
            install     = $null
            actions     = @()
        }
        $inst = Get-WpsInstall
        if ($inst) {
            $st.install = [ordered]@{
                root = $inst.Root; currentDir = $inst.CurrentDir; version = $inst.Version
            }
        }
    }
    # 重建而非原地赋值:JSON 反序列化出的 PSCustomObject 给不存在的属性赋值会报错
    $out = [ordered]@{
        toolVersion = $st.toolVersion
        capturedAt  = $st.capturedAt
        install     = $st.install
        actions     = $Script:Actions
    }
    $out | ConvertTo-Json -Depth 6 | Set-Content -Path $Script:StateFile -Encoding UTF8
}

# ---------------------------------------------------------------- 保护区(安全红线)

function Get-ProtectedPaths {
    # 绝对不能删的数据。清理动手前逐项硬校验,任何目标落在这里都被拒绝。
    $list = @()
    try {
        $common = Get-ItemProperty 'HKCU:\Software\Kingsoft\Office\6.0\Common' -ErrorAction SilentlyContinue
        if ($common) {
            foreach ($n in @('NewBackupPath', 'CurrentWpsCloudCachePath', 'OldWpsCloudCachePath')) {
                $v = $common.$n
                if ($v) { $list += $v.TrimEnd('\') }
            }
        }
    } catch { }
    # 文档自动恢复备份(未保存文档的副本,最危险)与模板
    $list += (Join-Path $env:APPDATA 'kingsoft\office6\backup')
    $list += (Join-Path $env:APPDATA 'kingsoft\office6\templates')
    return $list | Where-Object { $_ } | Select-Object -Unique
}

function Test-ProtectedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.TrimEnd('\').ToLowerInvariant()
    foreach ($guard in (Get-ProtectedPaths)) {
        $g = $guard.TrimEnd('\').ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($g)) { continue }
        if ($p -eq $g -or $p.StartsWith($g + '\') -or $g.StartsWith($p + '\')) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------- 免登录

function Get-NoLoginKey { return 'HKCU:\Software\Kingsoft\Office\6.0\plugins\officespace\flogin' }

function Get-ForceLoginState {
    $k = Get-NoLoginKey
    if (-not (Test-Path $k)) { return [PSCustomObject]@{ Exists = $false; First = $null; Has = $null } }
    $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
    return [PSCustomObject]@{
        Exists = $true
        First  = $p.enableForceLoginForFirstInstallDevice
        Has    = $p.enableForceLoginForHasInstallDevice
    }
}

function Set-ForceLogin {
    param([bool]$Off)
    $k = Get-NoLoginKey
    try {
        if (-not (Test-Path $k)) { New-Item -Path $k -Force -ErrorAction Stop | Out-Null }
        $value = if ($Off) { 'false' } else { 'true' }
        foreach ($name in @('enableForceLoginForFirstInstallDevice', 'enableForceLoginForHasInstallDevice')) {
            New-ItemProperty -Path $k -Name $name -Value $value -PropertyType String -Force -ErrorAction Stop | Out-Null
        }
        Add-Action -Entry @{ id = 'no-login'; key = $k; value = $value }
        return $true
    } catch {
        Write-Err2 ("写入失败: {0}" -f $_.Exception.Message)
        Write-Info '注册表权限不足时,以管理员身份重新运行本工具。'
        return $false
    }
}

# ---------------------------------------------------------------- 重置使用记录的目标清单

function Get-ProfileRecordTargets {
    $base = 'HKCU:\Software\Kingsoft\Office\6.0'
    $office6 = Join-Path $env:APPDATA 'kingsoft\office6'
    $reg = @(
        @{ Path = "$base\wps\RecentFiles";          Name = 'WPS 文字最近文件' }
        @{ Path = "$base\et\RecentFiles";           Name = 'WPS 表格最近文件' }
        @{ Path = "$base\wpp\RecentFiles";          Name = 'WPS 演示最近文件' }
        @{ Path = "$base\pdf\RecentFiles";          Name = 'PDF 最近文件' }
        @{ Path = "$base\ofd\RecentFiles";          Name = 'OFD 最近文件' }
        @{ Path = "$base\et\RecentFunction";        Name = '表格最近使用的功能' }
        @{ Path = "$base\wps\RecentFonts";          Name = '最近使用的字体' }
        @{ Path = "$base\wps\BulletHistoryEx";      Name = '项目符号历史' }
        @{ Path = "$base\Common\CloudFileDialog\HistoryRecord"; Name = '云文件对话框历史' }
        @{ Path = "$base\Common\CloudFileDialog\PathMemoryInfo"; Name = '对话框路径记忆' }
        @{ Path = "$base\plugins\kstartpage";       Name = '开始页(推荐/最近列表)' }
        @{ Path = "$base\plugins\khyperion\filelist"; Name = '文件列表缓存' }
        @{ Path = "$base\plugins\khyperion\fileListNavTree"; Name = '文件导航树' }
        @{ Path = "$base\plugins\kitipsmanager";    Name = '提示弹窗记录' }
        @{ Path = "$base\plugins\ktipsmanager";     Name = '提示弹窗记录' }
        @{ Path = "$base\plugins\klearningtips";    Name = '新手引导记录' }
        @{ Path = "$base\plugins\kwpsupdateui";     Name = '更新提示记录' }
        @{ Path = "$base\plugins\kwpsshellextcheck"; Name = '右键菜单检查记录' }
        @{ Path = "$base\Common\StartupPerf";       Name = '启动耗时统计' }
        @{ Path = "$base\Common\ResourceManager";   Name = '资源预读时间记录' }
        @{ Path = "$base\plugins\officespace\usercenter\Sz520\openfilelist"; Name = '首页打开记录' }
        @{ Path = "$base\plugins\perfmon";          Name = '性能监控记录' }
        @{ Path = "$base\Common\extinfoc";          Name = '功能使用统计' }
    )
    $dir = @(
        @{ Path = (Join-Path $office6 'log');        Name = '运行日志' }
        @{ Path = (Join-Path $office6 'synccfg');    Name = '工作窗口布局记录' }
        @{ Path = (Join-Path $office6 'cache');      Name = '缓存' }
        @{ Path = (Join-Path $office6 'statusbarAppSeq'); Name = '状态栏应用顺序' }
        @{ Path = (Join-Path $office6 'skinitemsv3'); Name = '皮肤项记录' }
        @{ Path = (Join-Path $office6 'wpslearning'); Name = '学习引导记录' }
        @{ Path = (Join-Path $office6 'messagecenter'); Name = '消息中心记录' }
        @{ Path = (Join-Path $office6 'newdocs');    Name = '新建文档记录' }
        @{ Path = (Join-Path $office6 'layoutOrganizer'); Name = '界面布局记录' }
    )
    $regOut = @(); $dirOut = @()
    foreach ($r in $reg) {
        if (Test-Path -LiteralPath $r.Path) {
            $regOut += [PSCustomObject]@{ Type = 'reg'; Path = $r.Path; Name = $r.Name }
        }
    }
    foreach ($d in $dir) {
        if (Test-Path -LiteralPath $d.Path) {
            $dirOut += [PSCustomObject]@{ Type = 'dir'; Path = $d.Path; Name = $d.Name }
        }
    }
    return [PSCustomObject]@{ Reg = $regOut; Dir = $dirOut }
}

# ---------------------------------------------------------------- 缓存目标

function Get-CacheTargets {
    # 可清理的缓存目标。刻意不含:文档、模板、云盘缓存、配置、已装插件本体
    $targets = @()
    $office6 = Join-Path $env:APPDATA 'kingsoft\office6'
    $wpsAddons = Join-Path $env:APPDATA 'kingsoft\wps\addons'

    foreach ($n in @('cache', 'log')) {
        $p = Join-Path $office6 $n
        if (Test-Path -LiteralPath $p) {
            $targets += [PSCustomObject]@{ Path = $p; Name = "office6\$n"; Desc = '运行缓存/日志,自动重建' }
        }
    }

    $pool = Join-Path $wpsAddons 'pool\win-x64'
    if (Test-Path -LiteralPath $pool) {
        $groups = Get-ChildItem -LiteralPath $pool -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(.+)_(\d+\.\d+\.\d+\.\d+)$' } |
            ForEach-Object { [PSCustomObject]@{ Base = $matches[1]; Ver = $matches[2]; Item = $_ } } |
            Group-Object Base | Where-Object Count -gt 1
        foreach ($g in $groups) {
            $sorted = $g.Group | Sort-Object { try { [version]$_.Ver } catch { [version]'0.0.0' } } -Descending
            foreach ($old in ($sorted | Select-Object -Skip 1)) {
                $targets += [PSCustomObject]@{ Path = $old.Item.FullName; Name = "插件旧版 $($old.Item.Name)"; Desc = '被新版本取代' }
            }
        }
    }

    $curVer = $null
    try { $inst = Get-WpsInstall; if ($inst) { $curVer = $inst.Version } } catch { }
    $listV3 = Join-Path $wpsAddons 'listV3\win-x64'
    if (Test-Path -LiteralPath $listV3) {
        Get-ChildItem -LiteralPath $listV3 -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+(\.\d+){2,3}$' -and $_.Name -ne $curVer } |
            ForEach-Object {
                $targets += [PSCustomObject]@{ Path = $_.FullName; Name = "旧插件清单 $($_.Name)"; Desc = '旧版本清单' }
            }
    }

    $tmp = $env:TEMP
    if ($tmp -and (Test-Path -LiteralPath $tmp)) {
        Get-ChildItem -LiteralPath $tmp -Force -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(wps|kingsoft|kso|qing|kdoc|kprometheus)' } |
            ForEach-Object {
                $targets += [PSCustomObject]@{ Path = $_.FullName; Name = "临时目录 $($_.Name)"; Desc = 'WPS 临时残留' }
            }
    }

    foreach ($base in @($env:LOCALAPPDATA, $office6)) {
        if (-not $base) { continue }
        Get-ChildItem -LiteralPath $base -Recurse -Depth 2 -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(CrashDump|crash|dmp)$' } |
            ForEach-Object {
                $targets += [PSCustomObject]@{ Path = $_.FullName; Name = "崩溃转储 $($_.Name)"; Desc = '崩溃转储' }
            }
    }
    return $targets
}

# ---------------------------------------------------------------- 优化计划

function Get-OptimizePlan {
    # 返回优化项汇总(dry),供菜单确认;不打印明细
    $plan = [PSCustomObject]@{
        OldVersions = @(); StalePlugins = @(); OldLists = @()
        CacheMB = 0.0; LogMB = 0.0; WakeTasks = @(); SysMainFix = $false; PrefetchFix = $false
        CloudSvr = $null; CloudDisabled = $false; TotalMB = 0.0
    }
    $inst = Get-WpsInstall
    if (-not $inst) { return $plan }

    $plan.CloudSvr = Join-Path $inst.CurrentDir 'office6\wpscloudsvr.exe'
    $plan.CloudDisabled = Test-Path -LiteralPath "$($plan.CloudSvr).disabled"

    $plan.OldVersions = @(Get-ChildItem -LiteralPath $inst.Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+(\.\d+){2,3}$' -and $_.Name -ne $inst.Version })
    foreach ($d in $plan.OldVersions) { $plan.TotalMB += Get-DirSizeMB $d.FullName }

    $pool = Join-Path $env:APPDATA 'kingsoft\wps\addons\pool\win-x64'
    if (Test-Path -LiteralPath $pool) {
        $groups = Get-ChildItem -LiteralPath $pool -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(.+)_(\d+\.\d+\.\d+\.\d+)$' } |
            ForEach-Object { [PSCustomObject]@{ Base = $matches[1]; Ver = $matches[2]; Item = $_ } } |
            Group-Object Base | Where-Object Count -gt 1
        foreach ($g in $groups) {
            $sorted = $g.Group | Sort-Object { try { [version]$_.Ver } catch { [version]'0.0.0' } } -Descending
            foreach ($old in ($sorted | Select-Object -Skip 1)) {
                $plan.StalePlugins += $old.Item
                $plan.TotalMB += Get-DirSizeMB $old.Item.FullName
            }
        }
    }

    $listV3 = Join-Path $env:APPDATA 'kingsoft\wps\addons\listV3\win-x64'
    if (Test-Path -LiteralPath $listV3) {
        $plan.OldLists = @(Get-ChildItem -LiteralPath $listV3 -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+(\.\d+){2,3}$' -and $_.Name -ne $inst.Version })
    }

    $office6 = Join-Path $env:APPDATA 'kingsoft\office6'
    $plan.CacheMB = Get-DirSizeMB (Join-Path $office6 'cache')
    $plan.LogMB   = Get-DirSizeMB (Join-Path $office6 'log')
    $plan.TotalMB += $plan.CacheMB + $plan.LogMB

    $plan.WakeTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -match '^(WpsWakeWns|WpsWake)' -and $_.State -ne 'Disabled' })

    $sm = Get-Service SysMain -ErrorAction SilentlyContinue
    if ($sm -and $sm.StartType -eq 'Disabled') { $plan.SysMainFix = $true }
    $pfKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters'
    if (Test-Path $pfKey) {
        $pf = Get-ItemProperty $pfKey -ErrorAction SilentlyContinue
        if ($null -eq $pf.EnablePrefetch -or $null -eq $pf.EnableSuperfetch) { $plan.PrefetchFix = $true }
    }
    return $plan
}

# ---------------------------------------------------------------- 动作 1:体检诊断

function Invoke-Diagnose {
    Write-Head ("体检诊断 v{0}(只读)" -f $Script:Version)
    $inst = Get-WpsInstall
    if (-not $inst) {
        Write-Err2 '没有找到已安装的 WPS Office。'
        Write-Info '已尝试注册表 InstallRoot、卸载项与常见默认路径。'
        return
    }

    Write-Info ("版本     : {0}" -f $inst.Version)
    Write-Info ("目录     : {0}" -f $inst.CurrentDir)
    try {
        $d = Get-PathMediaType -Path $inst.Root
        if ($d) {
            Write-Info ("磁盘     : {0} / {1}" -f $d.Name, $d.MediaType)
            if ($d.MediaType -eq 'HDD') { Write-Warn2 'WPS 装在机械硬盘上,冷启动会明显慢;迁到 SSD 收益最大' }
        }
    } catch { }

    $procs = Get-WpsProcesses
    if ($procs) {
        $cloud = $procs | Where-Object { $_.ProcessName -eq 'wpscloudsvr' }
        Write-Info ("进程     : {0} 个 WPS 进程在运行" -f @($procs).Count)
        if ($cloud) { Write-Info ("           其中云服务 wpscloudsvr 占 {0:N0} MB" -f ($cloud.WorkingSet64 / 1MB)) }
    } else {
        Write-Info '进程     : 当前没有 WPS 进程在运行'
    }

    $svr = Join-Path $inst.CurrentDir 'office6\wpscloudsvr.exe'
    if (Test-Path -LiteralPath "$svr.disabled") {
        Write-Ok '云服务   : 已禁用(启动提速的主力项)'
    } elseif (Test-Path -LiteralPath $svr) {
        Write-Warn2 '云服务   : 启用中 ← 启动慢的主因(实测约占启动 CPU 一半)'
    } else {
        Write-Info '云服务   : 未找到 wpscloudsvr.exe(版本不同或已移除)'
    }

    $verDirs = @(Get-ChildItem -LiteralPath $inst.Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+(\.\d+){2,3}$' })
    if ($verDirs.Count -gt 1) {
        $oldMB = ($verDirs | Where-Object { $_.FullName.TrimEnd('\') -ne $inst.CurrentDir.TrimEnd('\') } |
                  ForEach-Object { Get-DirSizeMB $_.FullName } | Measure-Object -Sum).Sum
        Write-Warn2 ("旧版本   : {0} 个目录,约 {1:N0} MB 可清理" -f ($verDirs.Count - 1), $oldMB)
    } else {
        Write-Info '旧版本   : 无'
    }

    $plan = Get-OptimizePlan
    if ($plan.StalePlugins.Count -gt 0) {
        Write-Warn2 ("旧插件   : {0} 个被取代的旧版本可清理" -f $plan.StalePlugins.Count)
    } else {
        Write-Info '旧插件   : 无重复版本'
    }
    if ($plan.CacheMB -gt 0 -or $plan.LogMB -gt 0) {
        Write-Info ("缓存日志 : cache {0:N0} MB + log {1:N0} MB" -f $plan.CacheMB, $plan.LogMB)
    }
    if ($plan.WakeTasks.Count -gt 0) {
        Write-Warn2 ("计划任务 : {0} 个登录唤醒任务启用中({1})" -f $plan.WakeTasks.Count, (($plan.WakeTasks | ForEach-Object TaskName) -join ', '))
    } else {
        Write-Info '计划任务 : 无唤醒任务'
    }
    $sm = Get-Service SysMain -ErrorAction SilentlyContinue
    if ($sm) {
        if ($sm.StartType -eq 'Disabled') { Write-Warn2 'SysMain  : 被禁用 —— 拖慢程序二次启动' }
        else { Write-Info "SysMain  : 正常($($sm.StartType))" }
    }

    # 云盘缓存(易误解项):逻辑大小 vs 真实占用
    $cloudCfg = $null
    $common = Get-ItemProperty 'HKCU:\Software\Kingsoft\Office\6.0\Common' -ErrorAction SilentlyContinue
    if ($common -and $common.CurrentWpsCloudCachePath) { $cloudCfg = $common.CurrentWpsCloudCachePath }
    if ($cloudCfg -and (Test-Path -LiteralPath $cloudCfg)) {
        Write-Info ('正在统计云盘缓存(一遍遍历,几秒到几十秒)...')
        $st = Get-DirStats -Path $cloudCfg
        Write-Info ("云盘缓存 : {0}" -f $cloudCfg)
        if ($null -ne $st.RealMB) {
            Write-Info ("           逻辑 {0:N0} MB / 真实占用 {1:N0} MB / {2} 个文件" -f $st.LogicalMB, $st.RealMB, $st.Count)
            if ($st.LogicalMB -gt 0 -and $st.RealMB -lt $st.LogicalMB * 0.2) {
                Write-Info '           绝大部分是「按需下载」占位文件 —— 看着大,几乎不占盘'
            }
        } else {
            Write-Info ("           逻辑 {0:N0} MB({1} 个文件;多为占位文件,真实占用很小)" -f $st.LogicalMB, $st.Count)
        }
        Write-Warn2 '           此目录绝不能当垃圾删 —— 删了等于丢掉整个云盘入口'
    }

    $fl = Get-ForceLoginState
    if (-not $fl.Exists) {
        Write-Info '强制登录 : flogin 键不存在(WPS 可能尚未首次运行)'
    } elseif ($fl.First -eq 'false' -and $fl.Has -eq 'false') {
        Write-Ok '强制登录 : 已关闭(未登录也能用基础功能)'
    } else {
        Write-Warn2 '强制登录 : 开启中 —— 未登录时功能区会整体变灰'
    }

    $pt = Get-ProfileRecordTargets
    $dirMB = 0.0
    foreach ($x in $pt.Dir) { $dirMB += Get-DirSizeMB $x.Path }
    Write-Info ("使用记录 : 注册表 {0} 处 + 目录 {1} 个,约 {2:N0} MB" -f $pt.Reg.Count, $pt.Dir.Count, $dirMB)

    if (Test-Admin) { Write-Info '权限     : 管理员(可执行全部动作)' }
    else { Write-Warn2 '权限     : 非管理员 —— 计划任务/服务/Program Files 相关动作会失败' }

    Write-Host ''
    Write-Info '建议:菜单 [2] 一键优化(收益最大是连云服务一起禁用)。'
}

# ---------------------------------------------------------------- 动作 2:一键优化

function Invoke-Optimize {
    param([bool]$WithCloud)
    $Script:FreedMB = 0.0
    $plan = Get-OptimizePlan

    Write-Head ("一键优化(云服务: {0})" -f $(if ($WithCloud) { '禁用' } else { '保留' }))

    # 0) 关进程
    if (Get-WpsProcesses) {
        if (Close-Wps) { Write-Ok '已关闭全部 WPS 进程' }
        else { Write-Warn2 '部分进程未能关闭,占用文件将被跳过' }
    }

    # 1) 云服务
    if ($plan.CloudDisabled) {
        Write-Ok '云服务已是禁用状态,跳过'
    } elseif (-not (Test-Path -LiteralPath $plan.CloudSvr)) {
        Write-Info '未找到 wpscloudsvr.exe,跳过'
    } elseif ($WithCloud) {
        Write-Plan '禁用云服务 wpscloudsvr.exe(改名 .disabled,可随时还原)'
        try {
            Get-Process wpscloudsvr -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $plan.CloudSvr -Destination "$($plan.CloudSvr).disabled" -Force -ErrorAction Stop
            Write-Ok '云服务已禁用'
            Add-Action -Entry @{ id = 'cloud-svr'; before = $plan.CloudSvr; after = "$($plan.CloudSvr).disabled" }
        } catch {
            Write-Err2 ("禁用失败: {0}(权限不足时请以管理员重跑)" -f $_.Exception.Message)
        }
    } else {
        Write-Info '云服务保留(未勾选禁用)'
    }

    # 2) 旧版本目录
    foreach ($d in $plan.OldVersions) {
        $mb = Get-DirSizeMB $d.FullName
        $inUse = (Get-WpsProcesses | Where-Object { $_.Path -like "$($d.FullName)*" }).Count -gt 0
        if ($inUse) { Write-Warn2 "旧版本 $($d.Name) 有进程占用,跳过"; continue }
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $d.FullName) {
            Write-Err2 "旧版本 $($d.Name) 删除未完成(文件被占用)"
        } else {
            Write-Ok ("已删除旧版本目录 {0}({1:N0} MB)" -f $d.Name, $mb)
            $Script:FreedMB += $mb
            Add-Action -Entry @{ id = 'old-version'; path = $d.FullName; mb = $mb }
        }
    }
    if ($plan.OldVersions.Count -eq 0) { Write-Info '旧版本目录:无' }

    # 3) 旧插件
    $fail = 0
    foreach ($s in $plan.StalePlugins) {
        Remove-Item -LiteralPath $s.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $s.FullName) { $fail++ }
    }
    if ($plan.StalePlugins.Count -gt 0) {
        if ($fail -eq 0) {
            Write-Ok ("已清理 {0} 个旧插件" -f $plan.StalePlugins.Count)
            Add-Action -Entry @{ id = 'stale-plugins'; count = $plan.StalePlugins.Count }
        } else {
            Write-Warn2 ("旧插件清理 {0} 个成功,{1} 个被占用跳过" -f ($plan.StalePlugins.Count - $fail), $fail)
        }
    } else {
        Write-Info '旧插件:无'
    }

    # 4) 旧插件清单
    foreach ($l in $plan.OldLists) {
        Remove-Item -LiteralPath $l.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $l.FullName)) { Write-Ok ("已删除旧插件清单 {0}" -f $l.Name) }
        else { Write-Err2 "旧插件清单 $($l.Name) 删除失败" }
    }
    if ($plan.OldLists.Count -eq 0) { Write-Info '旧插件清单:无' }

    # 5) 缓存与日志
    $office6 = Join-Path $env:APPDATA 'kingsoft\office6'
    foreach ($pair in @(@('cache', $plan.CacheMB), @('log', $plan.LogMB))) {
        $dir = Join-Path $office6 $pair[0]
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok ("清空 office6\{0}({1:N0} MB)" -f $pair[0], $pair[1])
        $Script:FreedMB += $pair[1]
        Add-Action -Entry @{ id = "clear-$($pair[0])"; path = $dir; mb = $pair[1] }
    }

    # 6) 计划任务
    foreach ($t in $plan.WakeTasks) {
        try {
            Disable-ScheduledTask -TaskName $t.TaskName -ErrorAction Stop | Out-Null
            Write-Ok ("已禁用计划任务 {0}" -f $t.TaskName)
            Add-Action -Entry @{ id = 'task'; name = $t.TaskName }
        } catch {
            Write-Err2 ("禁用 {0} 失败(需管理员)" -f $t.TaskName)
        }
    }
    if ($plan.WakeTasks.Count -eq 0) { Write-Info '计划任务:无唤醒任务' }

    # 7) SysMain 与预读
    if ($plan.SysMainFix) {
        try {
            Set-Service SysMain -StartupType Automatic -ErrorAction Stop
            Start-Service SysMain -ErrorAction Stop
            Write-Ok 'SysMain 已恢复为自动并启动'
            Add-Action -Entry @{ id = 'sysmain'; before = 'Disabled'; after = 'Automatic' }
        } catch { Write-Err2 ("SysMain 修改失败(需管理员): {0}" -f $_.Exception.Message) }
    } else {
        Write-Info 'SysMain:正常,无需处理'
    }
    if ($plan.PrefetchFix) {
        try {
            $pfKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters'
            Set-ItemProperty -Path $pfKey -Name EnablePrefetch -Value 3 -Type DWord -Force -ErrorAction Stop
            Set-ItemProperty -Path $pfKey -Name EnableSuperfetch -Value 3 -Type DWord -Force -ErrorAction Stop
            Write-Ok '预读参数已补写(EnablePrefetch/Superfetch=3)'
        } catch { Write-Err2 '预读参数写入失败(需管理员)' }
    }

    Write-Host ''
    if ($Script:FreedMB -gt 0) { Write-Ok ("本次释放约 {0:N0} MB" -f $Script:FreedMB) }
    Write-Info '重新打开 WPS 生效。撤销:菜单 [3]。'
}

# ---------------------------------------------------------------- 动作 3:撤销优化

function Invoke-Restore {
    Write-Head '撤销优化(还原可逆项)'
    $restored = $false
    $inst = Get-WpsInstall

    if ($inst) {
        $svr = Join-Path $inst.CurrentDir 'office6\wpscloudsvr.exe'
        if (Test-Path -LiteralPath "$svr.disabled") {
            Get-Process wpscloudsvr -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath "$svr.disabled" -Destination $svr -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $svr) { Write-Ok '云服务 wpscloudsvr.exe 已还原'; $restored = $true }
            else { Write-Err2 '云服务还原失败,请以管理员重跑' }
        } else {
            Write-Info '云服务:没有需要还原的改动'
        }
    } else {
        Write-Warn2 '没找到 WPS 安装,无法还原云服务'
    }

    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -match '^Wps' -and $_.State -eq 'Disabled' })
    foreach ($t in $tasks) {
        try {
            Enable-ScheduledTask -TaskName $t.TaskName -ErrorAction Stop | Out-Null
            Write-Ok ("已启用计划任务 {0}" -f $t.TaskName)
        } catch { Write-Err2 ("启用 {0} 失败(需管理员)" -f $t.TaskName) }
    }
    if ($tasks.Count -eq 0) { Write-Info '计划任务:没有已禁用的 WPS 任务' }

    Write-Info '已删除的旧版本/旧插件/缓存无法还原 —— 它们只是冗余数据,不影响功能。'
}

# ---------------------------------------------------------------- 动作 4:清理缓存

function Invoke-CleanCache {
    Write-Head '清理缓存'
    $Script:FreedMB = 0.0
    $targets = @(Get-CacheTargets | Where-Object { -not (Test-ProtectedPath $_.Path) })
    if ($targets.Count -eq 0) {
        Write-Ok '没有可清理的缓存'
        return
    }
    foreach ($t in $targets) {
        $mb = Get-DirSizeMB $t.Path
        if ($mb -le 0) { continue }
        Get-ChildItem -LiteralPath $t.Path -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $t.Path) {
            $left = @(Get-ChildItem -LiteralPath $t.Path -Recurse -File -Force -ErrorAction SilentlyContinue).Count
            if ($left -gt 0) { Write-Warn2 ("{0} 有 {1} 个文件被占用,已跳过" -f $t.Name, $left); continue }
            Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Ok ("已清理 {0}({1:N0} MB)" -f $t.Name, $mb)
        $Script:FreedMB += $mb
    }
    Write-Host ''
    if ($Script:FreedMB -gt 0) { Write-Ok ("本次清理约 {0:N0} MB" -f $Script:FreedMB) }
    Write-Info '刻意不动:文档、模板、云盘缓存、配置、已装插件。'
}

# ---------------------------------------------------------------- 动作 5:免登录

function Invoke-NoLogin {
    Write-Head '免登录(未登录可用基础功能)'
    $fl = Get-ForceLoginState
    if (-not $fl.Exists) {
        Write-Info 'flogin 键不存在(WPS 可能尚未首次运行)。直接写入关闭值即可。'
    } else {
        $f = if ($null -eq $fl.First) { '(未设置)' } else { $fl.First }
        $h = if ($null -eq $fl.Has)  { '(未设置)' } else { $fl.Has }
        Write-Info ("首装设备强制登录: {0}" -f $f)
        Write-Info ("已装设备强制登录: {0}" -f $h)
    }
    Write-Host ''
    Write-Info '  [1] 关闭强制登录(未登录可用编辑/格式刷/粘贴/求和等)'
    Write-Info '  [2] 恢复强制登录(改回默认)'
    Write-Info '  [0] 取消'
    $c = Read-Host '  选择'
    if ($c -eq '1') {
        if (Set-ForceLogin -Off $true) {
            Write-Ok '已关闭强制登录'
            Write-Info '完全退出 WPS(含托盘)再打开才会生效。AI 与云文档仍需登录。'
            Write-Info '若功能区仍灰:配置和修复工具 → 高级 → 其他选项 → 勾选「兼容离线状态下的未登录使用方式」'
        }
    } elseif ($c -eq '2') {
        if (Set-ForceLogin -Off $false) { Write-Ok '已恢复强制登录(默认)' }
    } else {
        Write-Info '已取消'
    }
}

# ---------------------------------------------------------------- 动作 6/7:重置与还原使用记录

function Backup-Profile {
    param($Targets, [string]$BackupRoot)
    $manifest = @()
    $i = 0
    foreach ($r in $Targets.Reg) {
        $i++
        $name = ($r.Path -replace '[\\/:*?"<>|]', '_')
        $file = Join-Path $BackupRoot ("reg-{0:d2}-{1}.reg" -f $i, $name)
        & reg.exe export $r.Path.Replace('HKCU:', 'HKCU') $file /y 2>&1 | Out-Null
        if (Test-Path -LiteralPath $file) {
            $manifest += [ordered]@{ type = 'reg'; path = $r.Path; backup = (Split-Path $file -Leaf); name = $r.Name }
        }
    }
    foreach ($d in $Targets.Dir) {
        $i++
        $name = ($d.Path -replace '[\\/:*?"<>|]', '_').TrimStart('_')
        $dest = Join-Path $BackupRoot ("dir-{0:d2}-{1}" -f $i, $name)
        try { Copy-Item -LiteralPath $d.Path -Destination $dest -Recurse -Force -ErrorAction Stop } catch { }
        $manifest += [ordered]@{ type = 'dir'; path = $d.Path; backup = (Split-Path $dest -Leaf); name = $d.Name }
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $BackupRoot 'manifest.json') -Encoding UTF8
    return $manifest.Count
}

function Invoke-ResetProfile {
    Write-Head '重置使用记录(回到刚安装状态)'
    $t = Get-ProfileRecordTargets
    if ($t.Reg.Count -eq 0 -and $t.Dir.Count -eq 0) {
        Write-Ok '没有发现使用记录'
        return
    }
    $dirMB = 0.0
    foreach ($d in $t.Dir) { $dirMB += Get-DirSizeMB $d.Path }
    Write-Info ("将清除:注册表 {0} 处 + 目录 {1} 个,约 {2:N0} MB" -f $t.Reg.Count, $t.Dir.Count, $dirMB)
    Write-Info '保留  : 文档、模板、云同步/登录、文件关联、界面偏好、已装插件。'
    Write-Info '备份  : 清除前自动备份到 backups\,可随时用 [7] 还原。'
    $c = Read-Host '  确认执行?将关闭 WPS 进程 (y/N)'
    if ($c -notmatch '^[yY]') { Write-Info '已取消'; return }

    if (Get-WpsProcesses) {
        if (Close-Wps) { Write-Ok '已关闭 WPS' }
        else { Write-Err2 '未能关闭 WPS,请手动退出后重试'; return }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupRoot = Join-Path $Script:BackupDir "profile-$stamp"
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $n = Backup-Profile -Targets $t -BackupRoot $backupRoot
    Write-Ok ("已备份 {0} 项 → {1}" -f $n, $backupRoot)

    $okR = 0; $failR = 0
    foreach ($r in $t.Reg) {
        if (Test-ProtectedPath $r.Path) { Write-Warn2 "$($r.Name) 受保护,跳过"; continue }
        try {
            Remove-Item -LiteralPath $r.Path -Recurse -Force -ErrorAction Stop
            $okR++
        } catch { $failR++ }
    }
    Write-Ok ("注册表记录:清除 {0} 项,失败 {1} 项" -f $okR, $failR)

    $okD = 0; $failD = 0
    foreach ($d in $t.Dir) {
        if (Test-ProtectedPath $d.Path) { Write-Warn2 "$($d.Name) 受保护,跳过"; continue }
        # 逐项尽力清空(SilentlyContinue):个别文件被占用时不清空其余内容
        Get-ChildItem -LiteralPath $d.Path -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $okD++
    }
    Write-Ok ("记录目录:清空 {0} 项" -f $okD)
    Write-Info '重新打开 WPS,即回到接近「刚安装」的状态。'
}

function Invoke-RestoreProfile {
    Write-Head '还原使用记录'
    if (-not (Test-Path -LiteralPath $Script:BackupDir)) {
        Write-Err2 '没有备份目录,无法还原。'
        return
    }
    $latest = Get-ChildItem -LiteralPath $Script:BackupDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'profile-*' } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) {
        Write-Err2 '备份目录里没有 profile-* 记录。'
        return
    }
    $manifestPath = Join-Path $latest.FullName 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Write-Err2 "备份缺少 manifest.json: $($latest.Name)"
        return
    }
    Write-Info ("使用备份: {0}" -f $latest.Name)
    $c = Read-Host '  确认还原?将关闭 WPS 进程 (y/N)'
    if ($c -notmatch '^[yY]') { Write-Info '已取消'; return }

    if (Get-WpsProcesses) {
        if (Close-Wps) { Write-Ok '已关闭 WPS' }
        else { Write-Err2 '未能关闭 WPS,已中止'; return }
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ok = 0; $fail = 0
    foreach ($m in $manifest) {
        if ($m.type -eq 'reg') {
            $file = Join-Path $latest.FullName $m.backup
            if (-not (Test-Path -LiteralPath $file)) { $fail++; continue }
            & reg.exe import $file 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail++; Write-Warn2 "导入失败: $($m.name)" }
        } else {
            $src = Join-Path $latest.FullName $m.backup
            if (-not (Test-Path -LiteralPath $src)) { $fail++; continue }
            try {
                New-Item -ItemType Directory -Path $m.path -Force -ErrorAction SilentlyContinue | Out-Null
                # 注意必须用 -Path(通配符语义):-LiteralPath 配 "*" 在 PS 5.1 会静默不复制
                Copy-Item -Path (Join-Path $src '*') -Destination $m.path -Recurse -Force -ErrorAction Stop
                $ok++
            } catch { $fail++; Write-Warn2 "复制失败: $($m.name)" }
        }
    }
    Write-Ok ("还原完成:成功 {0} 项,失败 {1} 项" -f $ok, $fail)
    Write-Info '重新打开 WPS 即可看到恢复的记录。'
}

# ---------------------------------------------------------------- 菜单

function Show-Menu {
    Write-Host ''
    Write-Host $Script:Bar -ForegroundColor Cyan
    $admin = if (Test-Admin) { '管理员' } else { '受限' }
    Write-Host ("  WPS 优化工具 v{0}   [{1}]   {2}" -f $Script:Version, $admin, $Script:Root) -ForegroundColor White
    Write-Host $Script:Bar -ForegroundColor Cyan

    $inst = Get-WpsInstall
    if ($inst) {
        $svr = Join-Path $inst.CurrentDir 'office6\wpscloudsvr.exe'
        $cloud = if (Test-Path -LiteralPath "$svr.disabled") { '已禁用' }
                 elseif (Test-Path -LiteralPath $svr) { '启用中' }
                 else { '未找到' }
        Write-Host ("  WPS {0}   云服务: {1}" -f $inst.Version, $cloud) -ForegroundColor Gray
    } else {
        Write-Host '  未检测到 WPS Office' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  [1] 体检诊断    只读,看占用与隐患' -ForegroundColor White
    Write-Host '  [2] 一键优化    清旧版本/旧插件/缓存日志,收敛后台' -ForegroundColor White
    Write-Host '  [3] 撤销优化    恢复云服务与计划任务' -ForegroundColor White
    Write-Host '  [4] 清理缓存    日志/临时残留/崩溃转储(不碰文档)' -ForegroundColor White
    Write-Host '  [5] 免登录      未登录也能用基础功能(可恢复)' -ForegroundColor White
    Write-Host '  [6] 重置记录    清最近文件/历史,回到刚安装(自动备份)' -ForegroundColor White
    Write-Host '  [7] 还原记录    从最近一次备份恢复使用记录' -ForegroundColor White
    Write-Host '  [0] 退出' -ForegroundColor DarkGray
    Write-Host ''
}

function Confirm-Run {
    param([string]$Message)
    $c = Read-Host ("  {0} (y/N)" -f $Message)
    return ($c -match '^[yY]')
}

function Main {
    try {
        while ($true) {
            Show-Menu
            $choice = Read-Host '  选择'
            switch ($choice) {
                '1' { Invoke-Diagnose; Pause-Menu }
                '2' {
                    $inst = Get-WpsInstall
                    if (-not $inst) { Write-Err2 '没有找到 WPS,无法优化'; Pause-Menu; continue }
                    Write-Host ''
                    Write-Info '云服务禁用是收益最大的一项(实测约砍一半启动 CPU),'
                    Write-Info '代价是云文档无法在客户端内直接打开,本地文档不受影响。'
                    $withCloud = (Read-Host '  包含云服务禁用? (y/N)') -match '^[yY]'
                    $plan = Get-OptimizePlan
                    Write-Host ''
                    $summary = "计划: 旧版本 {0} 个 / 旧插件 {1} 个 / 缓存日志 {2:N0} MB / 唤醒任务 {3} 个" -f $plan.OldVersions.Count, $plan.StalePlugins.Count, ($plan.CacheMB + $plan.LogMB), $plan.WakeTasks.Count
                    Write-Info $summary
                    if ($withCloud -and -not $plan.CloudDisabled -and (Test-Path -LiteralPath $plan.CloudSvr)) {
                        Write-Info '      + 禁用云服务 wpscloudsvr.exe'
                    }
                    if (Confirm-Run '执行以上优化?将关闭 WPS,未保存文档会丢失') {
                        Invoke-Optimize -WithCloud $withCloud
                    } else { Write-Info '已取消' }
                    Pause-Menu
                }
                '3' { Invoke-Restore; Pause-Menu }
                '4' {
                    $targets = @(Get-CacheTargets | Where-Object { -not (Test-ProtectedPath $_.Path) })
                    $total = 0.0
                    foreach ($t in $targets) { $total += Get-DirSizeMB $t.Path }
                    if ($targets.Count -eq 0 -or $total -le 0) {
                        Write-Host ''; Write-Ok '没有可清理的缓存'; Pause-Menu; continue
                    }
                    Write-Host ''
                    Write-Info ("将清理 {0} 项,约 {1:N0} MB(文档/模板/云盘缓存/配置一律不动)" -f $targets.Count, $total)
                    if (Confirm-Run '执行清理?将关闭 WPS,未保存文档会丢失') {
                        $Script:FreedMB = 0.0
                        Invoke-CleanCache
                    } else { Write-Info '已取消' }
                    Pause-Menu
                }
                '5' { Invoke-NoLogin; Pause-Menu }
                '6' { Invoke-ResetProfile; Pause-Menu }
                '7' { Invoke-RestoreProfile; Pause-Menu }
                '0' { return }
                default { }
            }
        }
    } catch {
        Write-Host ''
        Write-Err2 ("发生异常: {0}" -f $_.Exception.Message)
        Write-Info $_.ScriptStackTrace
        $null = Read-Host '  按回车退出'
        exit 1
    }
}

Main
rem #PS-END
