# audit.ps1 - 生成审计视图数据（拦截/审计历史）
. "$PSScriptRoot\wdac-common.ps1"
Initialize-WdacDirs

$events = Get-WdacCIEvents -MaxEvents 1000
$typeMap = @{
    3076 = '审计拦截'
    3077 = '已阻止'
    3033 = '策略阻止'
    3089 = '签名信息'
    3099 = '策略加载'
}

$items = @()
foreach ($e in ($events | Sort-Object Time -Descending | Select-Object -First 200)) {
    $type = '其他'
    if ($typeMap.ContainsKey([int]$e.Id)) { $type = $typeMap[[int]$e.Id] }
    $name = ''
    if ($e.FilePath) { $name = Split-Path $e.FilePath -Leaf }
    $app = $null
    if ($e.FilePath) { $app = Resolve-WdacApp $e.FilePath }
    $items += [pscustomobject]@{
        Time       = $e.Time.ToString('yyyy-MM-dd HH:mm:ss')
        File       = $(if ($e.FilePath) { $e.FilePath } else { '' })
        Name       = $name
        AppName    = $(if ($app) { $app.Name } else { $null })
        AppVersion = $(if ($app) { $app.Version } else { $null })
        Type       = $type
        EventId    = $e.Id
    }
}
ConvertTo-Json -InputObject @($items) -Depth 3 | Out-File (Join-Path $OutDir 'audit.json') -Encoding UTF8
Write-WdacLog "审计记录: $($items.Count) 条"
