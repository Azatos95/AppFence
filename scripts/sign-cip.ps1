# sign-cip.ps1 - 生成/签名/部署多策略格式（签名者规则生效）
# 用法:
#   .\sign-cip.ps1 -PolicyXml 'C:\wdac-platform\out\policy.xml'              # 只签名
#   .\sign-cip.ps1 -PolicyXml '...' -Deploy                                 # 签名并部署到 Active（重启生效）
param(
    [Parameter(Mandatory = $true)][string]$PolicyXml,
    [string]$PfxFile = 'C:\wdac-platform\state\signing.pfx',
    [string]$PfxPassword = 'AppFence!2026',
    [switch]$Deploy
)

. "$PSScriptRoot\wdac-common.ps1"
Assert-WdacAdmin
Initialize-WdacDirs

if (-not (Test-Path $PolicyXml)) { throw "策略文件不存在: $PolicyXml" }

# 1. 确保签名证书存在（自签名，仅本机）
if (-not (Test-Path $PfxFile)) {
    $stateDir = Split-Path $PfxFile -Parent
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Force $stateDir | Out-Null }
    $cert = New-SelfSignedCertificate -Type Custom -Subject 'CN=AppFence Policy Signing' -KeyUsage DigitalSignature -CertStoreLocation 'Cert:\LocalMachine\My' -ErrorAction Stop
    $pwd = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
    Export-PfxCertificate -Cert $cert -FilePath $PfxFile -Password $pwd | Out-Null
    Write-WdacLog "已生成签名证书: $($cert.Thumbprint)"
}

# 2. 生成 CIP（原始二进制）
$cip = $PolicyXml -replace '\.xml$', '.cip'
ConvertFrom-CIPolicy -XmlFilePath $PolicyXml -BinaryFilePath $cip | Out-Null
if (-not (Test-Path $cip)) { throw "CIP 生成失败" }

# 3. 签名（PKCS#7）
$signed = $cip -replace '\.cip$', '-signed.cip'
$signTool = Join-Path $PSScriptRoot 'SignCip.exe'
if (-not (Test-Path $signTool)) { throw "缺少 SignCip.exe" }
$r = & $signTool $PfxFile $PfxPassword $cip $signed
Write-WdacLog ("签名结果: " + ($r -join ' '))

if (-not (Test-Path $signed)) { throw "签名失败" }

# 4. 部署到 Active（多策略，重启生效）
if ($Deploy) {
    $guid = [guid]::NewGuid().ToString().ToUpper()
    $dest = "C:\Windows\System32\CodeIntegrity\CiPolicies\Active\$guid.cip"
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    Copy-Item $signed $dest -Force
    Write-WdacLog "已部署签名策略: $dest（重启后生效）"
    Write-WdacLog "注意：多策略格式下签名者规则生效；如需强制拦截请确保策略为强制模式"
} else {
    Write-WdacLog "签名完成（未部署）: $signed"
}
