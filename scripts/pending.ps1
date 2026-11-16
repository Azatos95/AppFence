# pending.ps1 - 输出待审批程序列表（被拦截且未在规则中的程序）
. "$PSScriptRoot\wdac-common.ps1"
Initialize-WdacDirs

$events = Get-WdacCIEvents -MaxEvents 2000
$paths = @{}
foreach ($e in $events) {
    if (-not $e.FilePath) { continue }
    if (-not (Test-Path $e.FilePath)) { continue }
    if (-not $paths.ContainsKey($e.FilePath)) { $paths[$e.FilePath] = $e.Time }
}

$known = @()
$rulesFile = Join-Path $OutDir 'rules.json'
if (Test-Path $rulesFile) {
    try {
        $data = Get-Content $rulesFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $known = @($data.Rules | ForEach-Object { $_.FilePath })
    } catch { }
}

$pending = @()
foreach ($p in $paths.Keys) {
    if ($p -in $known) { continue }
    $app = Resolve-WdacApp $p
    $pending += [pscustomobject]@{
        FilePath   = $p
        Name       = (Split-Path $p -Leaf)
        AppName    = $(if ($app) { $app.Name } else { $null })
        AppVersion = $(if ($app) { $app.Version } else { $null })
        Time       = $paths[$p].ToString('yyyy-MM-dd HH:mm:ss')
    }
}
$pending = @($pending | Sort-Object Time -Descending)
ConvertTo-Json -InputObject @($pending) -Depth 3 | Out-File (Join-Path $OutDir 'pending.json') -Encoding UTF8
Write-WdacLog "待审批: $($pending.Count) 个程序"
