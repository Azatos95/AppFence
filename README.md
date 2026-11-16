# AppFence（应用围栏）（ThreatLocker 风格 Windows 应用白名单）

离线优先的 Windows 端应用白名单平台，基于微软 WDAC（App Control for Business）。

## 当前状态

- **PoC 已验证**：策略部署、强制模式拦截、审计事件、回滚（详见 `docs/POC_REPORT.md`）
- **待解决**：多策略格式签名（signtool 对自签证书兼容问题，见 `docs/SIGNING_ISSUE.md`）
- **未开始**：Agent 服务化、本地控制台

## 目录结构

```
wdac-platform/
├── docs/               # 设计文档与报告
├── scripts/            # 核心 PowerShell 脚本（离线可用）
│   ├── wdac-common.ps1     # 公共函数
│   ├── wdac-learn.ps1      # 学习模式：采集事件 → 生成规则草稿
│   ├── wdac-build.ps1      # 规则草稿 → 策略 XML
│   ├── wdac-deploy.ps1     # 部署 / 回滚（legacy 单策略）
│   └── wdac-sign.ps1       # 策略签名（多策略，当前阻塞）
├── agent/              # 终端 Agent（待开发）
└── console/            # 本地 Web 控制台（待开发）
```

## 快速使用（VM 内以管理员执行）

```powershell
# 1. 学习模式：采集当前系统已有程序的执行事件（需要在策略审计模式下运行）
.\scripts\wdac-learn.ps1

# 2. 生成策略
.\scripts\wdac-build.ps1 -RulesFile .\out\rules.json -OutputFile .\out\policy.xml

# 3. 部署（自动转换 + 备份）
.\scripts\wdac-deploy.ps1 -PolicyXml .\out\policy.xml

# 4. 回滚
.\scripts\wdac-deploy.ps1 -Rollback
```

## 设计原则

1. **离线优先**：不依赖任何云服务，所有组件本地运行。
2. **默认拒绝**：非明确允许的程序不执行。
3. **可回滚**：所有变更前自动备份，支持一键恢复。
4. **先审计后强制**：学习模式先收集，减少误杀。
