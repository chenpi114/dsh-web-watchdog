# dsh-web.ps1 - DeepSeek Harness Web GUI 管理脚本
# 用法: powershell -File dsh-web.ps1 -Command <start|stop|restart|status|watchdog> [-Node ...] [-WorkDir ...] [-Port ...]
# start  : 若端口无服务则后台启动 dsh web(日志写入 dsh-web.out.log / .err.log,并写 restart 标记);清除 stop 标记;确保常驻看门狗在跑
# stop   : 结束占用端口的进程并写 stop 标记(看门狗之后不会自动重启,直到再次 start)
# restart: stop + start
# status : 显示当前进程/端口状态
# watchdog: 若端口无服务且无 stop 标记则 start;确保常驻看门狗在跑
# 常驻看门狗见 dsh-web-watchdog.ps1(事件驱动,无周期轮询开销)

param(
    [ValidateSet('start', 'stop', 'restart', 'status', 'watchdog')]
    [string]$Command = 'status',
    [string]$Node = '',                 # 空则自动探测 node.exe
    [string]$WorkDir = '',                 # 空则自动探测: 环境变量 DSH_WORKDIR → 脚本目录向上查找
    [int]$Port = 3080
)

$ErrorActionPreference = 'Stop'

$DshHome = $PSScriptRoot   # 脚本所在目录:日志/标记/看门狗都放这里
if (-not $Node) {
    $cand = @((Get-Command node.exe -ErrorAction SilentlyContinue).Source,
              "$env:LOCALAPPDATA\Programs\nodejs\node.exe",
              'C:\Program Files\nodejs\node.exe')
    $Node = $cand | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
# WorkDir 探测顺序: -WorkDir 参数 → 环境变量 DSH_WORKDIR → 脚本所在目录向上查找 dsh 仓库根(特征文件 apps\cli\src\bin.ts)
if (-not $WorkDir) { $WorkDir = $env:DSH_WORKDIR }
if (-not $WorkDir) {
    $dir = $PSScriptRoot
    while ($dir) {
        if (Test-Path (Join-Path $dir 'apps\cli\src\bin.ts')) { $WorkDir = $dir; break }
        $dir = Split-Path $dir -Parent
    }
}

$OutLog  = Join-Path $DshHome 'dsh-web.out.log'
$ErrLog  = Join-Path $DshHome 'dsh-web.err.log'
$Marker  = Join-Path $DshHome 'dsh-web.restart.marker'
$WatcherScript = Join-Path $DshHome 'dsh-web-watchdog.ps1'
$StoppedMarker = Join-Path $DshHome 'dsh-web.stopped.marker'

function Get-WebPid {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conn) { return ($conn | Select-Object -First 1).OwningProcess }
    return $null
}

function Start-Web {
    Remove-Item -Path $StoppedMarker -ErrorAction SilentlyContinue   # start 意图解除 stop 标记
    $old = Get-WebPid
    if ($old) {
        Write-Host "dsh web already running (PID $old on port $Port)"
        return
    }
    if (-not $Node) { throw '找不到 node.exe,请用 -Node 指定或加入 PATH' }
    if (-not $WorkDir) { throw '找不到 dsh 仓库根目录(apps\cli\src\bin.ts),请设置环境变量 DSH_WORKDIR 或用 -WorkDir 指定' }
    $p = Start-Process -FilePath $Node `
        -ArgumentList '--import', 'tsx/esm', 'apps/cli/src/bin.ts', 'web' `
        -WorkingDirectory $WorkDir -WindowStyle Hidden `
        -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog -PassThru
    $deadline = (Get-Date).AddSeconds(120)
    $new = $null
    do {
        Start-Sleep -Milliseconds 800
        $new = Get-WebPid
    } while (-not $new -and (Get-Date) -lt $deadline -and -not $p.HasExited)
    if (-not $new) {
        # 竞争场景：本实例启动失败（如 EADDRINUSE）但另一个实例已占住端口 → 视为成功
        $new = Get-WebPid
        if (-not $new) {
            $exit = if ($p.HasExited) { $p.ExitCode } else { 'n/a' }
            throw "dsh web failed to listen on port $Port within 120s (process exited: $($p.HasExited), exit code: $exit)"
        }
        Write-Host "dsh web already serving (PID $new, started by another instance)"
    }
    "restarted at $((Get-Date).ToString('o')) old=$old new=$new" | Set-Content -Path $Marker
    Write-Host "dsh web started (PID $new on port $Port)"
}

function Stop-Web {
    $pid0 = Get-WebPid
    if (-not $pid0) {
        Write-Host 'dsh web not running'
        return
    }
    Stop-Process -Id $pid0 -Force
    Write-Host "dsh web stopped (PID $pid0)"
}

function Show-Status {
    $pid0 = Get-WebPid
    if ($pid0) {
        $proc = Get-Process -Id $pid0 -ErrorAction SilentlyContinue
        $started = if ($proc) { $proc.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'n/a' }
        Write-Host "dsh web RUNNING (PID $pid0, port $Port, started $started)"
    } else {
        Write-Host 'dsh web NOT RUNNING'
    }
}

function Ensure-Watcher {
    $me = $PID
    $existing = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -match 'dsh-web-watchdog\.ps1' }
    if (-not $existing) {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatcherScript`" -Port $Port" `
            -WindowStyle Hidden | Out-Null
    }
}

switch ($Command) {
    'start'    { Start-Web; Ensure-Watcher }
    'stop'     {
        Stop-Web
        "stopped at $((Get-Date).ToString('o'))" | Set-Content -Path $StoppedMarker
    }
    'restart'  { Stop-Web; Start-Web; Ensure-Watcher }
    'status'   { Show-Status }
    'watchdog' {
        if (-not (Get-WebPid) -and -not (Test-Path $StoppedMarker)) {
            try { Start-Web | Out-Null; Write-Host 'watchdog: dsh web restarted' }
            catch { Write-Host "watchdog: start failed: $($_.Exception.Message)" }
        }
        Ensure-Watcher
    }
}
