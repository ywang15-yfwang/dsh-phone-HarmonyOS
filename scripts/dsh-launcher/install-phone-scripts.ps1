# 把「开启 / 关闭 / 关机」脚本装到**固定约定目录**，供手机 App 调用。
#
# 为什么：客户 2026-10-21 定的方案 A —— 手机端不再写死本机路径，
# 只发固定命令 `powershell -File "%LOCALAPPDATA%\dsh-phone\start.ps1"` 等。
# 这个脚本在**每台电脑上跑一次**（升级时再跑一次即可，会覆盖旧版本）。
#
# 点位（DSH_HOME / dsh 所在目录 / 工作目录）**装机时写进脚本**，源码里只有占位符 ——
# 机器相关值不进仓库，手机端也不需要知道。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File install-phone-scripts.ps1 `
#       -DshHome '<DSH_HOME>' -NpmBin '<npm bin>' -WorkDir '<workspace>'
param(
  [string]$TargetDir = (Join-Path $env:LOCALAPPDATA 'dsh-phone'),
  [string]$DshHome = $env:DSH_HOME,
  [string]$NpmBin = '',
  [string]$WorkDir = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($DshHome)) {
  Write-Output 'MISSING_DSH_HOME'
  exit 1
}
if ([string]::IsNullOrWhiteSpace($NpmBin)) {
  $cmd = Get-Command 'dsh.cmd' -ErrorAction SilentlyContinue
  if ($null -ne $cmd) {
    $NpmBin = Split-Path -Parent $cmd.Source
  }
}
if ([string]::IsNullOrWhiteSpace($NpmBin)) {
  Write-Output 'MISSING_NPM_BIN'
  exit 1
}

$map = @(
  @{ Src = 'launcher-command.ps1'; Dst = 'start.ps1';        Template = $true  },
  @{ Src = 'run-instance.ps1';     Dst = 'run-instance.ps1'; Template = $true  },
  @{ Src = 'repair-workspace.ps1'; Dst = 'repair-workspace.ps1'; Template = $true  },
  @{ Src = 'stop-command.ps1';     Dst = 'stop.ps1';         Template = $false },
  @{ Src = 'power-command.ps1';    Dst = 'power.ps1';        Template = $false }
)

if (-not (Test-Path $TargetDir)) {
  New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

foreach ($item in $map) {
  $src = Join-Path $here $item.Src
  if (-not (Test-Path $src)) {
    Write-Output "MISSING $($item.Src)"
    exit 1
  }
  $text = Get-Content -LiteralPath $src -Raw -Encoding UTF8
  if ($item.Template) {
    $text = $text.Replace('__DSH_HOME__', $DshHome).Replace('__NPM_BIN__', $NpmBin).Replace('__WORKDIR__', $WorkDir)
  }
  # BOM + UTF8：Windows PowerShell 5.1 读中文注释需要 BOM
  $out = Join-Path $TargetDir $item.Dst
  [IO.File]::WriteAllText($out, $text, (New-Object System.Text.UTF8Encoding($true)))
  Write-Output "INSTALLED $($item.Dst)"
}

# 自检：文件都在、没有残留占位符、大小打出来
$fail = $false
foreach ($name in @('start.ps1', 'run-instance.ps1', 'repair-workspace.ps1', 'stop.ps1', 'power.ps1')) {
  $p = Join-Path $TargetDir $name
  if (-not (Test-Path $p)) {
    Write-Output "VERIFY_FAIL $name missing"
    $fail = $true
    continue
  }
  $body = Get-Content -LiteralPath $p -Raw -Encoding UTF8
  if ($body.Contains('__DSH_HOME__') -or $body.Contains('__NPM_BIN__') -or $body.Contains('__WORKDIR__')) {
    Write-Output "VERIFY_FAIL $name placeholder"
    $fail = $true
    continue
  }
  $size = (Get-Item $p).Length
  $hash = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
  Write-Output "VERIFY_OK $name $size $hash"
}
if ($fail) {
  exit 1
}
Write-Output "DIR $TargetDir"
Write-Output "DONE"
