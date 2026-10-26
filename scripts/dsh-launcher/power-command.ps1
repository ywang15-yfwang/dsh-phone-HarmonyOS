# power-command.ps1 —— 手机上点「关机」时跑的固定命令。
#
# 语义（和启停脚本同一套规矩）：
#   正常  → 立刻回 SHUTTING_DOWN，然后按 -DelaySeconds 倒计时真正关机（默认 10 秒）
#   干跑  → 回 WOULD_SHUTDOWN，什么都不做（本机自测用）
#
# 为什么延迟：SSH 这条连接是**本进程**跑出来的，命令一返回连接就断；
# 立刻关机可能连回执都发不出去，手机端就会显示"失败"（其实成功了）。
# 给 10 秒：手机先拿到 SHUTTING_DOWN，电脑再断电。
#
# ⚠️ 关机会让电脑上所有会话（包括 dsh web 本身）一起断 —— 这是客户要的效果，
#    但调试时**务必用 -DryRun**，别把自己正在用的机器关掉。

param(
    [int]$DelaySeconds = 10,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if ($DryRun) {
    Write-Output 'WOULD_SHUTDOWN'
    exit 0
}

if ($DelaySeconds -lt 0) {
    $DelaySeconds = 0
}

# /s 关机 /t 倒计时（秒）/f 强制关掉阻塞的应用（不 /f 会被"是否保存"卡住）
$proc = Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" `
    -ArgumentList "/s /t $DelaySeconds /f" -WindowStyle Hidden -PassThru -Wait
if ($proc.ExitCode -ne 0) {
    Write-Output "FAILED:$($proc.ExitCode)"
    exit 1
}

Write-Output 'SHUTTING_DOWN'
exit 0
