# AppFence vs ThreatLocker 功能对比（更新版）

日期：2026-11-16 · 更新：已补充提权控制、网络围栏增强、多策略签名

## 一、定位差异

| | ThreatLocker | AppFence |
|---|---|---|
| 目标用户 | 企业（多终端） | 个人/小团队/单机 |
| 架构 | 云控制台 + 内核驱动 | 本地服务 + 浏览器（无驱动） |
| 成本 | 商业订阅 | 免费 |
| 网络 | 需要联网 | **完全离线** |

## 二、功能对比（当前最新）

| 能力 | ThreatLocker | AppFence | 差距 |
|---|---|---|---|
| **默认拒绝白名单** | ✅ 核心 | ✅ WDAC 审计/强制（哈希/路径/目录/Deny） | 对齐 |
| **签名者/证书规则** | ✅ 稳定 | ✅ **多策略格式 + PKCS#7 签名**（已验证 CI=Audit 加载） | 基本对齐（强制模式待验证） |
| **Ringfencing 网络** | ✅ 内核级（程序×目标） | ✅ **按程序 + 目标 IP/网段**（防火墙） | 用户态 vs 内核（可被提权绕过） |
| **Ringfencing 存储/注册表/进程** | ✅ 内核级 | ❌ 未实现 | **大差距** |
| **提权控制** | ✅ 透明审批替代 UAC | ✅ **审批流**（申请/批准/拒绝/记录） | **无透明提权**（用户仍需手动 UAC） |
| **审批流** | ✅ Cyber Hero 或内部 | ✅ 内部审批 + 申请工具 | 内部对齐 |
| **集中管理（多终端）** | ✅ 云控制台/组策略 | ❌ 单机 | **缺失** |
| **应用商店/预批准** | ✅ User Store | ❌ | 缺失 |
| **审计与报告** | ✅ 完整/合规 | ✅ 审计/CSV/HTML/健康 | 个人尺度对齐 |
| **启动项管理** | ❌ | ✅ 扫描/监视/增删/快照/未知发布者 | **AppFence 独有** |
| **应用扫描与卸载** | ❌ | ✅ Geek 式（备份/卸载/彻底删除） | **AppFence 独有** |
| **事件→软件映射** | ⚠️ 偏技术 | ✅ 软件名→组件（小白友好） | AppFence 更直观 |
| **部署复杂度** | 高 | 低（单 exe） | AppFence 更简单 |
| **崩溃风险** | 驱动级 | 审计模式安全 + 看门狗回滚 | 各有风险，AppFence 可控 |
| **性能** | 低 | 低 | 相当 |

## 三、本轮新增能力（对比更新）

| 新增 | 说明 | 对比意义 |
|---|---|---|
| **提权控制** | 申请→审批→记录，控制台 UI | 补齐 ThreatLocker Elevation Control 的**审批层**；但无透明提权（UAC 仍需用户操作） |
| **网络围栏增强** | 按程序 + 目标 IP/网段阻止 | 更接近 Ringfencing 网络控制（仍用户态） |
| **多策略签名** | 自签名证书 + PKCS#7 + Active 部署 | **签名者规则恢复**（legacy 失效问题绕过），逼近 ThreatLocker 的证书白名单 |

## 四、AppFence 优势

1. **离线免费**、无云依赖
2. **部署极简**（单 exe / 静默 / 自动开浏览器）
3. **审计先行 + 看门狗回滚**（个人慢慢调更安全）
4. **一体化**：白名单 + 启动项 + 卸载 + 清单 + 提权申请
5. **小白友好**（软件名映射、报告导出）

## 五、剩余差距（诚实）

| 差距 | 影响 | 状态 |
|---|---|---|
| **无内核围栏**（存储/注册表/进程） | 无法限制程序文件/注册表/进程行为 | 架构限制（用户接受无驱动） |
| **提权不能透明替代 UAC** | 用户仍需手动提权 | 用户态限制；审批层已补 |
| **无集中管理** | 每台机器独立 | 规划 1.0 |
| **多策略强制模式未验证** | 签名者规则在强制下是否 100% 生效未实测 | 可选验证（VM 快照测试） |
| **家庭版受限** | 不能部署完整 WDAC | 系统限制 |

## 六、结论

- **企业采购**：ThreatLocker 仍全面领先（内核围栏、透明提权、集中管理、合规）。
- **个人/单机/离线**：**AppFence 已覆盖约 85% 的实用价值**——白名单、审批、提权申请、网络围栏、启动项、卸载、审计、回滚，**轻量免费可控**。
- **最值得继续补**：
  1. **多策略强制模式验证**（确认签名者规则在强制下生效）
  2. **按目标"仅允许"网络策略**（需要系统出站默认阻止，谨慎）
  3. **多终端集中管理**（规划 1.0）

## 参考

- [ThreatLocker: Zero Trust in action](https://www.threatlocker.com/blog/zero-trust-in-action-blocking-and-containing-applications)
- [ThreatLocker Cyber Hero Approvals](https://www.threatlocker.com/platform/cyber-hero-approvals)
- [ThreatLocker: Default-Deny & Ringfencing](https://www.infotech.com/software-reviews/vendor-technology-notes/threatlocker-default-deny-endpoint-protection-for-the-post-mythos-threat-environment)
- [ThreatLocker User Store](https://www.threatlocker.com/platform-archive/user-store-archive)
