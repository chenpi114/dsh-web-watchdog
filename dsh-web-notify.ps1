# dsh-web-notify.ps1 - 服务自动恢复通知(独立隐藏进程, 不阻塞看门狗)
# 由看门狗在服务恢复后调用: 显示托盘气球通知, 点击后打开 GUI 并自动回到最新会话
# 用法: powershell -File dsh-web-notify.ps1 [-Port 3080] [-NewPid 0] [-IconPath ""]

param(
    [int]$Port = 3080,
    [int]$NewPid = 0,
    [string]$IconPath = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 恢复后的深链: 找最新会话目录(按最后修改时间), 拼到 URL 上, 让 GUI 自动打开之前的对话
$url = "http://127.0.0.1:$Port"
$sessionsRoot = Join-Path $env:USERPROFILE '.dsh\sessions'
try {
    $latest = Get-ChildItem $sessionsRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { $url = "http://127.0.0.1:$Port/?session=$($latest.Name)" }
} catch { }

$time = Get-Date -Format 'HH:mm:ss'
$n = New-Object System.Windows.Forms.NotifyIcon
try {
    if (-not $IconPath) {
        $IconPath = @((Join-Path $PSScriptRoot 'deepseek-harness.ico')) |
            Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if ($IconPath -and (Test-Path $IconPath)) {
        $n.Icon = New-Object System.Drawing.Icon($IconPath)
    } else {
        $n.Icon = [System.Drawing.SystemIcons]::Information
    }
} catch {
    try { $n.Icon = [System.Drawing.SystemIcons]::Information } catch { }
}
$n.Visible = $true
$n.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
$n.BalloonTipTitle = 'DeepSeek Harness 已自动恢复'
$n.BalloonTipText = "服务已在 $time 重新启动 (PID $NewPid)`n点击打开并继续之前的对话"
$script:opened = $false
$n.Add_BalloonTipClicked({
    $script:opened = $true
    Start-Process $url
    $n.Visible = $false
    $n.Dispose()
})
$n.Add_BalloonTipClosed({
    $n.Visible = $false
    $n.Dispose()
})
$n.ShowBalloonTip(20000)
# 事件泵: 等待点击/关闭或超时(30 秒)
$deadline = (Get-Date).AddSeconds(30)
while (-not $script:opened -and (Get-Date) -lt $deadline) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 100
}
try { $n.Visible = $false; $n.Dispose() } catch { }
