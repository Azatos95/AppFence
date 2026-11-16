# uninstall-app.ps1 - 扫描已安装应用 + 彻底卸载（Geek 风格）
# 用法:
#   .\uninstall-app.ps1 -Action scan
#   .\uninstall-app.ps1 -Action uninstall -Name 'App DisplayName' [-Purge]
# 注意: 卸载前自动导出注册表键备份到 out\app-backup\
param(
    [ValidateSet('scan', 'uninstall', 'backups')][string]$Action = 'scan',
    [string]$Name,
    [switch]$Purge
)

. "$PSScriptRoot\wdac-common.ps1"
Assert-WdacAdmin
Initialize-WdacDirs

$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)

if ($Action -eq 'scan') {
    $apps = @()
    foreach ($base in $uninstallKeys) {
        $items = Get-ChildItem $base -ErrorAction SilentlyContinue
        foreach ($it in $items) {
            $p = Get-ItemProperty $it.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.DisplayName) { continue }
            $apps += [pscustomobject]@{
                Name                = [string]$p.DisplayName
                Version             = [string]$p.DisplayVersion
                Publisher           = [string]$p.Publisher
                InstallLocation     = [string]$p.InstallLocation
                InstallDate         = [string]$p.InstallDate
                UninstallString     = [string]$p.UninstallString
                QuietUninstallString = [string]$p.QuietUninstallString
                KeyPath             = $it.PSPath
            }
        }
    }
    $apps = @($apps | Sort-Object Name -Unique)
    $result = [pscustomobject]@{ Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Count = $apps.Count; Apps = $apps }
    $result | ConvertTo-Json -Depth 4 | Out-File (Join-Path $OutDir 'apps.json') -Encoding UTF8
    Write-WdacLog "应用扫描: $($apps.Count) 个"
} elseif ($Action -eq 'uninstall') {
    if (-not $Name) { throw '需要 Name（应用显示名称）' }

    # 1. 定位
    $target = $null
    foreach ($base in $uninstallKeys) {
        foreach ($it in (Get-ChildItem $base -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $it.PSPath -ErrorAction SilentlyContinue
            if ($p -and [string]$p.DisplayName -eq $Name) {
                $target = [pscustomobject]@{
                    PSPath = $it.PSPath
                    DisplayName = [string]$p.DisplayName
                    UninstallString = [string]$p.UninstallString
                    QuietUninstallString = [string]$p.QuietUninstallString
                    InstallLocation = [string]$p.InstallLocation
                    Publisher = [string]$p.Publisher
                }
                break
            }
        }
        if ($target) { break }
    }
    if (-not $target) { throw "未找到应用: $Name" }

    # 2. 备份注册表键
    $backupDir = Join-Path $OutDir 'app-backup'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bkDir = Join-Path $backupDir $stamp
    New-Item -ItemType Directory -Force $bkDir | Out-Null
    $regPath = $target.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^HKEY_LOCAL_MACHINE', 'HKLM' -replace '^HKEY_CURRENT_USER', 'HKCU'
    $regFile = Join-Path $bkDir 'app.reg'
    & reg.exe export $regPath $regFile /y 2>$null | Out-Null
    [pscustomobject]@{ Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Name = $target.DisplayName; Publisher = $target.Publisher; InstallLocation = $target.InstallLocation; RegBackup = $regFile } |
        ConvertTo-Json -Depth 3 | Out-File (Join-Path $bkDir 'manifest.json') -Encoding UTF8
    Write-WdacLog "已备份注册表: $regFile"

    # 3. 执行卸载（静默优先）
    $cmd = $null
    if ($target.QuietUninstallString) { $cmd = $target.QuietUninstallString }
    elseif ($target.UninstallString) {
        $cmd = $target.UninstallString
        # MSI 卸载加静默参数
        if ($cmd -match 'msiexec') {
            if ($cmd -notmatch '/qn') { $cmd = $cmd + ' /qn' }
        }
    }
    if (-not $cmd) { throw "该应用没有卸载命令（可能不可卸载）" }

    Write-WdacLog "执行卸载: $cmd"
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ' + $cmd) -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
    if ($proc) { $proc.WaitForExit(300000) } else { Write-WdacLog '卸载命令启动失败' }

    # 4. 清理（卸载后仍然存在的注册表键）
    Start-Sleep -Seconds 2
    if (Test-Path $target.PSPath) {
        Remove-Item $target.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-WdacLog "已清理残留注册表键: $($target.DisplayName)"
    }

    # 5. 彻底删除残留目录（需 -Purge 且 UI 已二次确认）
    if ($Purge -and $target.InstallLocation -and (Test-Path $target.InstallLocation)) {
        Remove-Item $target.InstallLocation -Recurse -Force -ErrorAction SilentlyContinue
        Write-WdacLog "已删除残留目录: $($target.InstallLocation)"
    }

    Write-WdacLog "卸载完成: $($target.DisplayName)（备份: $bkDir）"
} elseif ($Action -eq 'backups') {
    $list = @()
    $backupDir = Join-Path $OutDir 'app-backup'
    Get-ChildItem $backupDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $mf = Join-Path $_.FullName 'manifest.json'
        if (Test-Path $mf) {
            try { $list += (Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
        }
    }
    ConvertTo-Json -InputObject @($list | Sort-Object Time -Descending) -Depth 3 | Out-File (Join-Path $OutDir 'app-backups.json') -Encoding UTF8
    Write-WdacLog "应用备份: $($list.Count) 条"
}
