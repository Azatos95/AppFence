# PoC 验证报告

日期：2026-11-13 · 环境：Windows 10 教育版 22H2（19045.2965）VMware 虚拟机

## 结论

| 能力 | 结果 | 证据 |
|---|---|---|
| 策略部署（legacy 单策略） | ✅ | `SIPolicy.p7b` 加载，事件 3099 |
| 强制模式生效 | ✅ | `notepad` Deny 规则真实拦截（BLOCKED） |
| 未签名程序拦截 | ✅ | 64MB 未签名 exe 运行即被拦（3089/3077/3033） |
| 审计事件 | ✅ | 3076/3077/3089 完整记录 |
| 系统稳定性 | ✅ | 驱动经 Microsoft Windows 签名者放行后正常 |
| 一键回滚 | ✅ | 删除策略 + 重启，CI=0 干净恢复 |
| 白名单放行（Allow） | ⚠️ | legacy 单策略下 Allow 规则不生效（见 SIGNING_ISSUE） |
| 多策略格式 | ⚠️ | .cip 生成/部署成功，签名阻塞（见 SIGNING_ISSUE） |

## 关键事实

1. WDAC 教育版可用，`ConvertFrom-CIPolicy` 可生成可加载策略。
2. **Audit Mode 规则会让策略只审计不拦截**——强制模式必须移除 `Enabled:Audit Mode`。
3. **CI 状态**：`Win32_DeviceGuard.CodeIntegrityPolicyEnforcementStatus` 实测 1=Audit、2=Enforced（与部分文档描述相反，以行为为准）。
4. **驱动放行**依赖 Microsoft Windows 证书签名者（TBS `78EAC555...`）；缺失时系统驱动会被拦截（网络中断等）。
5. `New-CIPolicy -ScanPath` 在 ConfigCI 模块 1.0 中无效（只做全盘扫描）。
6. legacy 单策略：**Deny 规则生效，Allow 规则不生效**（多次验证）。

## 已确定的架构方向

- 采用**多策略格式**（`CiPolicies\Active\*.cip` + 签名），微软 1903+ 推荐路线。
- 策略签名需要代码签名证书；自签证书在 signtool 下存在兼容问题，待解决。
- 产品化组件：Agent（学习采集 + 策略执行）+ 本地控制台（策略编排 + 审批 + 审计）。
