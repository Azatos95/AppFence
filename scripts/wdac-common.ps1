# wdac-common.ps1 - 公共函数库
# 用法: . .\wdac-common.ps1

$script:Root = 'C:\wdac-platform'
$script:LogDir = Join-Path $script:Root 'logs'
$script:OutDir = Join-Path $script:Root 'out'
$script:StateDir = Join-Path $script:Root 'state'
$script:BackupDir = Join-Path $script:Root 'backup'

function Initialize-WdacDirs {
    foreach ($d in $LogDir, $OutDir, $StateDir, $BackupDir) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
    }
}

function Write-WdacLog {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    Initialize-WdacDirs
    $line = ('[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    Write-Host $line
    Add-Content -Path (Join-Path $LogDir 'wdac.log') -Value $line -Encoding UTF8
}

function Assert-WdacAdmin {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw '需要管理员权限运行（请以管理员身份启动 PowerShell）'
    }
}

function Get-WdacCIStatus {
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    $state = switch ($dg.CodeIntegrityPolicyEnforcementStatus) {
        0 { 'Off' }
        1 { 'Audit' }
        2 { 'Enforced' }
        default { "Unknown($($dg.CodeIntegrityPolicyEnforcementStatus))" }
    }
    [pscustomobject]@{
        Raw    = $dg.CodeIntegrityPolicyEnforcementStatus
        State  = $state
        Policy = (Test-Path 'C:\Windows\System32\CodeIntegrity\SIPolicy.p7b')
    }
}

function Get-WdacCIEvents {
    # 读取 CodeIntegrity 事件，返回结构化对象
    param([int]$MaxEvents = 500, [int[]]$Ids = @(3033, 3076, 3077, 3089))
    $events = Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents $MaxEvents -ErrorAction SilentlyContinue
    if (-not $events) { return @() }
    $result = @()
    foreach ($e in $events) {
        if ($e.Id -notin $Ids) { continue }
        $msg = $e.Message
        # 优先提取「attempted to load」后面的被加载文件（真正需要放行的目标，路径可能含空格）
        $paths = @()
        $loadMatch = [regex]::Match($msg, 'attempted to load\s+(\\Device\\HarddiskVolume\d+\\[^\r\n"]+?)\s+that did not meet')
        if (-not $loadMatch.Success) {
            $loadMatch = [regex]::Match($msg, 'attempted to load\s+(\\Device\\HarddiskVolume\d+\\[^\r\n"]+?)(?="\s*[\.\)]?\s*$)')
        }
        if ($loadMatch.Success) {
            $rel = $loadMatch.Groups[1].Value -replace '^\\Device\\HarddiskVolume\d+\\', ''
            $rel = $rel.TrimEnd(')', ']', ',', '.', '"')
            $paths += "C:\$rel"
        } else {
            foreach ($m in [regex]::Matches($msg, '\\Device\\HarddiskVolume\d+\\([^\r\n"]+)')) {
                $rel = $m.Groups[1].Value -replace '/', '\'
                $rel = $rel.TrimEnd(')', ']', ',', '.', '"')
                $paths += "C:\$rel"
            }
        }
        foreach ($p in ($paths | Select-Object -Unique)) {
            $result += [pscustomobject]@{
                Id        = $e.Id
                Time      = $e.TimeCreated
                FilePath  = $p
                Message   = ($msg -replace "\r?\n", ' ')
            }
        }
    }
    return $result
}

function ConvertTo-WdacSafeXml {
    # 转义 XML 特殊字符
    param([string]$Text)
    return [System.Security.SecurityElement]::Escape($Text)
}

function Get-WdacInventory {
    # 读取已安装软件清单
    $f = Join-Path $OutDir 'inventory.json'
    if (-not (Test-Path $f)) { return @() }
    try {
        $d = ConvertFrom-Json -InputObject (Get-Content $f -Raw -Encoding UTF8)
        return @($d.Apps)
    } catch { return @() }
}

function Resolve-WdacApp {
    # 把文件路径映射到已安装软件（用于"哪个软件在悄悄运行"）
    param([string]$FilePath)
    if (-not $FilePath) { return $null }
    $inv = Get-WdacInventory
    if ($inv.Count -eq 0) { return $null }

    # 1. InstallLocation 前缀匹配（最长安装路径优先）
    $best = $null
    foreach ($a in $inv) {
        if ($a.InstallLocation -and $a.InstallLocation.Length -gt 3) {
            $loc = $a.InstallLocation.TrimEnd('\') + '\'
            if ($FilePath.StartsWith($loc, [System.StringComparison]::OrdinalIgnoreCase)) {
                if (-not $best -or $a.InstallLocation.Length -gt $best.InstallLocation.Length) { $best = $a }
            }
        }
    }
    if ($best) { return $best }

    # 2. 回退：Program Files 下第一级目录名与软件名匹配
    $m = [regex]::Match($FilePath, '^[A-Z]:\\Program Files(?: \(x86\))?\\([^\\]+)\\')
    if ($m.Success) {
        $folder = $m.Groups[1].Value.ToLower()
        foreach ($a in $inv) {
            if ($a.Name -and $a.Name.ToLower().Contains($folder)) { return $a }
            if ($a.Publisher -and $a.Publisher.ToLower().Contains($folder)) { return $a }
        }
    }
    return $null
}
