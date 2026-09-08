<#
.SYNOPSIS
    注册/卸载「联通加装包 5G 上网服务方案监控」Windows 计划任务（每 12 小时一次）

.DESCRIPTION
    默认注册两个每天触发的任务：08:00 和 20:00，即每 12 小时运行一次。
    任务调用同目录下的 run-monitor.cmd。

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

if (-not (Test-Path $Launcher)) { throw ('找不到运行入口：' + $Launcher) }

$action = New-ScheduledTaskAction -Execute $Launcher -WorkingDirectory $Root
$t1 = New-ScheduledTaskTrigger -Daily -At $Time1
$t2 = New-ScheduledTaskTrigger -Daily -At $Time2
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
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

Write-Host ''
Write-Host ('计划任务已注册：' + $TaskName) -ForegroundColor Green
Write-Host ('  触发时间：每天 ' + $Time1 + ' 和 ' + $Time2 + '（每 12 小时一次）')
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
    Write-Host '立即运行一次...' -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 5
    Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo |
        Format-List TaskName, LastRunTime, LastTaskResult, NextRunTime
}
