# compile.ps1 - 编译 Agent（.NET Framework 4.8 csc）
param([string]$Root = 'C:\wdac-platform')
$ErrorActionPreference = 'Stop'
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$cs = Join-Path $Root 'agent\WdacAgent.cs'
$exe = Join-Path $Root 'agent\WdacAgent.exe'
if (-not (Test-Path $cs)) { throw "源码不存在: $cs" }
& $csc /nologo /target:exe /out:"$exe" "$cs" /r:System.ServiceProcess.dll
if ($LASTEXITCODE -ne 0) { throw "编译失败: exit=$LASTEXITCODE" }
$info = Get-Item $exe
Write-Host "编译成功: $($info.FullName) ($($info.Length) bytes)"
