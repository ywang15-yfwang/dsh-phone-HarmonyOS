# add-phone-key.ps1 —— 把手机 App 的 SSH 公钥加进 Windows OpenSSH 的**管理员**授权文件。
#
# 为什么要这个文件（而不是 ~/.ssh/authorized_keys）：
#   sshd_config 里 AuthorizedKeysFile 指向 `C:\ProgramData\ssh\administrators_authorized_keys`，
#   且**没有 Match 块**（全局生效）；管理员组用户走的就是这个文件。
#
# 用法（**必须管理员**）：
#   powershell -ExecutionPolicy Bypass -File add-phone-key.ps1 -Key "ssh-ed25519 AAAA... dsh-phone"
#
# 语义：
#   · 同一把公钥（按 base64 主体判重）已存在 ⇒ 只报 EXISTS，不重复追加；
#   · 追加后统一修 ACL（只留 Administrators + SYSTEM，继承关掉）—— 这是 sshd 在
#     Windows 上默认的严格权限要求，权限过宽会直接拒绝登录。
#   · 幂等：反复跑不会写重复行。

param(
    [Parameter(Mandatory = $true)][string]$Key
)

$ErrorActionPreference = 'Stop'

$path = 'C:\ProgramData\ssh\administrators_authorized_keys'

$key = $Key.Trim()
if ($key.Length -eq 0) {
    Write-Output 'BAD_KEY'
    exit 2
}
# 只收公钥行：必须以 ssh- 开头
if (-not $key.StartsWith('ssh-')) {
    Write-Output 'BAD_KEY'
    exit 2
}

# 判重：比较第二段（base64 主体），注释不同也算同一把
$parts = $key -split '\s+'
$body = if ($parts.Length -ge 2) { $parts[1] } else { $key }

$exists = $false
if (Test-Path $path) {
    foreach ($line in (Get-Content -LiteralPath $path)) {
        $p = $line.Trim() -split '\s+'
        if ($p.Length -ge 2 -and $p[1] -eq $body) {
            $exists = $true
            break
        }
    }
}

if (-not $exists) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # 追加（用 \r\n，OpenSSH 解析不挑，但统一更稳）
    Add-Content -LiteralPath $path -Value $key -Encoding ascii
}

# ACL：关闭继承 + 只给 Administrators/SYSTEM（用 SID，避免系统语言差异）
& icacls $path /inheritance:r | Out-Null
& icacls $path /grant '*S-1-5-32-544:F' | Out-Null
& icacls $path /grant '*S-1-5-18:F' | Out-Null

if ($exists) {
    Write-Output 'EXISTS'
} else {
    Write-Output 'ADDED'
}
