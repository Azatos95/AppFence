# wdac-deploy.ps1 - 部署 / 回滚策略
# 用法:
#   .\wdac-deploy.ps1 -PolicyXml policy.xml     # 部署（自动备份）
#   .\wdac-deploy.ps1 -Rollback                 # 回滚（删除策略）

[CmdletBinding(DefaultParameterSetName = 'Deploy')]
param(
    [Parameter(ParameterSetName = 'Deploy')][string]$PolicyXml,
    [Parameter(ParameterSetName = 'Rollback')][switch]$Rollback,
    [Parameter(ParameterSetName = 'Deploy')][switch]$Force
)

. "$PSScriptRoot\wdac-common.ps1"
Assert-WdacAdmin
Initialize-WdacDirs

$sip = 'C:\Windows\System32\CodeIntegrity\SIPolicy.p7b'
$active = 'C:\Windows\System32\CodeIntegrity\CiPolicies\Active'

if ($Rollback) {
    if (Test-Path $sip) {
        $bak = Join-Path $BackupDir ('SIPolicy.p7b.removed.' + (Get-Date -Format 'yyyyMMddHHmmss'))
        Copy-Item $sip $bak -Force
        Remove-Item $sip -Force
        Write-WdacLog "已移除 SIPolicy.p7b（备份: $bak）"
    }
    if (Test-Path $active) {
        $cips = Get-ChildItem $active -Filter '*.cip' -ErrorAction SilentlyContinue
        foreach ($c in $cips) {
            $bak = Join-Path $BackupDir ($c.Name + '.removed.' + (Get-Date -Format 'yyyyMMddHHmmss'))
            Copy-Item $c.FullName $bak -Force
            Remove-Item $c.FullName -Force
        }
        if ($cips.Count -gt 0) { Write-WdacLog "已移除 $($cips.Count) 个多策略 .cip（备份在 $BackupDir）" }
    }
    Write-WdacLog '回滚完成，请重启系统生效' 'WARN'
    return
}

if (-not $PolicyXml -or -not (Test-Path $PolicyXml)) {
    throw "策略文件不存在: $PolicyXml"
}

# 部署前覆盖率检查（审计模式自动跳过）
$precheckJson = Join-Path $OutDir 'precheck.json'
& "$PSScriptRoot\precheck.ps1" -PolicyXml $PolicyXml -JsonOutput $precheckJson | Out-Null
$precheckExit = $LASTEXITCODE
if ($precheckExit -ne 0) {
    if (-not $Force) {
        throw "策略覆盖率不足（关键系统程序未覆盖），已阻止部署。确认风险后使用 -Force 强制部署。详情见 $precheckJson"
    }
    Write-WdacLog '覆盖率检查未通过，但 -Force 已指定，继续部署（风险自担）' WARN
}

# 备份现有策略
if (Test-Path $sip) {
    $bak = Join-Path $BackupDir ('SIPolicy.p7b.bak.' + (Get-Date -Format 'yyyyMMddHHmmss'))
    Copy-Item $sip $bak -Force
    Write-WdacLog "已备份旧策略: $bak"
}

# 转换并部署
$ErrorActionPreference = 'Stop'
$bin = Join-Path $OutDir 'policy.p7b'
ConvertFrom-CIPolicy -XmlFilePath $PolicyXml -BinaryFilePath $bin -ErrorAction Stop
if (-not (Test-Path $bin)) { throw '策略转换失败，未生成二进制文件' }
Copy-Item $bin $sip -Force
Write-WdacLog "策略已部署: $sip（$((Get-Item $sip).Length) bytes），请重启系统生效" 'WARN'

# 部署后自检
$status = Get-WdacCIStatus
Write-WdacLog "当前 CI 状态: $($status.State)（重启后应变为 Enforced/Audit）"
