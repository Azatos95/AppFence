# addpath.ps1 - 添加路径/目录规则
# 用法:
#   .\addpath.ps1 -Path 'C:\Program Files\App\app.exe' -Type path    # 精确路径规则（按路径放行，不校验哈希）
#   .\addpath.ps1 -Path 'C:\Program Files\App' -Type folder          # 目录规则（展开为目录内所有可执行文件的哈希）
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [ValidateSet('path', 'folder')][string]$Type = 'path',
    [switch]$Deploy
)

. "$PSScriptRoot\wdac-common.ps1"
Assert-WdacAdmin
Initialize-WdacDirs

$rulesFile = Join-Path $OutDir 'rules.json'
$data = $null
if (Test-Path $rulesFile) {
    try { $data = Get-Content $rulesFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
if (-not $data) { $data = [pscustomobject]@{ Rules = @() } }
$rules = @($data.Rules)

if ($Type -eq 'folder') {
    if (-not (Test-Path $Path -PathType Container)) { throw "目录不存在: $Path" }
    $exts = @('.exe', '.dll', '.sys', '.ps1', '.bat', '.cmd', '.msi', '.com')
    $files = @(Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $exts -contains $_.Extension.ToLower() })
    $added = 0
    foreach ($f in $files) {
        if ($rules | Where-Object { $_.FilePath -eq $f.FullName }) { continue }
        try {
            $sha1 = (Get-FileHash $f.FullName -Algorithm SHA1 -ErrorAction Stop).Hash
            $sha256 = (Get-FileHash $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            $sig = Get-AuthenticodeSignature $f.FullName -ErrorAction SilentlyContinue
            $signer = $null
            if ($sig -and $sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject }
            $rules += [pscustomobject]@{
                FilePath  = $f.FullName
                SHA1      = $sha1
                SHA256    = $sha256
                Signer    = $signer
                SigStatus = 'Approved'
                Type      = 'hash'
                Source    = 'folder'
            }
            $added++
        } catch { }
    }
    Write-WdacLog "目录规则: $Path → 新增 $added 个文件哈希（扫描到 $($files.Count) 个可执行文件）"
} else {
    if (-not (Test-Path $Path -PathType Leaf)) { throw "文件不存在: $Path" }
    $exists = $rules | Where-Object { $_.FilePath -eq $Path -and $_.Type -eq 'path' }
    if (-not $exists) {
        $rules += [pscustomobject]@{
            FilePath  = $Path
            SHA1      = $null
            SHA256    = $null
            Signer    = $null
            SigStatus = 'Approved'
            Type      = 'path'
        }
        Write-WdacLog "路径规则已添加: $Path（按路径放行，不校验哈希）"
    } else {
        Write-WdacLog "路径规则已存在: $Path"
    }
}

$data.Rules = @($rules)
$data | ConvertTo-Json -Depth 6 | Out-File $rulesFile -Encoding UTF8

if ($Deploy) {
    & "$PSScriptRoot\wdac-build.ps1" -RulesFile $rulesFile -OutputFile (Join-Path $OutDir 'policy.xml')
    & "$PSScriptRoot\wdac-deploy.ps1" -PolicyXml (Join-Path $OutDir 'policy.xml')
}
