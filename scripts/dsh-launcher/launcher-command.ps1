# launcher-command.ps1 —— 手机（SSH）发来的那条「开启 dsh」命令的**本体**。
#
# 语义（回执四句话，手机端按这个翻译）：
#   dsh 已在跑        → ALREADY
#   端口没配过实例    → FAILED_NO_INSTANCE（明确说"没有这个端口的实例"，绝不偷偷起别的）
#   起来并探到端口    → READY
#   等不到端口        → FAILED
#
# 端口从参数来：手机端**不写死端口**，带配置页里填的值 `-Port <端口>`。
# 这一份脚本管所有端口，不给某个实例单独写脚本。
#
# 「这个端口用哪套 dsh 配置」也不另建映射文件：每个 profile 的配对配置里本来就写着
# 它对应的 dsh 端口（`phonePort`）。脚本按端口认 profile，认不到就报"没配过"。
#
# 真正起 dsh 的是同目录的 run-instance.ps1，由**一个**通用计划任务（DshWebStart）
# 以交互身份调用 —— SSH 会话是服务会话，从那里直接起进程，桌面上看不到窗口。
param(
    [Parameter(Mandatory = $true)][int]$Port,
    [string]$DshHome = '__DSH_HOME__'
)

$ErrorActionPreference = 'SilentlyContinue'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskName = 'DshWebStart'
$requestFile = Join-Path $here 'launch-request.json'

function Test-Port([int]$p) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $p); return $true } catch { return $false } finally { $c.Dispose() }
}

if ($Port -lt 1 -or $Port -gt 65535) {
    Write-Output 'FAILED'
    exit 1
}

if (Test-Port $Port) {
    Write-Output 'ALREADY'
    exit 0
}

if ($null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
    Write-Output 'FAILED_NO_TASK'
    exit 1
}

# 找这个端口对应的 profile（只认配对配置里真正写着 phonePort 的那一行）
$profileName = ''
$profilesRoot = Join-Path $DshHome 'profiles'
foreach ($dir in @(Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction SilentlyContinue)) {
    $patch = Join-Path $dir.FullName 'cordis.patch.yml'
    if (-not (Test-Path -LiteralPath $patch)) { continue }
    $text = Get-Content -LiteralPath $patch -Raw -Encoding UTF8
    if ($text -match ('(?m)^\s*phonePort:\s*' + $Port + '\s*$')) {
        $profileName = $dir.Name
        break
    }
}
if ($profileName -eq '') {
    Write-Output 'FAILED_NO_INSTANCE'
    exit 1
}

# 把「端口 + 用哪套配置」交给通用任务；任务只读这一份请求
$request = @{ port = $Port; profile = $profileName } | ConvertTo-Json -Compress
Set-Content -LiteralPath $requestFile -Value $request -Encoding UTF8
Start-ScheduledTask -TaskName $taskName

# 最多等 90s（dsh 正常几秒就起；放宽只是保险）
for ($i = 0; $i -lt 180; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Port $Port) {
        Write-Output 'READY'
        exit 0
    }
}
Write-Output 'FAILED'
exit 1
