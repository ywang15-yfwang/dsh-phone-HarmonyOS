# repair-workspace.ps1 —— 修复 dsh 的会话分组（workspace.json 被另一个实例覆盖后漏掉的会话）。
#
# 背景：dsh 的 workspace 存储是"整份内存覆盖写"（single-unit，last-write-wins）。
# 同一份 DSH_HOME 下跑两个 dsh web 时，后写的那个会用自己内存里的旧列表把对方新建的会话冲掉，
# 于是会话在 UI 里掉进「未分组」。磁盘上的会话本身没丢，分组信息丢了。
#
# 修法：会话日志本来就按工作目录分目录存（`sessions/--D-DeepSeek--/<session-id>/`），
# 所以按 workspace 的 path 反推目录，把磁盘上存在、但 workspace 里没登记的会话补回去。
#
# 用法：
#   powershell -File repair-workspace.ps1 -DshHome '<DSH_HOME>'
# 语义：
#   · 只补"磁盘有、登记里没有、且不在 archived 里"的会话；不动已有顺序；
#   · 改前备份到 `_versions\` 并记 SHA256；无变化就什么都不写；
#   · 应在 dsh 实例**没在跑**的时候调用（run-instance.ps1 每次启动前会先跑一遍）。
param(
  [string]$DshHome = '__DSH_HOME__'
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$versions = Join-Path $here '_versions'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$ws = Join-Path $DshHome 'storages\workspace.json'
$sessionsRoot = Join-Path $DshHome 'sessions'

if (-not (Test-Path -LiteralPath $ws)) {
  Write-Output 'NO_WORKSPACE'
  exit 0
}

$doc = [IO.File]::ReadAllText($ws) | ConvertFrom-Json
$archived = @()
if ($doc.global -ne $null -and $doc.global.archivedSessionIds -ne $null) {
  $archived = @($doc.global.archivedSessionIds)
}

function ConvertTo-SessionDir([string]$path) {
  $s = $path.Trim()
  $s = $s -replace ':', ''
  $s = $s -replace '[\\/]', '-'
  return "--$s--"
}

$added = 0
foreach ($wid in @($doc.global.workspaceIds)) {
  $rec = $doc.tables.workspaces.$wid
  if ($rec -eq $null) { continue }
  $set = New-Object System.Collections.Generic.HashSet[string]
  foreach ($e in @($rec.sessionIds)) { [void]$set.Add([string]$e) }
  $dir = Join-Path $sessionsRoot (ConvertTo-SessionDir ([string]$rec.path))
  if (Test-Path -LiteralPath $dir) {
    $dirs = Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending
    foreach ($d in $dirs) {
      $sid = [string]$d.Name
      if (-not $sid.StartsWith('session-')) { continue }
      if ($archived -contains $sid) { continue }
      if (-not $set.Contains($sid)) {
        [void]$set.Add($sid)
        $added = $added + 1
      }
    }
  }
  $rec.sessionIds = @($set)
}

if ($added -eq 0) {
  Write-Output 'NO_CHANGE'
  exit 0
}

New-Item -ItemType Directory -Force -Path $versions | Out-Null
$backup = Join-Path $versions "workspace.json-$stamp"
Copy-Item -LiteralPath $ws -Destination $backup
$hash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash

$json = $doc | ConvertTo-Json -Depth 12
$tmp = "$ws.tmp-$stamp"
[IO.File]::WriteAllText($tmp, ($json + "`n"), (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tmp -Destination $ws -Force

Write-Output "ADDED=$added"
Write-Output "BACKUP=$backup"
Write-Output "SHA256=$hash"
