<#
.SYNOPSIS
    注册/卸载「联通加装包 5G 上网服务方案监控」Windows 计划任务（每 12 小时一次）

.DESCRIPTION
    默认注册一个每天触发两次的任务：08:00 和 20:00（一个任务、两个触发器），即每 12 小时运行一次。
    任务调用同目录下的 run-monitor.cmd，并以 S4U 方式注册（注销后也会运行、不弹控制台窗口）。

.PARAMETER Remove
    卸载计划任务

.PARAMETER RunNow
    注册完成后立即运行一次

.PARAMETER Time1
    第一次触发时间，默认 08:00

.PARAMETER Time2
    第二次触发时间，默认 20:00

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-task.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-task.ps1 -RunNow
    powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-task.ps1 -Remove
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$RunNow,
    [string]$Time1 = '08:00',
    [string]$Time2 = '20:00'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$TaskName = 'UnicomPlanMonitor'
$Root     = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Launcher = Join-Path $Root 'run-monitor.cmd'

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host ('已卸载计划任务：' + $TaskName) -ForegroundColor Green
    } else {
        Write-Host ('计划任务不存在：' + $TaskName) -ForegroundColor Yellow
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $Launcher)) { throw ('找不到运行入口：' + $Launcher) }

# 时间参数校验：写错时给一句人话，而不是原始的类型转换异常；
# 顺带避免 Time1 与 Time2 相同（那样一天只会跑一次，却还在输出里说"每 12 小时"）
foreach ($tv in @(@('Time1', $Time1), @('Time2', $Time2))) {
    if ($tv[1] -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
        throw ('时间格式必须是 HH:mm（24 小时制），例如 08:00 / 20:30；收到 ' + $tv[0] + '=' + $tv[1])
    }
}
if ($Time1 -eq $Time2) { throw ('Time1 与 Time2 不能相同（当前都是 ' + $Time1 + '），否则一天只会运行一次') }

$action = New-ScheduledTaskAction -Execute $Launcher -WorkingDirectory $Root
$t1 = New-ScheduledTaskTrigger -Daily -At $Time1
$t2 = New-ScheduledTaskTrigger -Daily -At $Time2
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -WakeToRun `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -MultipleInstances IgnoreNew

# 默认（不指定 principal）注册出来的是「只使用交互方式」：注销 / 未登录时任务根本不会运行，
# 而且会在桌面弹出控制台窗口。这里显式用 S4U（不需要保存密码，注销后也能跑）。
# S4U 注册通常需要管理员权限，失败则回退到交互式并给出提示。
$principal = $null
try {
    $principal = New-ScheduledTaskPrincipal -UserId ("$env:USERDOMAIN\$env:USERNAME") -LogonType S4U -RunLevel Limited
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger @($t1, $t2) `
        -Settings $settings `
        -Principal $principal `
        -Description '监控中国联通资费专区「加装包」中含 5G上网服务/5G-A上网服务（下行峰值…）的方案，并筛选智慧沃家共享版用户可订购的方案。' `
        -Force | Out-Null
} catch {
    Write-Host ('以 S4U 注册失败（' + $_.Exception.Message + '），改用「只在用户登录时运行」方式注册。') -ForegroundColor Yellow
    Write-Host '  提示：注销 / 未登录时该任务不会运行；想让它无人值守运行，请用管理员身份重新执行本脚本。' -ForegroundColor Yellow
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -WakeToRun `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger @($t1, $t2) `
        -Settings $settings `
        -Description '监控中国联通资费专区「加装包」中含 5G上网服务/5G-A上网服务（下行峰值…）的方案，并筛选智慧沃家共享版用户可订购的方案。' `
        -Force | Out-Null
}

# 两次触发之间的真实间隔（不再硬编码「每 12 小时一次」）
$span = [TimeSpan]::Parse($Time2) - [TimeSpan]::Parse($Time1)
if ($span.TotalHours -lt 0) { $span = $span.Add([TimeSpan]::FromHours(24)) }

Write-Host ''
Write-Host ('计划任务已注册：' + $TaskName) -ForegroundColor Green
Write-Host ('  触发时间：每天 ' + $Time1 + ' 和 ' + $Time2 + '（间隔 ' + $span.TotalHours + ' 小时）')
Write-Host ('  运行身份：' + (Get-ScheduledTask -TaskName $TaskName).Principal.LogonType + '（S4U=注销后也会运行，无控制台窗口）')
Write-Host ('  执行命令：' + $Launcher)
Write-Host ('  结果目录：' + (Join-Path $Root 'output'))
Write-Host ''
Write-Host '查看任务：' -ForegroundColor Cyan
Write-Host ('  Get-ScheduledTask -TaskName ' + $TaskName + ' | Get-ScheduledTaskInfo')
Write-Host '立即运行一次：' -ForegroundColor Cyan
Write-Host ('  Start-ScheduledTask -TaskName ' + $TaskName)
Write-Host '卸载任务：' -ForegroundColor Cyan
Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-task.ps1 -Remove'
Write-Host ''

if ($RunNow) {
    Write-Host '立即运行一次（等它跑完再看结果）...' -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $TaskName
    # 监控一次要跑十几秒到几十秒，原来只等 5 秒就打印，看到的是 267009（= 任务仍在运行）
    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 2
        $task = Get-ScheduledTask -TaskName $TaskName
        $info = $task | Get-ScheduledTaskInfo
    } while ($task.State -eq 'Running' -and (Get-Date) -lt $deadline)
    $info | Format-List TaskName, LastRunTime, LastTaskResult, NextRunTime
    if ($info.LastTaskResult -eq 0) {
        Write-Host '√ 运行成功（LastTaskResult = 0），报告见 output\latest\summary.txt' -ForegroundColor Green
    } elseif ($info.LastTaskResult -eq 267009) {
        Write-Host '任务仍在运行（LastTaskResult = 267009），稍后再看 output\latest\summary.txt' -ForegroundColor Yellow
    } else {
        Write-Host ('× 运行失败，LastTaskResult = 0x{0:X}（十进制 {1}），详见 output\logs' -f $info.LastTaskResult, $info.LastTaskResult) -ForegroundColor Red
    }
}
