# install.ps1 - 部署 dsh-web 守护方案到本机
# 用法: powershell -ExecutionPolicy Bypass -File install.ps1 [-DshHome <目录>] [-Uninstall]
# 部署内容:
#   1. 复制 dsh-web.ps1 / dsh-web-watchdog.ps1 到 $DshHome(默认 ~\.dsh)
#   2. 注册计划任务 DSH-Web-Watchdog(登录时启动常驻看门狗,运行时长不限)
#   3. 创建启动文件夹 VBS(登录时后台启动服务)
#   4. 立即启动服务与看门狗

param(
    [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh'),
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$TaskName = 'DSH-Web-Watchdog'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $vbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'dsh-web-autostart.vbs'
    Remove-Item $vbs -Force -ErrorAction SilentlyContinue
    Write-Host "已卸载:$TaskName 计划任务与开机自启"
    exit 0
}

# 1) 复制脚本
New-Item -ItemType Directory -Path $DshHome -Force | Out-Null
Copy-Item (Join-Path $Here 'dsh-web.ps1') $DshHome -Force
Copy-Item (Join-Path $Here 'dsh-web-watchdog.ps1') $DshHome -Force
Copy-Item (Join-Path $Here 'dsh-web-notify.ps1') $DshHome -Force
Write-Host "脚本已复制到 $DshHome"

# 2) 计划任务:登录时启动常驻看门狗(ExecutionTimeLimit=PT0S 即不限时长)
$watchdog = Join-Path $DshHome 'dsh-web-watchdog.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdog`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
Set-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings
Enable-ScheduledTask -TaskName $TaskName
Write-Host "计划任务 $TaskName 已注册(登录时启动看门狗)"

# 3) 启动文件夹 VBS(开机自启服务)
$vbsPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'dsh-web-autostart.vbs'
$script = Join-Path $DshHome 'dsh-web.ps1'
$vbs = "' dsh-web autostart - runs hidden at logon`r`n" +
       "CreateObject(""Wscript.Shell"").Run ""powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$script"""" -Command start"", 0, False"
Set-Content -Path $vbsPath -Value $vbs -Encoding ASCII
Write-Host "开机自启已创建: $vbsPath"

# 4) 立即启动服务(同时会确保看门狗在跑)
& (Join-Path $DshHome 'dsh-web.ps1') -Command start
Write-Host '部署完成'
