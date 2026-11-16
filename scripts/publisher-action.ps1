# publisher-action.ps1 - 按发布者批量信任/拒绝
param(
    [Parameter(Mandatory = $true)][string]$Publisher,
    [ValidateSet('trust', 'deny')][string]$Action = 'trust'
)

. "$PSScriptRoot\wdac-common.ps1"
Assert-WdacAdmin
Initialize-WdacDirs

& "$PSScriptRoot\uninstall-app.ps1" -Action scan | Out-Null
$appsFile = Join-Path $OutDir 'apps.json'
if (-not (Test-Path $appsFile)) { throw '应用清单不存在' }
$d = ConvertFrom-Json -InputObject (Get-Content $appsFile -Raw -Encoding UTF8)
$apps = @($d.Apps | Where-Object { $_.Publisher -eq $Publisher })
if ($apps.Count -eq 0) {
    Write-WdacLog "未找到该发布者的应用: $Publisher"
    return
}

$ok = 0
$fail = 0
foreach ($a in $apps) {
    $loc = [string]$a.InstallLocation
    if (-not $loc -or -not (Test-Path $loc -PathType Container)) {
        $fail++
        continue
    }
    if ($Action -eq 'trust') {
        & "$PSScriptRoot\addpath.ps1" -Path $loc -Type folder | Out-Null
        $ok++
    } else {
        $files = @(Get-ChildItem $loc -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension.ToLower() -in '.exe', '.dll', '.sys' })
        foreach ($f in $files) {
            & "$PSScriptRoot\deny.ps1" -Path $f.FullName | Out-Null
        }
        $ok++
    }
}
$verb = if ($Action -eq 'trust') { '信任' } else { '拒绝' }
Write-WdacLog "发布者 $Publisher：已$verb $ok 个应用（跳过 $fail 个）"
