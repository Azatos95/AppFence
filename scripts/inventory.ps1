# inventory.ps1 - 扫描已安装软件清单（零依赖）
# 数据源：注册表 Uninstall 键（HKLM 64/32 + HKCU）+ 可选 Appx
. "$PSScriptRoot\wdac-common.ps1"
Initialize-WdacDirs

$apps = @()
$seen = @{}

function Add-App([string]$Name, [string]$Version, [string]$Publisher, [string]$Location, [string]$Source) {
    if (-not $Name) { return }
    $key = ($Name + '|' + $Version).ToLower()
    if ($seen.ContainsKey($key)) { return }
    $seen[$key] = $true
    $script:apps += [pscustomobject]@{
        Name            = $Name
        Version         = $Version
        Publisher       = $Publisher
        InstallLocation = $Location
        Source          = $Source
    }
}

# 1. 注册表 Uninstall（64 位、32 位、当前用户）
$regKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
foreach ($k in $regKeys) {
    $items = Get-ItemProperty $k -ErrorAction SilentlyContinue
    foreach ($item in $items) {
        if (-not $item.DisplayName) { continue }
        $loc = $item.InstallLocation
        if (-not $loc) { $loc = $null }
        Add-App $item.DisplayName $item.DisplayVersion $item.Publisher $loc 'registry'
    }
}

# 2. Store 应用（Appx，可选，失败忽略）
try {
    $appx = Get-AppxPackage -ErrorAction SilentlyContinue
    foreach ($a in $appx) {
        Add-App ($a.Name) ($a.Version) ($a.PublisherDisplayName) ($a.InstallLocation) 'appx'
    }
} catch { }

# 3. 去重排序并保存
$apps = @($apps | Sort-Object Name -Unique)
$result = [pscustomobject]@{
    Time  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Count = $apps.Count
    Apps  = $apps
}
$result | ConvertTo-Json -Depth 4 | Out-File (Join-Path $OutDir 'inventory.json') -Encoding UTF8
Write-WdacLog "软件清单: $($apps.Count) 个已安装软件"
