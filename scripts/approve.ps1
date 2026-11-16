# approve.ps1 - 一键允许程序（加入规则并重新部署）
param(
    [Parameter(Mandatory = $true)][string]$Path
)

. "$PSScriptRoot\wdac-common.ps1"
Initialize-WdacDirs
Assert-WdacAdmin

if (-not (Test-Path $Path)) { throw "文件不存在: $Path" }

$rulesFile = Join-Path $OutDir 'rules.json'
$data = $null
if (Test-Path $rulesFile) {
    try { $data = Get-Content $rulesFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
if (-not $data) { $data = [pscustomobject]@{ Rules = @() } }
$rules = @($data.Rules)

$exists = $rules | Where-Object { $_.FilePath -eq $Path }
if (-not $exists) {
    $hash = (Get-FileHash $Path -Algorithm SHA256).Hash
    $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction SilentlyContinue
    $signer = $null
    if ($sig -and $sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject }
    $rules += [pscustomobject]@{
        FilePath  = $Path
        SHA256    = $hash
        Signer    = $signer
        SigStatus = 'Approved'
    }
    $data.Rules = $rules
    $data | ConvertTo-Json -Depth 6 | Out-File $rulesFile -Encoding UTF8
    Write-WdacLog "已允许: $Path ($hash)"
} else {
    Write-WdacLog "已在规则中: $Path"
}

Write-WdacLog '重新生成并部署策略...'
& "$PSScriptRoot\wdac-build.ps1" -RulesFile $rulesFile -OutputFile (Join-Path $OutDir 'policy.xml')
& "$PSScriptRoot\wdac-deploy.ps1" -PolicyXml (Join-Path $OutDir 'policy.xml')
Write-WdacLog '审批完成（重启后策略生效）'
