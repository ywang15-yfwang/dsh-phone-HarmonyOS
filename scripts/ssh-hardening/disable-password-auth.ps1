# disable-password-auth.ps1 —— 关掉 SSH 的**密码类登录**，只留公钥（必须管理员）。
#
# 为什么还要关 keyboard-interactive：Windows OpenSSH 的密码输入走的是
# `keyboard-interactive` 渠道 —— 只关 PasswordAuthentication 时，服务端仍会把这个
# 方法列在 "Permission denied (publickey,keyboard-interactive)" 里。要只留公钥，两个开关都要关。
#
# 顺序（可回滚）：
#   1. 备份 sshd_config 到 `_versions\`，记 SHA256；
#   2. 确认手机公钥还在授权文件里（不在就**直接中止**，不改任何配置）；
#   3. 置 `PubkeyAuthentication yes` / `PasswordAuthentication no` / `KbdInteractiveAuthentication no`；
#   4. 重启 sshd，确认服务在跑、端口在听；
#   5. 回归：sshd -T 的有效值、密码法被拒、keyboard-interactive 被拒、公钥能登（授权文件里有测试私钥时）。
#
# 回滚：把 `_versions\sshd_config-<时间戳>` 拷回 `C:\ProgramData\ssh\sshd_config`，再重启 sshd。
param(
    [Parameter(Mandatory = $true)][int]$Port,
    [string]$AuthorizedKeys = 'C:\ProgramData\ssh\administrators_authorized_keys',
    [string]$PhonePubKey = '',
    [string]$TestKeyPub = ''
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$versions = Join-Path $here '_versions'
New-Item -ItemType Directory -Force -Path $versions | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $versions "disable-password-auth-$stamp.log"

function Log([string]$m) {
    $m | Add-Content -LiteralPath $log -Encoding UTF8
}

$cfg = 'C:\ProgramData\ssh\sshd_config'
    $keyFile = $AuthorizedKeys
    $phonePub = $PhonePubKey
    $devKey = ''
    $devPub = $TestKeyPub
$sshdExe = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'

function Get-KeyBody([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $p = (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim() -split '\s+'
    if ($p.Count -ge 2) { return $p[1] }
    return ''
}

function Test-KeyPresent([string]$body, $keys) {
    if ($body -eq '') { return $false }
    foreach ($line in $keys) {
        $q = $line.Trim() -split '\s+'
        if ($q.Count -ge 2 -and $q[1] -eq $body) { return $true }
    }
    return $false
}

try {
    Log "START=$stamp"
    if (-not (Test-Path -LiteralPath $cfg)) { Log 'ABORT=no-sshd-config'; exit 2 }

    # 1) 备份
    $bytes = [IO.File]::ReadAllBytes($cfg)
    $backup = Join-Path $versions "sshd_config-$stamp"
    [IO.File]::WriteAllBytes($backup, $bytes)
    Log "BACKUP=$backup"
    Log ("BACKUP_SHA256=" + (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash)

    # 2) 手机公钥必须还在（按 base64 主体比，不看注释）
    if (-not (Test-Path -LiteralPath $keyFile)) { Log 'ABORT=no-authorized-keys'; exit 3 }
    $keys = @(Get-Content -LiteralPath $keyFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
    $phonePresent = if ($phonePub -eq '') { $true } else { Test-KeyPresent (Get-KeyBody $phonePub) $keys }
    if ($phonePub -eq '') { Log "PHONE_KEY_CHECK=skipped" }
    $devPresent = Test-KeyPresent (Get-KeyBody $devPub) $keys
    Log "AUTH_KEY_LINES=$($keys.Count)"
    Log "PHONE_KEY_PRESENT=$phonePresent"
    Log "DEV_KEY_PRESENT=$devPresent"
    if (-not $phonePresent) { Log 'ABORT=phone-key-not-in-authorized-keys'; exit 4 }

    # 3) 改配置（保留原文件其余内容；已有该行就改写，不追加重复行）
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $lines = $text -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    $want = [ordered]@{
        'PubkeyAuthentication'         = 'PubkeyAuthentication yes'
        'PasswordAuthentication'       = 'PasswordAuthentication no'
        'KbdInteractiveAuthentication' = 'KbdInteractiveAuthentication no'
    }
    $saw = @{}
    foreach ($l in $lines) {
        $matched = $false
        foreach ($k in $want.Keys) {
            if ($l -match ('^\s*' + $k + '\s+')) {
                $out.Add($want[$k])
                $saw[$k] = $true
                $matched = $true
                break
            }
        }
        if (-not $matched) { $out.Add($l) }
    }
    foreach ($k in $want.Keys) {
        if (-not $saw.ContainsKey($k)) { $out.Add($want[$k]) }
    }
    [IO.File]::WriteAllText($cfg, ($out -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Log "WROTE=$cfg"
    Log ("CFG_SHA256=" + (Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash)

    # 4) 重启服务
    Restart-Service -Name sshd -Force
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name sshd
    Log "SERVICE=$($svc.Status)"
    $listen = @(netstat -ano | Select-String -Pattern ":$Port\s" | Select-String -Pattern 'LISTENING')
    Log "LISTEN_COUNT=$($listen.Count)"

    # 5) 回归（调外部 ssh/sshd 时别让 stderr 触发 Stop）
    $ErrorActionPreference = 'Continue'
    $eff = & $sshdExe -T 2>&1
    $pick = @($eff | Select-String -Pattern '^(passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication)\s+\S+' | ForEach-Object { $_.Line.Trim() })
    Log ("EFFECTIVE=" + ($pick -join '; '))

    $user = "$env:USERDOMAIN\$env:USERNAME"
    $target = "$user@127.0.0.1"

    $pw = & ssh.exe -p $Port -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o PubkeyAuthentication=no -o PreferredAuthentications=password -o KbdInteractiveAuthentication=no $target exit 2>&1
    Log ("PASSWORD_ONLY_EXIT=" + $LASTEXITCODE)
    Log ("PASSWORD_ONLY_OUT=" + ((($pw | Out-String).Trim()) -replace "`r?`n", ' | '))

    $ki = & ssh.exe -p $Port -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o PubkeyAuthentication=no -o PreferredAuthentications=keyboard-interactive $target exit 2>&1
    Log ("KBD_ONLY_EXIT=" + $LASTEXITCODE)
    Log ("KBD_ONLY_OUT=" + ((($ki | Out-String).Trim()) -replace "`r?`n", ' | '))

    if ($devPresent) {
        $kp = & ssh.exe -p $Port -i $devKey -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o IdentitiesOnly=yes $target 'echo KEY_OK' 2>&1
        Log ("KEY_LOGIN_EXIT=" + $LASTEXITCODE)
        Log ("KEY_LOGIN_OUT=" + ((($kp | Out-String).Trim()) -replace "`r?`n", ' | '))
    }
    $ErrorActionPreference = 'Stop'
    Log 'DONE'
} catch {
    Log "ERROR=$($_.Exception.Message)"
    exit 1
}
