# dsh-web-watchdog.ps1 - 常驻看门狗（事件驱动，无周期轮询开销）
# 由计划任务（登录时触发）或 dsh-web.ps1 的 start/watchdog 命令启动，进程常驻：
# - 服务在跑：阻塞等待其进程退出（WaitForExit，零 CPU 开销，不干扰游戏）
# - 服务不在：若未被显式 stop（存在 dsh-web.stopped.marker）则自动拉起
# 日志：dsh-web-watchdog.log

param(
    [int]$Port = 3080
)

$ErrorActionPreference = 'Stop'

$DshHome   = $PSScriptRoot
$DshWebPs1 = Join-Path $DshHome 'dsh-web.ps1'
$Log       = Join-Path $DshHome 'dsh-web-watchdog.log'
$StoppedMarker = Join-Path $DshHome 'dsh-web.stopped.marker'
$MutexName = "Local\dsh-web-watchdog-$Port"

# 单实例保护：命名互斥量，已有看门狗在跑时直接退出（防重复）
$mutex = New-Object System.Threading.Mutex($false, $MutexName)
if (-not $mutex.WaitOne(0)) { exit 0 }

function Log($msg) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Add-Content -Path $Log }

function Get-WebPid {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conn) { return ($conn | Select-Object -First 1).OwningProcess }
    return $null
}

Log 'watchdog started'
$fail = 0
while ($true) {
    $pid0 = Get-WebPid
    if (-not $pid0) {
        if (Test-Path $StoppedMarker) {
            Start-Sleep -Seconds 30   # 被显式 stop，等 start 解除标记
            continue
        }
        try {
            & $DshWebPs1 -Command start -Port $Port | Out-Null
        } catch {
            Log "start failed: $($_.Exception.Message)"
        }
        $pid0 = Get-WebPid
        if (-not $pid0) {
            $fail++
            Log "port $Port still down (failure #$fail)"
            Start-Sleep -Seconds ([Math]::Min(120, 15 * $fail))   # 失败退避：15s 起，上限 120s
            continue
        }
        Log "service restarted (PID $pid0)"
        $fail = 0
        # 恢复通知(独立进程, 不阻塞看门狗): 托盘气泡, 点击打开 GUI 并深链回到最新会话
        $notify = Join-Path $DshHome 'dsh-web-notify.ps1'
        if (Test-Path $notify) {
            try {
                Start-Process -FilePath 'powershell.exe' `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$notify`" -Port $Port -NewPid $pid0" `
                    -WindowStyle Hidden | Out-Null
            } catch {
                Log "notify failed: $($_.Exception.Message)"
            }
        }
    }
    try {
        $proc = Get-Process -Id $pid0 -ErrorAction Stop
        Log "watching service PID $pid0"
        $proc.WaitForExit()
        Log "service process exited (PID $pid0)"
    } catch {
        Start-Sleep -Seconds 3
    }
    Start-Sleep -Seconds 2
}
