# autostart-manage.ps1 - 启动项管理（增加/移除/恢复），操作前自动快照
param(
    [Parameter(Mandatory = $true)][ValidateSet('add', 'remove', 'restore', 'list')][string]$Action,
    [string]$Name,
    [string]$Command,
    [string]$BackupId
)

. "$PSScriptRoot\wdac-common.ps1"
Assert-WdacAdmin
Initialize-WdacDirs

$backupRoot = Join-Path $OutDir 'autostart-backup'
if (-not (Test-Path $backupRoot)) { New-Item -ItemType Directory -Force $backupRoot | Out-Null }

function New-Backup {
    param([string]$Op, [string]$Type, [string]$ItemName, [string]$ItemCommand, [string]$FilePath, [string]$Scope)
    $ts = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $dir = Join-Path $backupRoot $ts
    New-Item -ItemType Directory -Force $dir | Out-Null
    $entry = [pscustomobject]@{
        Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Op = $Op; Type = $Type; Name = $ItemName; Command = $ItemCommand; Scope = $Scope
    }
    $entry | ConvertTo-Json -Depth 3 | Out-File (Join-Path $dir 'manifest.json') -Encoding UTF8
    if ($FilePath -and (Test-Path $FilePath)) {
        Copy-Item $FilePath (Join-Path $dir 'backup-file') -Force -ErrorAction SilentlyContinue
    }
    return $ts
}

function Get-UserRunPaths {
    $paths = @()
    foreach ($sid in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        if ($sid.PSChildName -notmatch '^S-1-5-21-') { continue }
        foreach ($sub in @('Run', 'RunOnce')) {
            $paths += @{ Path = ('Registry::HKEY_USERS\' + $sid.PSChildName + '\SOFTWARE\Microsoft\Windows\CurrentVersion\' + $sub); Scope = $sid.PSChildName }
        }
    }
    return $paths
}

if ($Action -eq 'add') {
    if (-not $Name -or -not $Command) { throw '需要 Name 和 Command' }
    $runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    New-Item -Path $runKey -Force | Out-Null
    New-ItemProperty $runKey -Name $Name -Value $Command -PropertyType String -Force | Out-Null
    Write-WdacLog "已添加启动项: $Name -> $Command（当前用户 Run）"
} elseif ($Action -eq 'remove') {
    if (-not $Name) { throw '需要 Name' }
    $removed = $false

    # 1. HKLM / HKU Run & RunOnce
    $candidates = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Scope = 'HKLM' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Scope = 'HKLM' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Scope = 'HKLM' }
    )
    $candidates += Get-UserRunPaths
    foreach ($c in $candidates) {
        $v = (Get-ItemProperty $c.Path -ErrorAction SilentlyContinue).$Name
        if ($null -ne $v) {
            $ts = New-Backup 'remove' '注册表' $Name ([string]$v) $null $c.Scope
            Remove-ItemProperty $c.Path -Name $Name -Force -ErrorAction SilentlyContinue
            Write-WdacLog "已移除启动项: $Name（备份: $ts，作用域: $($c.Scope)）"
            $removed = $true
        }
    }

    # 2. 启动文件夹（所有用户）
    if (-not $removed) {
        $folders = @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))
        foreach ($u in (Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
            $s = Join-Path $u.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
            if (Test-Path $s) { $folders += $s }
        }
        foreach ($f in ($folders | Select-Object -Unique)) {
            $p = Join-Path $f $Name
            if (Test-Path $p) {
                $ts = New-Backup 'remove' '启动文件夹' $Name $p $p $f
                Remove-Item $p -Force -ErrorAction SilentlyContinue
                Write-WdacLog "已移除启动项: $Name（备份: $ts）"
                $removed = $true
            }
        }
    }

    # 3. 计划任务
    if (-not $removed) {
        $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        if ($t) {
            $xml = Export-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
            $ts = New-Backup 'remove' '计划任务' $Name $xml $null 'TaskScheduler'
            Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
            Write-WdacLog "已移除计划任务: $Name（备份: $ts）"
            $removed = $true
        }
    }

    if (-not $removed) { Write-WdacLog "未找到启动项: $Name" }
} elseif ($Action -eq 'restore') {
    if (-not $BackupId) { throw '需要 BackupId' }
    $dir = Join-Path $backupRoot $BackupId
    $mf = Join-Path $dir 'manifest.json'
    if (-not (Test-Path $mf)) { throw "备份不存在: $BackupId" }
    $m = Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($m.Op -ne 'remove') { throw "备份类型不支持恢复: $($m.Op)" }

    if ($m.Type -eq '注册表') {
        if ($m.Scope -match '^S-1-5-21-') {
            $key = 'Registry::HKEY_USERS\' + $m.Scope + '\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            New-ItemProperty $key -Name $m.Name -Value $m.Command -PropertyType String -Force | Out-Null
        } else {
            New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name $m.Name -Value $m.Command -PropertyType String -Force | Out-Null
        }
    } elseif ($m.Type -eq '启动文件夹') {
        $target = $m.Scope
        if (-not $target) { $target = [Environment]::GetFolderPath('Startup') }
        Copy-Item (Join-Path $dir 'backup-file') (Join-Path $target $m.Name) -Force -ErrorAction SilentlyContinue
    } elseif ($m.Type -eq '计划任务') {
        $xmlFile = Join-Path $dir 'task.xml'
        $m.Command | Out-File $xmlFile -Encoding UTF8
        Register-ScheduledTask -TaskName $m.Name -Xml (Get-Content $xmlFile -Raw -Encoding UTF8) -Force | Out-Null
    }
    Write-WdacLog "已恢复启动项: $($m.Name)"
} elseif ($Action -eq 'list') {
    $list = @()
    Get-ChildItem $backupRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $mf = Join-Path $_.FullName 'manifest.json'
        if (Test-Path $mf) {
            try {
                $m = Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json
                $list += [pscustomobject]@{ BackupId = $_.Name; Time = $m.Time; Action = $m.Op; Type = $m.Type; Name = $m.Name; Command = $m.Command }
            } catch { }
        }
    }
    ConvertTo-Json -InputObject @($list | Sort-Object Time -Descending) -Depth 3 | Out-File (Join-Path $OutDir 'autostart-backups.json') -Encoding UTF8
    Write-WdacLog "备份列表: $($list.Count) 条"
}
