# uninstall.ps1 - 完整卸载
param(
    [string]$Root = 'C:\wdac-platform',
    [switch]$KeepPolicy
)

. "$PSScriptRoot\wdac-common.ps1" -ErrorAction SilentlyContinue

Write-Host '=== WDAC Platform 卸载 ===' -ForegroundColor Cyan

# 1. 停止并删除服务
Write-Host '[1/3] 停止并删除服务...'
sc.exe stop WdacAgent 2>$null | Out-Null
Start-Sleep -Seconds 2
sc.exe delete WdacAgent 2>$null | Out-Null

# 2. 移除策略（除非指定保留）
Write-Host '[2/3] 移除代码完整性策略...'
if (-not $KeepPolicy) {
    Remove-Item 'C:\Windows\System32\CodeIntegrity\SIPolicy.p7b' -Force -ErrorAction SilentlyContinue
    $active = 'C:\Windows\System32\CodeIntegrity\CiPolicies\Active'
    if (Test-Path $active) {
        Get-ChildItem $active -Filter '*.cip' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Write-Host '策略已移除（重启后生效）'
} else {
    Write-Host '已保留策略（-KeepPolicy）'
}

# 3. 删除程序目录
Write-Host '[3/3] 删除程序目录...'
Set-Location $env:SystemDrive
Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '卸载完成。建议重启系统以完全移除策略。' -ForegroundColor Green
