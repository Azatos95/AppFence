# deny.ps1 - 添加例外/拒绝规则（Deny 优先于 Allow）
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$Deploy
)

. "$PSScriptRoot\wdac-common.ps1"
Assert-WdacAdmin
Initialize-WdacDirs

if (-not (Test-Path $Path)) { throw "文件不存在: $Path" }

$rulesFile = Join-Path $OutDir 'rules.json'
$data = $null
if (Test-Path $rulesFile) {
    try { $data = Get-Content $rulesFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
if (-not $data) { $data = [pscustomobject]@{ Rules = @() } }
$rules = @($data.Rules)

$exists = $rules | Where-Object { $_.FilePath -eq $Path -and $_.Type -eq 'deny' }
if (-not $exists) {
    $sha1 = (Get-FileHash $Path -Algorithm SHA1 -ErrorAction Stop).Hash
    $sha256 = (Get-FileHash $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    $rules += [pscustomobject]@{
        FilePath  = $Path
        SHA1      = $sha1
        SHA256    = $sha256
        Signer    = $null
        SigStatus = 'Denied'
        Type      = 'deny'
    }
    $data.Rules = @($rules)
    $data | ConvertTo-Json -Depth 6 | Out-File $rulesFile -Encoding UTF8
    Write-WdacLog "已添加拒绝规则: $Path（Deny 优先于 Allow）"
} else {
    Write-WdacLog "拒绝规则已存在: $Path"
}

if ($Deploy) {
    & "$PSScriptRoot\wdac-build.ps1" -RulesFile $rulesFile -OutputFile (Join-Path $OutDir 'policy.xml')
    & "$PSScriptRoot\wdac-deploy.ps1" -PolicyXml (Join-Path $OutDir 'policy.xml')
}
