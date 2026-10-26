# stop-command.ps1 —— 手机上点「关闭」时跑的固定命令（`launcher-command.ps1` 的镜像）。
#
# 语义（和启动脚本对齐，三句话）：
#   dsh 没在跑      → 立刻回 ALREADY_STOPPED，不动任何东西
#   dsh 在跑        → 杀掉监听该端口的那个进程（连子进程），等端口释放，回 STOPPED
#   杀了 10s 还在   → 回 FAILED（不假装成功）
#
# 为什么要杀进程而不是 `Stop-ScheduledTask`：计划任务里跑的是 wscript → cmd → node，
# 停任务并不会把已经跑起来的 node 收掉；真正占端口的是那个 node。
#
# ⚠️ 两条纪律：
#   ① 判"在不在跑"用 **TCP 实连**，不用 `Get-NetTCPConnection`（本机 CIM 受限时它会谎报没监听）；
#   ② 只杀**监听这个端口的那个 PID**，不按进程名杀（这台机器上还有别的 node）。

param(
    [Parameter(Mandatory = $true)][int]$Port
)

$ErrorActionPreference = 'SilentlyContinue'

function Test-Port([int]$p) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $p); return $true } catch { return $false } finally { $c.Dispose() }
}

if (-not (Test-Port $Port)) {
    Write-Output 'ALREADY_STOPPED'
    exit 0
}

# 从 netstat 取属主 PID（只认 LISTENING，且端口要精确匹配，避免 :<端口> 命中 :<端口>1）
$pids = @()
foreach ($line in (netstat -ano | Select-String -Pattern ":$Port\s" | Select-String -Pattern 'LISTENING')) {
    $cols = @($line.ToString().Trim() -split '\s+')
    if ($cols.Count -ge 5) {
        $owner = 0
        [int]::TryParse($cols[$cols.Count - 1], [ref]$owner) | Out-Null
        if ($owner -gt 0 -and $pids -notcontains $owner) {
            $pids += $owner
        }
    }
}

if ($pids.Count -eq 0) {
    # 端口回话但查不到属主（权限/时序）⇒ 如实失败，不猜
    Write-Output 'FAILED'
    exit 1
}

foreach ($procId in $pids) {
    # /T 连子进程一起收；/F 强制（node 不一定理会正常退出）
    & taskkill /PID $procId /T /F *> $null
}

# 最多等 10s 让端口真正释放（杀掉和端口释放之间有几百毫秒的窗口）
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    if (-not (Test-Port $Port)) {
        Write-Output 'STOPPED'
        exit 0
    }
}

Write-Output 'FAILED'
exit 1
