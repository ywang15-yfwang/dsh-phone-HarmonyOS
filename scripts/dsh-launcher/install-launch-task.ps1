# install-launch-task.ps1 —— 注册**唯一一个**通用启动任务 `DshWebStart`。
#
# 为什么要有这个任务：
#   手机通过 SSH（服务会话）发命令，从那里直接起进程，桌面上**看不到窗口**；
#   任务以你的交互身份运行，窗口才会出现在你的桌面。
#
# 为什么只有一个：
#   任务的动作固定，带不了手机传来的端口 —— 所以动作只写"跑 run-instance.ps1"，
#   端口和用哪套 profile 由 start.ps1 写进请求文件。新增实例**不需要**再建任务。
#
# 特性：无触发器（不会自己跑）、可手动启动、IgnoreNew（已在启动中就不叠第二个）、不限运行时长。
# 幂等：重复跑覆盖同名任务；旧定义先导出到 `_versions\` 备份。
param(
  [string]$TargetDir = (Join-Path $env:LOCALAPPDATA 'dsh-phone')
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$versions = Join-Path $here '_versions'
New-Item -ItemType Directory -Force -Path $versions | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$taskName = 'DshWebStart'
$script = Join-Path $TargetDir 'run-instance.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $script)) {
  Write-Output 'MISSING_RUN_SCRIPT'
  exit 1
}
if (-not (Test-Path -LiteralPath $powershell)) {
  Write-Output 'MISSING_POWERSHELL'
  exit 1
}

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $existing) {
  $xml = Export-ScheduledTask -TaskName $taskName
  $backup = Join-Path $versions "$taskName-$stamp.xml"
  Set-Content -LiteralPath $backup -Value $xml -Encoding UTF8
  $hash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
  "BACKUP=$backup`nSHA256=$hash" | Set-Content -LiteralPath (Join-Path $versions "$taskName-$stamp.log") -Encoding UTF8
}

$action = New-ScheduledTaskAction -Execute $powershell -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $script + '"')
$settings = New-ScheduledTaskSettingsSet `
  -MultipleInstances Parallel `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal `
  -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
  -LogonType Interactive `
  -RunLevel Limited

Register-ScheduledTask -TaskName $taskName `
  -Action $action -Settings $settings -Principal $principal `
  -Description '手机开启 dsh 用：一个通用任务，按请求文件里的端口/profile 起实例；无触发器，手动运行。' `
  -Force | Out-Null

$after = Get-ScheduledTask -TaskName $taskName
$xmlAfter = Export-ScheduledTask -TaskName $taskName
$triggerCount = @(([xml]$xmlAfter).Task.Triggers.ChildNodes | Where-Object { $_.NodeType -eq 'Element' }).Count
"TASK=$taskName"
"TRIGGERS=$triggerCount"
"STATE=$($after.State)"
"ACTION=$($after.Actions[0].Execute) $($after.Actions[0].Arguments)"
Write-Output 'DONE'
