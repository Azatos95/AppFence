# 策略签名问题记录（SIGNING_ISSUE）

## 现象

多策略 `.cip` 需要签名后才能被 Code Integrity 加载到 `CiPolicies\Active`。当前环境签名失败：

| 尝试 | 结果 |
|---|---|
| signtool 10.0.29648（预览版）`/p7` | `Error: pkcs7 sign. (-2147024893/0x80070003)`（路径错误） |
| signtool 10.0.26100 `sign /fd sha256 /p7 <cip> /p7co 1.3.6.1.4.1.311.10.3.12 /p7ce 0 /f <pfx> /p <pwd> <cip>` | `SignTool Error: File not found: C:\wdac\policy3.pfx`（文件实际存在） |
| signtool `/a`（自动选证书） | `No certificates were found that met all the given criteria` |
| .NET `SignedCms` 手工签名 | 输出 0 字节（ComputeSignature 未成功） |
| vmrun 直接调用 signtool（绕过 PowerShell） | 同样失败 |

## 已排除的因素

- pfx 文件存在且大小正常（2589–2645 字节）
- `certutil -exportPFX` 正常导出（提示"无法以纯文本方式导出私钥"属正常，证书有私钥）
- 证书扩展存在 `2.5.29.37`（EKU）
- 路径问题排除（根目录 `C:\policy3.pfx` 同样报错）
- 证书已装入 `LocalMachine\My` 与 `LocalMachine\Root`

## 根因推断

signtool 报 `File not found` 是**误导性错误**，实际是证书/PFX 无法被 signtool 接受。可能方向：

1. **自签证书的私钥提供程序**：`Microsoft Software Key Storage Provider` 与 signtool 的 CryptoAPI 路径不兼容（常见于自签 + 无 CSP 场景）。
2. **signtool 对策略签名证书的额外要求**：可能需要证书链到受信任根 + `Trusted Publishers` 存储。
3. **signtool 10 的 `/p7` 模式在旧系统（Win10 19045）上的兼容问题**。

## 解决路径（待验证）

1. **AppControl Manager**（微软官方开源 GUI）：内置策略签名与部署，最省事。
2. **正式代码签名证书**（EV/OV）：产品化本就需要的采购项。
3. **在目标机器上使用 Windows SDK 的完整 signtool 环境**（而非单独复制 exe）。
4. **.NET SignedCms 正确构造**：需要 `ContentInfo` 使用自定义 OID + `CmsSigner` 完整链，调试成本较高。

## 临时规避

- 策略签名可暂缓：先生成未签名 `.cip` 放 Active（不会被加载，CI=0，无风险）。
- 放行规则可在 legacy 单策略上继续开发（Deny 已验证可用）。

## 2026-11-13 深夜补充（AppControl Manager 路线）

1. AppControl Manager 仅通过 Microsoft Store 分发（MSIX）；winget 下载被 Entra 认证拦截，rg-adguard 403。
2. 从其源码 `eXclude/CommonCore/Signing/Main.cs` 提取了官方 `SignCIP` 实现：
   - `ContentInfo(Oid(1.3.6.1.4.1.311.10.3.12), fileContent)`
   - `CmsSigner` + `IssuerAndSerialNumber` + `ComputeSignature(signer, false)`
   - 签名后把 CMS version 从 3 修补为 1
3. 照抄实现仍报 `ASN1 损坏的数据`。**根因定位**：`ConvertFrom-CIPolicy` 输出的 `.cip` 是**原始 SIPolicy 二进制**（文件头 `07 00 00 00`，不是 PKCS#7）。.NET `SignedCms` 的 `ContentInfo.content` 要求 ASN.1 合法的 ANY 内容，原始二进制不是合法 ASN.1，导致编码失败。
4. signtool 的 `/p7` 内部会做 OCTET STRING 包装，因此能处理原始二进制；但 signtool 对自签 PFX 报误导性 `File not found`（未解决）。
5. **剩余可行路径**：
   - 手工构造 PKCS#7（ContentInfo content 用 OCTET STRING 包装原始二进制，再 SignedCms 签名）——需要一次实验。
   - 在装有完整 Windows SDK / AppControl Manager 的机器上完成签名，把 signed .cip 拷回。
   - 采购正式代码签名证书后再处理。
