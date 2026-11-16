# autostart.ps1 - 扫描开机/登录启动项并检测变化（Autoruns 风格）
# 修复：扫描所有用户注册表（HKU，而非 SYSTEM 的 HKCU）；变化累积历史
. "$PSScriptRoot\wdac-common.ps1"
Initialize-WdacDirs

$items = @()

function Add-RunValue([string]$path, [string]$type, [string]$scope) {
    $props = Get-ItemProperty $path -ErrorAction SilentlyContinue
    if (-not $props) { return }
    foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -in 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') { continue }
        $cmd = [string]$p.Value
        if (-not $cmd) { continue }
        $exe = $null
        $m = [regex]::Match($cmd, '^\s*"([^"]+)"')
        if ($m.Success) {
            $exe = $m.Groups[1].Value
        } else {
            # 无引号命令（路径可能含空格）：去掉参数后取路径；逐步缩短寻找存在的文件
            $candidate = ($cmd -replace '\s+(-{1,2}|/)\S+.*$', '').Trim()
            if ($candidate -and (Test-Path $candidate -PathType Leaf)) {
                $exe = $candidate
            } else {
                $tokens = @($cmd -split '\s+')
                $exe = $tokens[0]
                for ($k = $tokens.Count; $k -ge 2; $k--) {
                    $probe = ($tokens[0..($k - 1)] -join ' ')
                    if (Test-Path $probe -PathType Leaf) { $exe = $probe; break }
                }
            }
        }
        $script:items += [pscustomobject]@{ Type = $type; Name = $p.Name; Command = $cmd; Exe = $exe; Source = $path; Scope = $scope }
    }
}

# 1. 注册表 Run / RunOnce（HKLM 64/32 位）
Add-RunValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' '注册表 Run' 'HKLM'
Add-RunValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' '注册表 RunOnce' 'HKLM'
Add-RunValue 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' '注册表 Run (32位)' 'HKLM'

