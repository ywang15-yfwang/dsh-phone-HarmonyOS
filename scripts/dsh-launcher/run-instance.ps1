# run-instance.ps1 —— **真正起 dsh** 的那一份脚本（全机只有这一份，不按实例分脚本）。
#
# 由计划任务 DshWebStart 以**交互身份**调用，所以窗口出现在你的桌面上：
#   · 窗口里就是 dsh 自己的输出（启动信息、带 token 的地址、报错）；
#   · 窗口正常大小，标题写着端口和 profile；
#   · 关掉窗口 = 停掉 dsh；手机上点「关闭」时窗口也会跟着退出。
#
# 手机点「开启」时，同目录的 launcher-command.ps1 先把 {port, profile} 写进
# launch-request.json，再触发任务；这里读它、起实例。
#
# 点位（dsh 装在哪、DSH_HOME 在哪、从哪个目录起）**在装机时替换**，源码里是占位符。
param(
    [switch]$DryRun,
    [string]$DshHome = '__DSH_HOME__',
    [string]$NpmBin = '__NPM_BIN__',
    [string]$WorkDir = '__WORKDIR__'
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$requestFile = Join-Path $here 'launch-request.json'
if (-not (Test-Path -LiteralPath $requestFile)) {
    Write-Output 'NO_REQUEST'
    exit 1
}

$request = Get-Content -LiteralPath $requestFile -Raw -Encoding UTF8 | ConvertFrom-Json
$port = [int]$request.port
$profile = [string]$request.profile
if ($port -lt 1 -or $port -gt 65535 -or $profile -eq '') {
    Write-Output 'BAD_REQUEST'
    exit 1
}

$env:DSH_HOME = $DshHome
$env:PATH = "$NpmBin;$env:PATH"
Set-Location -LiteralPath $WorkDir

# 启动前先把「会话分组」修一遍：同一个人家目录被多个实例写过时，workspace.json 会漏掉别人的会话
# （dsh 的 workspace 存储是整份内存覆盖写）。此时本实例端口还没起来，改文件不会和谁打架。
$repair = Join-Path $here 'repair-workspace.ps1'
if (Test-Path -LiteralPath $repair) {
    try {
        $repairOut = & $repair -DshHome $DshHome 2>&1
        if (($repairOut | Out-String).Trim() -ne 'NO_CHANGE') {
            Write-Output ("workspace 修复：" + (($repairOut | Out-String).Trim() -replace "`r?`n", ' | '))
        }
    } catch {
        Write-Output "workspace 修复跳过：$($_.Exception.Message)"
    }
}

$dshCmd = Join-Path $NpmBin 'dsh.cmd'
if ($DryRun) {
    Write-Output "DRYRUN dsh --profile $profile --port $port --no-open (DSH_HOME=$DshHome)"
    exit 0
}

try {
    $host.UI.RawUI.WindowTitle = "dsh $port ($profile) —— 关掉这个窗口即停止 dsh"
} catch {
    # 拿不到控制台标题就算了
}

$started = Get-Date
& $dshCmd --profile $profile --port $port --no-open
$code = $LASTEXITCODE
$alive = ((Get-Date) - $started).TotalSeconds

# 起不来（几秒内就退了）时把窗口留住，别让错误一闪而过；正常停掉就直接关窗
if ($alive -lt 10) {
    Write-Output ""
    Write-Output "dsh 已退出（退出码 $code，存活 $([int]$alive) 秒）。按回车关闭窗口。"
    try { [void](Read-Host) } catch { }
}
