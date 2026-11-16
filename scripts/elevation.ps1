# elevation.ps1 - 提权申请/审批（用户态，记录 + 审批；无法透明替代 UAC）
param(
    [ValidateSet('request', 'approve', 'deny', 'list')][string]$Action = 'list',
    [string]$Path,
    [string]$Id,
    [string]$Reason = ''
)

. "$PSScriptRoot\wdac-common.ps1"
Initialize-WdacDirs
$reqFile = Join-Path $OutDir 'elevation-requests.json'

$requests = @()
if (Test-Path $reqFile) {
    try {
        $raw = Get-Content $reqFile -Raw -Encoding UTF8
        if ($raw) {
            foreach ($x in (ConvertFrom-Json -InputObject $raw)) { $requests += $x }
        }
    } catch { }
}

if ($Action -eq 'request') {
    if (-not $Path -or -not (Test-Path $Path)) { throw "文件不存在: $Path" }
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $requests += [pscustomobject]@{
        Id     = $id
        Path   = $Path
        Name   = (Split-Path $Path -Leaf)
        User   = $env:USERNAME
        Time   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Reason = $Reason
        Status = 'pending'
    }
    Write-WdacLog "提权申请已提交: $Path（ID: $id）"
} elseif ($Action -eq 'approve') {
    if (-not $Id) { throw '需要 Id' }
    $found = $false
    foreach ($r in $requests) {
        if ($r.Id -eq $Id) {
            $r.Status = 'approved'
            $r.ApprovedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $found = $true
            Write-WdacLog "提权申请已批准: $($r.Path)（ID: $Id）"
        }
    }
    if (-not $found) { throw "未找到申请: $Id" }
} elseif ($Action -eq 'deny') {
    if (-not $Id) { throw '需要 Id' }
    foreach ($r in $requests) {
        if ($r.Id -eq $Id) {
            $r.Status = 'denied'
            $r.DeniedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Write-WdacLog "提权申请已拒绝: $($r.Path)"
        }
    }
}

$requests = @($requests | Select-Object -Last 200)
ConvertTo-Json -InputObject @($requests) -Depth 4 | Out-File $reqFile -Encoding UTF8
if ($Action -eq 'list') { Write-WdacLog "提权申请: $($requests.Count) 条" }
