# setup.ps1 - 安装脚本（由安装器解压后调用）
# 功能：编译 Agent、注册为 Windows 服务、启动

param(
    [string]$Root = 'C:\wdac-platform',
    [switch]$Silent
)
$ErrorActionPreference = 'Stop'

Write-Host '=== WDAC Platform 安装 ===' -ForegroundColor Cyan

# 0. 先停止旧服务（释放 exe，避免编译失败）
Write-Host '[0/3] 停止旧服务…'
sc.exe stop WdacAgent 2>$null | Out-Null
Start-Sleep -Seconds 2

# 1. 编译 Agent
Write-Host '[1/3] 编译 Agent...'
& (Join-Path $Root 'agent\compile.ps1') -Root $Root
$exe = Join-Path $Root 'agent\WdacAgent.exe'
if (-not (Test-Path $exe)) { throw 'Agent 编译失败' }

# 2. 注册服务（先清理旧实例）
Write-Host '[2/3] 注册 Windows 服务...'
sc.exe stop WdacAgent 2>$null | Out-Null
sc.exe delete WdacAgent 2>$null | Out-Null
Start-Sleep -Seconds 1
$binPath = '"' + $exe + '"'
sc.exe create WdacAgent binPath= $binPath start= auto DisplayName= "AppFence Agent" | Out-Null
sc.exe description WdacAgent "AppFence 应用围栏 Agent（本地 API + 学习采集）" | Out-Null

# 3. 启动服务
Write-Host '[3/3] 启动服务...'
sc.exe start WdacAgent | Out-Null
Start-Sleep -Seconds 2
$svc = Get-Service WdacAgent -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('服务状态: ' + $(if ($svc) { $svc.Status } else { '未知' })) -ForegroundColor Green
Write-Host '安装完成！' -ForegroundColor Green
Write-Host '控制台地址: http://localhost:8765' -ForegroundColor Yellow
Write-Host '卸载命令: sc.exe stop WdacAgent; sc.exe delete WdacAgent'

# 注册托盘告警（当前用户登录自启）
try {
    $tray = Join-Path $Root 'agent\WdacTray.exe'
    if (Test-Path $tray) {
        New-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'WdacTray' -Value ('"' + $tray + '"') -PropertyType String -Force | Out-Null
        Write-Host '已注册托盘告警（登录自启）'
        if (-not $Silent) { Start-Process $tray -ErrorAction SilentlyContinue }
    }
} catch { }
