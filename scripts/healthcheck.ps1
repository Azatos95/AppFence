# healthcheck.ps1 - 平台健康检查（策略一致性、服务、规则、磁盘）
. "$PSScriptRoot\wdac-common.ps1"
Initialize-WdacDirs

$checks = @()
function Add-Check([string]$Name, [bool]$Pass, [string]$Detail) {
    $script:checks += [pscustomobject]@{ Name = $Name; Pass = $Pass; Detail = $Detail }
}

# 1. Agent 服务
$svc = Get-Service WdacAgent -ErrorAction SilentlyContinue
Add-Check 'Agent 服务' ($null -ne $svc -and $svc.Status -eq 'Running') $(if ($svc) { $svc.Status.ToString() } else { '未安装' })

# 2. Agent 程序
$exe = 'C:\wdac-platform\agent\WdacAgent.exe'
Add-Check 'Agent 程序' (Test-Path $exe) $(if (Test-Path $exe) { "$((Get-Item $exe).Length) bytes" } else { '缺失' })

# 3. 规则文件
$rulesFile = Join-Path $OutDir 'rules.json'
$ruleCount = 0
$ruleOk = $false
if (Test-Path $rulesFile) {
    try {
        $data = Get-Content $rulesFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $ruleCount = @($data.Rules).Count
        $ruleOk = $ruleCount -gt 0
    } catch { }
}
Add-Check '规则文件' $ruleOk "$ruleCount 条规则"

# 4. 策略文件（若存在）
$sip = 'C:\Windows\System32\CodeIntegrity\SIPolicy.p7b'
$sipOk = $true
$sipDetail = '未部署策略（CI Off）'
if (Test-Path $sip) {
    $size = (Get-Item $sip).Length
    $sipOk = $size -gt 1000
    $sipDetail = "$size bytes"
}
Add-Check '策略文件' $sipOk $sipDetail

# 5. CI 状态
$dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
$ciState = switch ($dg.CodeIntegrityPolicyEnforcementStatus) { 0 { 'Off' } 1 { 'Audit' } 2 { 'Enforced' } default { 'Unknown' } }
Add-Check '代码完整性状态' ($ciState -ne 'Unknown') $ciState

# 6. 待确认标志残留（看门狗用）
$pendingFlag = Join-Path $OutDir 'pending-enforce.json'
$flagOk = -not (Test-Path $pendingFlag)
Add-Check '待确认标志' $flagOk $(if (Test-Path $pendingFlag) { '存在（上次强制部署未确认）' } else { '正常' })

# 7. 磁盘空间（C 盘剩余 > 1 GB）
$free = (Get-PSDrive C -ErrorAction SilentlyContinue).Free
$freeGB = 0
if ($free) { $freeGB = [math]::Round($free / 1GB, 1) }
Add-Check '磁盘空间' ($freeGB -gt 1) "$freeGB GB 可用"

# 8. 日志目录可写
$logOk = $false
try { $t = Join-Path $LogDir '.health-test'; Set-Content $t 'ok' -ErrorAction Stop; Remove-Item $t -Force; $logOk = $true } catch { }
Add-Check '日志目录' $logOk $LogDir

$failed = @($checks | Where-Object { -not $_.Pass })
$result = [pscustomobject]@{
    Time    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Pass    = ($failed.Count -eq 0)
    Failed  = $failed.Count
    Checks  = @($checks)
}
$result | ConvertTo-Json -Depth 4 | Out-File (Join-Path $OutDir 'health.json') -Encoding UTF8
Write-WdacLog ("健康检查: " + $(if ($result.Pass) { '全部通过' } else { "$($failed.Count) 项异常" }))
