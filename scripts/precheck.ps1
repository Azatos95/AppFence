# precheck.ps1 - 部署前策略覆盖率检查
# 检查策略是否覆盖关键系统程序（避免强制模式下系统卡死）
# 用法: .\precheck.ps1 -PolicyXml policy.xml [-JsonOutput precheck.json]
# 退出码: 0 = 通过；1 = 覆盖率不足（应阻止强制部署）

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PolicyXml,
    [string]$JsonOutput
)

. "$PSScriptRoot\wdac-common.ps1"
Initialize-WdacDirs
if (-not $JsonOutput) { $JsonOutput = Join-Path $OutDir 'precheck.json' }
if (-not (Test-Path $PolicyXml)) { throw "策略文件不存在: $PolicyXml" }

# TBS 计算
$cs = @'
using System;
using System.Security.Cryptography;
public class TbsCalc2 {
    static void ReadLen(byte[] d, int off, out int len, out int bytes) {
        len = d[off]; bytes = 1;
        if ((len & 0x80) == 0) return;
        int n = len & 0x7F; len = 0;
        for (int i = 0; i < n; i++) len = (len << 8) | d[off + 1 + i];
        bytes = 1 + n;
    }
    public static string Hash(byte[] der) {
        if (der[0] != 0x30) throw new Exception("not seq");
        int off = 1; int clen, cbytes; ReadLen(der, off, out clen, out cbytes); off += cbytes;
        int tbsStart = off;
        if (der[tbsStart] != 0x30) throw new Exception("no tbs");
        int tlen, tbytes; ReadLen(der, tbsStart + 1, out tlen, out tbytes);
        int tbsTotal = 1 + tbytes + tlen;
        byte[] tbs = new byte[tbsTotal];
        Array.Copy(der, tbsStart, tbs, 0, tbsTotal);
        using (SHA256 sha = SHA256.Create()) {
            byte[] h = sha.ComputeHash(tbs);
            System.Text.StringBuilder sb = new System.Text.StringBuilder();
            foreach (byte b in h) sb.Append(b.ToString("X2"));
            return sb.ToString();
        }
    }
}
'@
if (-not ('TbsCalc2' -as [type])) { Add-Type -TypeDefinition $cs -Language CSharp -ReferencedAssemblies 'System.Security' }

# 解析策略：签名者 TBS + 允许哈希
$xml = [xml](Get-Content $PolicyXml -Raw -Encoding UTF8)
$ns = 'urn:schemas-microsoft-com:sipolicy'
$sm = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
$sm.AddNamespace('s', $ns)

$signerTbs = @()
foreach ($s in $xml.SelectNodes('//s:Signers/s:Signer', $sm)) {
    $cr = $s.SelectSingleNode('s:CertRoot', $sm)
    if ($cr -and $cr.Value) { $signerTbs += $cr.Value.ToUpper() }
}
$allowHashes = @()
foreach ($a in $xml.SelectNodes('//s:FileRules/s:Allow', $sm)) {
    if ($a.Hash) { $allowHashes += $a.Hash.ToUpper() }
}

# 审计模式不会拦截，跳过覆盖率检查
$isAudit = $false
foreach ($r in $xml.SelectNodes('//s:Rules/s:Rule', $sm)) {
    if ($r.Option -eq 'Enabled:Audit Mode') { $isAudit = $true }
}
if ($isAudit) {
    $result = [pscustomobject]@{
        PolicyXml   = $PolicyXml
        Pass        = $true
        AuditMode   = $true
        SignerCount = $signerTbs.Count
        AllowCount  = $allowHashes.Count
        Missing     = @()
    }
    $result | ConvertTo-Json -Depth 4 | Out-File $JsonOutput -Encoding UTF8
    Write-WdacLog '部署前检查: 审计模式，跳过覆盖率检查'
    exit 0
}

# 关键系统程序（强制模式下必须可运行）
$critical = @(
    'smss.exe', 'services.exe', 'lsass.exe', 'winlogon.exe', 'csrss.exe',
    'wininit.exe', 'explorer.exe', 'cmd.exe', 'powershell.exe', 'svchost.exe'
)
$missing = @()
foreach ($name in $critical) {
    $p = Join-Path 'C:\Windows\System32' $name
    if (-not (Test-Path $p)) { continue }
    $covered = $false
    $hash256 = (Get-FileHash $p -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
    if ($hash256 -and $allowHashes -contains $hash256.ToUpper()) { $covered = $true }
    if (-not $covered) {
        $sig = Get-AuthenticodeSignature $p -ErrorAction SilentlyContinue
        if ($sig -and $sig.SignerCertificate) {
            $tbs = [TbsCalc2]::Hash($sig.SignerCertificate.RawData)
            if ($signerTbs -contains $tbs) { $covered = $true }
        }
    }
    if (-not $covered) { $missing += $name }
}

# 系统文件抽样覆盖率（防止"关键文件通过但整体覆盖不足"）
$samples = @()
foreach ($d in @('C:\Windows\System32', 'C:\Windows\System32\drivers')) {
    if (Test-Path $d) {
        $samples += @(Get-ChildItem $d -Filter '*.exe' -ErrorAction SilentlyContinue | Get-Random -Count 25 -ErrorAction SilentlyContinue)
        $samples += @(Get-ChildItem $d -Filter '*.sys' -ErrorAction SilentlyContinue | Get-Random -Count 25 -ErrorAction SilentlyContinue)
    }
}
$total = 0; $hit = 0
foreach ($s in $samples) {
    $total++
    $h = (Get-FileHash $s.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
    if ($h -and ($allowHashes -contains $h.ToUpper())) { $hit++; continue }
    $sg = Get-AuthenticodeSignature $s.FullName -ErrorAction SilentlyContinue
    if ($sg -and $sg.SignerCertificate) {
        $tbs = [TbsCalc2]::Hash($sg.SignerCertificate.RawData)
        if ($signerTbs -contains $tbs) { $hit++; continue }
    }
}
$coverage = 0
if ($total -gt 0) { $coverage = [math]::Round($hit / $total, 3) }
$threshold = 0.9
if ($coverage -lt $threshold) {
    $missing += "系统文件覆盖率 $([math]::Round($coverage*100,1))% < 90%（抽样 $hit/$total）"
}

$result = [pscustomobject]@{
    PolicyXml   = $PolicyXml
    Pass        = ($missing.Count -eq 0)
    SignerCount = $signerTbs.Count
    AllowCount  = $allowHashes.Count
    Coverage    = $coverage
    Sampled     = $total
    Missing     = @($missing)
}
$result | ConvertTo-Json -Depth 4 | Out-File $JsonOutput -Encoding UTF8
Write-WdacLog ("部署前检查: " + $(if ($result.Pass) { '通过' } else { "未通过（缺少覆盖: $($missing -join ', ')）" }))
if (-not $result.Pass) { exit 1 } else { exit 0 }
