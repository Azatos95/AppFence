# netctl.ps1 - 网络围栏（按程序 + 可选目标 IP/网段，基于 Windows 防火墙）
# 用法:
#   .\netctl.ps1 -Path 'C:\path\app.exe' -Action block                    # 禁止该程序所有出站
#   .\netctl.ps1 -Path 'C:\path\app.exe' -Action block -RemoteAddress 1.2.3.4  # 禁止访问该目标
#   .\netctl.ps1 -Path 'C:\path\app.exe' -Action unblock [-RemoteAddress X]    # 解除
#   .\netctl.ps1 -Path 'C:\path\app.exe' -Action status
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [ValidateSet('block', 'unblock', 'status')][string]$Action = 'block',
    [string]$RemoteAddress = ''
)

. "$PSScriptRoot\wdac-common.ps1"
Assert-WdacAdmin
Initialize-WdacDirs

if (-not (Test-Path $Path)) { throw "文件不存在: $Path" }

$leaf = Split-Path $Path -Leaf
$suffix = ''
if ($RemoteAddress) { $suffix = '-' + ($RemoteAddress -replace '[^\w\.\-:]', '_') }
$ruleName = 'WDAC-Outbound-' + $leaf + $suffix

if ($Action -eq 'block') {
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-WdacLog "联网限制已存在: $ruleName"
    } else {
        $params = @{
            DisplayName = $ruleName
            Program = $Path
            Direction = 'Outbound'
            Action = 'Block'
            Profile = 'Any'
            Enabled = $true
        }
        if ($RemoteAddress) { $params['RemoteAddress'] = $RemoteAddress }
        New-NetFirewallRule @params -ErrorAction Stop | Out-Null
        if ($RemoteAddress) {
            Write-WdacLog "已禁止联网: $Path -> $RemoteAddress（规则: $ruleName）"
        } else {
            Write-WdacLog "已禁止联网: $Path（规则: $ruleName）"
        }
    }
} elseif ($Action -eq 'unblock') {
    $existing = @(Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        $existing | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Write-WdacLog "已解除联网限制: $ruleName"
    } else {
        Write-WdacLog "未找到联网限制: $ruleName"
    }
} else {
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    $state = if ($existing) { '禁止联网' } else { '允许联网' }
    Write-WdacLog "状态: $leaf -> $state（目标: $(if ($RemoteAddress) { $RemoteAddress } else { '全部' })）"
}
