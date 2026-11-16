# wdac-build.ps1 - 规则草稿 → 策略 XML（支持双哈希 + 签名者规则）
# 用法: .\wdac-build.ps1 -RulesFile rules.json [-OutputFile policy.xml] [-AuditMode]
#
# 已知限制（PoC 结论）：
#   legacy 单策略（SIPolicy.p7b）下 Allow 哈希规则存在不生效问题；
#   签名者规则（AllowedSigners）相对可靠，可作为放行的替代路径。
#   产品化最终走「多策略格式 + 签名」（见 wdac-sign.ps1 / docs/SIGNING_ISSUE.md）。

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RulesFile,
    [string]$OutputFile,
    [switch]$AuditMode
)

. "$PSScriptRoot\wdac-common.ps1"
Initialize-WdacDirs
if (-not $OutputFile) { $OutputFile = Join-Path $OutDir 'policy.xml' }
if (-not (Test-Path $RulesFile)) { throw "规则文件不存在: $RulesFile" }

$data = Get-Content $RulesFile -Raw -Encoding UTF8 | ConvertFrom-Json
$rules = @($data.Rules)
if ($rules.Count -eq 0) { throw '规则文件为空' }

# ---- TBS 计算（证书 TBS 哈希，用于 Signer CertRoot）----
$cs = @'
using System;
using System.Security.Cryptography;
public class TbsCalc {
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
if (-not ('TbsCalc' -as [type])) { Add-Type -TypeDefinition $cs -Language CSharp -ReferencedAssemblies 'System.Security' }

# ---- 规则处理：双哈希 Allow + 签名者收集 ----
$allowXml = @()
$refXml = @()
$signers = [ordered]@{}   # thumbprint -> signer info
$i = 0
foreach ($r in $rules) {
    $i++
    $name = [System.Security.SecurityElement]::Escape((Split-Path $r.FilePath -Leaf))
    $ruleType = 'hash'
    if ($r.Type) { $ruleType = [string]$r.Type }

    # 路径规则：按文件路径允许（不校验哈希；适合软件更新频繁的场景）
    if ($ruleType -eq 'path') {
        $id = "ID_ALLOW_PATH_$i"
        $escapedPath = [System.Security.SecurityElement]::Escape($r.FilePath)
        $allowXml += ('    <Allow ID="{0}" FriendlyName="{1} (Path)" FilePath="{2}" />' -f $id, $name, $escapedPath)
        $refXml += ('        <FileRuleRef RuleID="{0}" />' -f $id)
        continue
    }

    # 例外/拒绝规则：Deny 优先于 Allow（可用于"宽泛允许 + 精确拦截"）
    if ($ruleType -eq 'deny') {
        $denyId = "ID_DENY_$i"
        if ($r.SHA256) {
            $allowXml += ('    <Deny ID="{0}" FriendlyName="{1} (Deny SHA256)" Hash="{2}" />' -f $denyId, $name, $r.SHA256)
            $refXml += ('        <FileRuleRef RuleID="{0}" />' -f $denyId)
        }
        if ($r.SHA1) {
            $allowXml += ('    <Deny ID="{0}" FriendlyName="{1} (Deny SHA1)" Hash="{2}" />' -f ("$denyId`_S1"), $name, $r.SHA1)
            $refXml += ('        <FileRuleRef RuleID="{0}" />' -f ("$denyId`_S1"))
        }
        continue
    }

    if ($r.SHA256) {
        $id = "ID_ALLOW_S256_$i"
        $allowXml += ('    <Allow ID="{0}" FriendlyName="{1} (SHA256)" Hash="{2}" />' -f $id, $name, $r.SHA256)
        $refXml += ('        <FileRuleRef RuleID="{0}" />' -f $id)
    }
    if ($r.SHA1) {
        $id = "ID_ALLOW_S1_$i"
        $allowXml += ('    <Allow ID="{0}" FriendlyName="{1} (SHA1)" Hash="{2}" />' -f $id, $name, $r.SHA1)
        $refXml += ('        <FileRuleRef RuleID="{0}" />' -f $id)
    }

    # 提取签名证书（存在才加签名者规则）
    try {
        $sig = Get-AuthenticodeSignature -FilePath $r.FilePath -ErrorAction SilentlyContinue
        if ($sig -and $sig.SignerCertificate) {
            $tp = $sig.SignerCertificate.Thumbprint
            if (-not $signers.Contains($tp)) {
                $signers[$tp] = [pscustomobject]@{
                    Id   = 'ID_SIGNER_S' + ($signers.Count + 1)
                    Name = $sig.SignerCertificate.Subject
                    Tbs  = [TbsCalc]::Hash($sig.SignerCertificate.RawData)
                }
            }
        }
    } catch { }
}

$signerXml = @()
$allowedSignerXml = @()
foreach ($s in $signers.Values) {
    $signerXml += ('    <Signer ID="{0}" Name="{1}">' -f $s.Id, [System.Security.SecurityElement]::Escape($s.Name))
    $signerXml += ('      <CertRoot Type="TBS" Value="{0}" />' -f $s.Tbs)
    $signerXml += '    </Signer>'
    $allowedSignerXml += ('          <AllowedSigner SignerId="{0}" />' -f $s.Id)
}

# ---- 平台自保护：将平台目录下所有可执行文件（exe/dll/ps1）加入允许列表 ----
# 目的：强制部署后平台自身（Agent/脚本/申请工具）仍可运行，避免"自己把自己拦死"
$platformDirs = @(
    (Join-Path $env:SystemDrive 'wdac-platform\agent'),
    (Join-Path $env:SystemDrive 'wdac-platform\scripts'),
    (Join-Path $env:SystemDrive 'wdac-platform\console')
)
$selfCount = 0
foreach ($dir in $platformDirs) {
    if (-not (Test-Path $dir)) { continue }
    $files = Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension.ToLower() -in '.exe', '.dll', '.ps1' }
    foreach ($f in $files) {
        $h = (Get-FileHash $f.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        if (-not $h) { continue }
        $id = 'ID_ALLOW_SELF_' + [System.Math]::Abs($f.FullName.GetHashCode())
        $fname = [System.Security.SecurityElement]::Escape($f.Name)
        $allowXml += ('    <Allow ID="{0}" FriendlyName="{1} (self-protection)" Hash="{2}" />' -f $id, $fname, $h)
        $refXml += ('        <FileRuleRef RuleID="{0}" />' -f $id)
        $selfCount++
    }
}
if ($selfCount -gt 0) { Write-WdacLog "平台自保护: $selfCount 个文件已加入允许列表" }

$auditRule = ''
if ($AuditMode) {
    $auditRule = "    <Rule>`r`n      <Option>Enabled:Audit Mode</Option>`r`n    </Rule>"
}

$xml = @"
<?xml version="1.0" encoding="utf-8"?>
<SiPolicy xmlns="urn:schemas-microsoft-com:sipolicy">
  <VersionEx>10.0.0.0</VersionEx>
  <PlatformID>{2E07F7E4-194C-4D20-B7C9-6F44A6C5A234}</PlatformID>
  <PolicyTypeID>{A244370E-44C9-4C06-B551-F6016E563076}</PolicyTypeID>
  <Rules>
    <Rule>
      <Option>Enabled:UMCI</Option>
    </Rule>
    <Rule>
      <Option>Enabled:Unsigned System Integrity Policy</Option>
    </Rule>
    <Rule>
      <Option>Enabled:Advanced Boot Options Menu</Option>
    </Rule>
$auditRule
  </Rules>
  <FileRules>
$($allowXml -join "`r`n")
  </FileRules>
  <Signers>
$($signerXml -join "`r`n")
  </Signers>
  <SigningScenarios>
    <SigningScenario Value="131" ID="ID_SIGNINGSCENARIO_DRIVERS_1">
      <ProductSigners>
        <AllowedSigners>
$($allowedSignerXml -join "`r`n")
        </AllowedSigners>
      </ProductSigners>
    </SigningScenario>
    <SigningScenario Value="12" ID="ID_SIGNINGSCENARIO_WINDOWS">
      <ProductSigners>
        <AllowedSigners>
$($allowedSignerXml -join "`r`n")
        </AllowedSigners>
        <FileRulesRef>
$($refXml -join "`r`n")
        </FileRulesRef>
      </ProductSigners>
    </SigningScenario>
  </SigningScenarios>
  <UpdatePolicySigners />
  <CiSigners />
  <HvciOptions>0</HvciOptions>
</SiPolicy>
"@

[System.IO.File]::WriteAllText($OutputFile, $xml, (New-Object System.Text.UTF8Encoding($false)))
Write-WdacLog "策略已生成: $OutputFile（$($rules.Count) 条规则 / $($allowXml.Count) 条哈希 / $($signers.Count) 个签名者，Audit=$AuditMode）"