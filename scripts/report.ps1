# report.ps1 - 生成审计报告（CSV / HTML）
param(
    [ValidateSet('csv', 'html')][string]$Format = 'csv'
)

. "$PSScriptRoot\wdac-common.ps1"
Initialize-WdacDirs

# 数据源
$auditFile = Join-Path $OutDir 'audit.json'
$audit = @()
if (Test-Path $auditFile) {
    try {
        $raw = Get-Content $auditFile -Raw -Encoding UTF8
        if ($raw) {
            $parsed = ConvertFrom-Json -InputObject $raw
            foreach ($p in $parsed) { $audit += $p }
        }
    } catch { }
}
$rules = @()
$rulesFile = Join-Path $OutDir 'rules.json'
if (Test-Path $rulesFile) {
    try {
        $parsedRules = ConvertFrom-Json -InputObject (Get-Content $rulesFile -Raw -Encoding UTF8)
        foreach ($p in $parsedRules.Rules) { $rules += $p }
    } catch { }
}
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

if ($Format -eq 'csv') {
    $lines = @('时间,程序,事件类型,事件ID')
    foreach ($i in $audit) {
        $name = [string]$i.Name
        $name = $name.Replace('"', '""')
        $lines += ('{0},"{1}","{2}",{3}' -f $i.Time, $name, $i.Type, $i.EventId)
    }
    $outFile = Join-Path $OutDir 'report.csv'
    ($lines -join "`r`n") | Out-File $outFile -Encoding UTF8
} else {
    $rows = ''
    foreach ($i in $audit) {
        $cls = if ($i.Type -in @('已阻止', '策略阻止')) { 'color:#dc2626' } else { 'color:#b45309' }
        $rows += ('<tr><td>{0}</td><td>{1}<div style="font-size:11px;color:#666">{2}</div></td><td style="{3}">{4}</td><td>{5}</td></tr>' -f $i.Time, [System.Net.WebUtility]::HtmlEncode($i.Name), [System.Net.WebUtility]::HtmlEncode($i.File), $cls, $i.Type, $i.EventId)
    }
    $blocked = @($audit | Where-Object { $_.Type -in @('已阻止', '策略阻止') }).Count
    $html = @"
<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>WDAC 审计报告</title>
<style>
body { font-family: 'Segoe UI','Microsoft YaHei',sans-serif; margin: 24px; }
h1 { font-size: 20px; } .meta { color: #666; font-size: 13px; margin-bottom: 16px; }
table { border-collapse: collapse; width: 100%; } th, td { border: 1px solid #ddd; padding: 6px 10px; font-size: 13px; text-align: left; }
th { background: #f0f4f8; }
</style></head><body>
<h1>WDAC 审计报告</h1>
<div class="meta">生成时间: $stamp · 规则数: $($rules.Count) · 审计记录: $($audit.Count) · 拦截事件: $blocked</div>
<table><thead><tr><th>时间</th><th>程序</th><th>事件类型</th><th>事件 ID</th></tr></thead><tbody>
$rows
</tbody></table></body></html>
"@
    $outFile = Join-Path $OutDir 'report.html'
    $html | Out-File $outFile -Encoding UTF8
}

Write-WdacLog "报告已生成: $outFile"
