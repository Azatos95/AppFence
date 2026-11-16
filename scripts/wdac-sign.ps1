# wdac-sign.ps1 - 策略签名（多策略格式）
# 用法: .\wdac-sign.ps1 -PolicyCip policy.cip -Pfx cert.pfx -Password pwd
#
# 状态：阻塞中（PoC 环境验证）
#   - signtool 10.0.26100 对自签 pfx 报 "File not found"（误导性错误）
#   - 证书 EKU 扩展存在（2.5.29.37），但 signtool /a 仍报 No certificates
#   - 解决方向：AppControl Manager（官方 GUI）、EV 代码签名证书、或在目标机器重试
# 详见 docs/SIGNING_ISSUE.md

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PolicyCip,
    [Parameter(Mandatory = $true)][string]$Pfx,
    [Parameter(Mandatory = $true)][string]$Password,
    [string]$SigntoolPath = 'C:\wdac\signtool2.exe'
)

. "$PSScriptRoot\wdac-common.ps1"
Assert-WdacAdmin
Initialize-WdacDirs

if (-not (Test-Path $PolicyCip)) { throw "策略文件不存在: $PolicyCip" }
if (-not (Test-Path $Pfx)) { throw "证书文件不存在: $Pfx" }
if (-not (Test-Path $SigntoolPath)) {
    throw "signtool 不存在: $SigntoolPath（请从 Windows SDK 提取并放到该路径）"
}

Write-WdacLog "签名诊断: cip=$((Get-Item $PolicyCip).Length) bytes, pfx=$((Get-Item $Pfx).Length) bytes"

# 诊断：证书
$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Where-Object { $_.HasPrivateKey } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
if ($cert) {
    Write-WdacLog "候选证书: $($cert.Subject) thumb=$($cert.Thumbprint)"
    Write-WdacLog "证书扩展: $(($cert.Extensions | ForEach-Object { $_.Oid.Value }) -join ';')"
}

# 签名（/f + /p 模式，签名原地覆盖）
$args = @(
    'sign',
    '/fd', 'sha256',
    '/p7', $PolicyCip,
    '/p7co', '1.3.6.1.4.1.311.10.3.12',
    '/p7ce', '0',
    '/f', $Pfx,
    '/p', $Password,
    $PolicyCip
)
Write-WdacLog "执行: $SigntoolPath $($args -join ' ')"
$output = & $SigntoolPath @args 2>&1
Write-WdacLog "signtool 输出: $($output | Out-String)"
if ($LASTEXITCODE -ne 0) {
    Write-WdacLog "签名失败（exit=$LASTEXITCODE）。已知问题，参见 docs/SIGNING_ISSUE.md" 'ERROR'
    throw '策略签名失败'
}
Write-WdacLog '签名成功'