# 2. 所有用户的 Run / RunOnce（HKU，SYSTEM 服务可读）
try {
    $hku = Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue
    foreach ($sid in $hku) {
        if ($sid.PSChildName -notmatch '^S-1-5-21-') { continue }
        foreach ($sub in @('Run', 'RunOnce')) {
            $path = 'Registry::HKEY_USERS\' + $sid.PSChildName + '\SOFTWARE\Microsoft\Windows\CurrentVersion\' + $sub
            Add-RunValue $path ('用户 ' + $sub) ('HKU\' + $sid.PSChildName)
        }
    }
} catch { }

# 3. 启动文件夹（所有用户 + 所有用户的 Startup）
$startupFolders = @()
$startupFolders += [Environment]::GetFolderPath('CommonStartup')
$startupFolders += [Environment]::GetFolderPath('Startup')
try {
    foreach ($u in (Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
        $s = Join-Path $u.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        if (Test-Path $s) { $startupFolders += $s }
    }
} catch { }
$startupFolders = @($startupFolders | Where-Object { $_ } | Select-Object -Unique)
foreach ($folder in $startupFolders) {
    Get-ChildItem $folder -File -ErrorAction SilentlyContinue | ForEach-Object {
        $items += [pscustomobject]@{ Type = '启动文件夹'; Name = $_.Name; Command = $_.FullName; Exe = $_.FullName; Source = $folder; Scope = 'User' }
    }
}

# 4. 登录/启动触发的计划任务
try {
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        ($_.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -match 'Boot|Logon'
    }
    foreach ($t in $tasks) {
        $action = $t.Actions | Select-Object -First 1
        $cmd = ''
        if ($action) { $cmd = [string]$action.Execute }
        if (-not $cmd) { continue }
        $items += [pscustomobject]@{ Type = '计划任务'; Name = $t.TaskName; Command = $cmd; Exe = $cmd; Source = 'TaskScheduler'; Scope = 'System' }
    }
} catch { }

# 5. Winlogon（Shell / Userinit）
try {
    $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    if ($wl.Shell) { $items += [pscustomobject]@{ Type = 'Winlogon Shell'; Name = 'Shell'; Command = [string]$wl.Shell; Exe = [string]$wl.Shell; Source = 'Winlogon'; Scope = 'System' } }
    if ($wl.Userinit) { $items += [pscustomobject]@{ Type = 'Winlogon Userinit'; Name = 'Userinit'; Command = [string]$wl.Userinit; Exe = [string]$wl.Userinit; Source = 'Winlogon'; Scope = 'System' } }
} catch { }

# 去重
$items = @($items | Sort-Object Type, Name -Unique)

# 统一检查签名/发布者（未知发布者告警）
foreach ($i in $items) {
    $exePath = [string]$i.Exe
    if (-not $exePath) { continue }
    $expanded = [Environment]::ExpandEnvironmentVariables(($exePath -replace '^"|"$', ''))
    if (Test-Path $expanded -PathType Leaf) {
        try {
            $sig = Get-AuthenticodeSignature $expanded -ErrorAction SilentlyContinue
            $valid = ($sig -and $sig.Status -eq 'Valid' -and $sig.SignerCertificate)
            $i | Add-Member -NotePropertyName Signed -NotePropertyValue ([bool]$valid) -Force
            $i | Add-Member -NotePropertyName Publisher -NotePropertyValue $(if ($valid) { $sig.SignerCertificate.Subject } else { $null }) -Force
            $i | Add-Member -NotePropertyName UnknownPublisher -NotePropertyValue (-not $valid) -Force
        } catch {
            $i | Add-Member -NotePropertyName Signed -NotePropertyValue $false -Force
            $i | Add-Member -NotePropertyName Publisher -NotePropertyValue $null -Force
            $i | Add-Member -NotePropertyName UnknownPublisher -NotePropertyValue $true -Force
        }
    } else {
        $i | Add-Member -NotePropertyName Signed -NotePropertyValue $false -Force
        $i | Add-Member -NotePropertyName Publisher -NotePropertyValue $null -Force
        $i | Add-Member -NotePropertyName UnknownPublisher -NotePropertyValue $true -Force
    }
}

# 与上次快照对比（新增/移除）
$snapshotFile = Join-Path $OutDir 'autostart.json'
$prev = @()
if (Test-Path $snapshotFile) {
    try {
        $d = ConvertFrom-Json -InputObject (Get-Content $snapshotFile -Raw -Encoding UTF8)
        $prev = @($d.Items)
    } catch { }
}
$prevKeys = @{}
foreach ($p in $prev) { $prevKeys[([string]$p.Type) + '|' + ([string]$p.Name) + '|' + ([string]$p.Command)] = $true }
$curKeys = @{}
$changes = @()
foreach ($i in $items) {
    $key = ([string]$i.Type) + '|' + ([string]$i.Name) + '|' + ([string]$i.Command)
    $curKeys[$key] = $true
    if (-not $prevKeys.ContainsKey($key)) {
        $changes += [pscustomobject]@{ Action = '新增'; Type = $i.Type; Name = $i.Name; Command = $i.Command }
    }
}
foreach ($p in $prev) {
    $key = ([string]$p.Type) + '|' + ([string]$p.Name) + '|' + ([string]$p.Command)
    if (-not $curKeys.ContainsKey($key)) {
        $changes += [pscustomobject]@{ Action = '移除'; Type = $p.Type; Name = $p.Name; Command = $p.Command }
    }
}

# 保存当前快照
$result = [pscustomobject]@{ Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Count = $items.Count; Items = $items }
$result | ConvertTo-Json -Depth 4 | Out-File $snapshotFile -Encoding UTF8

# 变化累积到历史（保留最近 200 条），不覆盖
$historyFile = Join-Path $OutDir 'autostart-history.json'
$history = @()
if (Test-Path $historyFile) {
    try {
        $rawH = Get-Content $historyFile -Raw -Encoding UTF8
        if ($rawH -and $rawH.Trim() -ne '[]') {
            $parsedH = ConvertFrom-Json -InputObject $rawH
            foreach ($h in $parsedH) { $history += $h }
        }
    } catch { }
}
$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
foreach ($ch in $changes) {
    $history += [pscustomobject]@{ Time = $now; Action = $ch.Action; Type = $ch.Type; Name = $ch.Name; Command = $ch.Command }
}
$history = @($history | Select-Object -Last 200)
ConvertTo-Json -InputObject @($history) -Depth 3 | Out-File $historyFile -Encoding UTF8

# 本次变化（供日志）
ConvertTo-Json -InputObject @($changes) -Depth 3 | Out-File (Join-Path $OutDir 'autostart-changes.json') -Encoding UTF8
Write-WdacLog "启动项扫描: $($items.Count) 项，本次变化 $($changes.Count) 项"
