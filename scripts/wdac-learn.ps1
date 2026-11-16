# wdac-learn.ps1 - 学习模式：从 CodeIntegrity 事件采集规则草稿
# 用法: .\wdac-learn.ps1 [-MaxEvents 2000] [-OutputFile rules.json]

[CmdletBinding()]
param(
    [int]$MaxEvents = 2000,
    [string]$OutputFile
)

. "$PSScriptRoot\wdac-common.ps1"
Assert-WdacAdmin
Initialize-WdacDirs
if (-not $OutputFile) { $OutputFile = Join-Path $OutDir 'rules.json' }

Write-WdacLog '开始学习模式：读取 CodeIntegrity 事件（3076/3077/3089）...'
$events = Get-WdacCIEvents -MaxEvents $MaxEvents
Write-WdacLog "原始事件 $($events.Count) 条"

$files = $events |
    Where-Object { $_.FilePath } |
    Select-Object -ExpandProperty FilePath -Unique
Write-WdacLog "提取到 $($files.Count) 个不同文件"

# 限制处理规模，避免个别文件（大文件/被安全软件挂钩的文件）导致卡死
$maxFiles = 150
$files = @($files | Select-Object -First $maxFiles)
Write-WdacLog "本次处理上限 $maxFiles 个文件"

$rules = @()
foreach ($f in $files) {
    if (-not (Test-Path $f)) {
        Write-WdacLog "跳过不存在的文件: $f" WARN
        continue
    }
    try {
        $fi = Get-Item $f -ErrorAction Stop
        if ($fi.Length -gt 50MB) {
            Write-WdacLog "跳过超大文件: $f" WARN
            continue
        }
        $sha1 = (Get-FileHash -Path $f -Algorithm SHA1 -ErrorAction Stop).Hash
        $sha256 = (Get-FileHash -Path $f -Algorithm SHA256 -ErrorAction Stop).Hash
        $sig = Get-AuthenticodeSignature -FilePath $f -ErrorAction SilentlyContinue
        $signer = $null
        if ($sig -and $sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject }
        $rules += [pscustomobject]@{
            FilePath = $f
            SHA1     = $sha1
            SHA256   = $sha256
            Signer   = $signer
            SigStatus = if ($sig) { $sig.Status.ToString() } else { 'Unknown' }
        }
    } catch {
        Write-WdacLog "读取失败 $f : $($_.Exception.Message)" WARN
    }
}

$result = [pscustomobject]@{
    GeneratedAt = (Get-Date).ToString('o')
    Computer    = $env:COMPUTERNAME
    CIStatus    = (Get-WdacCIStatus)
    RuleCount   = $rules.Count
    Rules       = $rules
}
$result | ConvertTo-Json -Depth 6 | Out-File $OutputFile -Encoding UTF8
Write-WdacLog "学习完成：$($rules.Count) 条规则 → $OutputFile"
