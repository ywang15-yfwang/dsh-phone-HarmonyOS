# enable-autologon-checkbox.ps1 —— 让 netplwiz 的「要使用本计算机，用户必须输入用户名和密码」勾选框重新出现。
#
# 背景：Windows 11 的密码免输入（passwordless）策略把这个勾选框藏了：
#   HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device\DevicePasswordLessBuildVersion = 2
# 改成 0 后，重新打开 netplwiz 就能看到勾选框；勾掉并输入一次密码，Windows 自己保存自动登录凭据。
#
# 只改这一个值；不改 Winlogon、不写任何密码。必须管理员。
$ErrorActionPreference = 'Stop'
$path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
if (-not (Test-Path $path)) {
    New-Item -Path $path -Force | Out-Null
}
$old = $null
try { $old = (Get-ItemProperty -Path $path -Name DevicePasswordLessBuildVersion -ErrorAction Stop).DevicePasswordLessBuildVersion } catch { }
Set-ItemProperty -Path $path -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
$new = (Get-ItemProperty -Path $path -Name DevicePasswordLessBuildVersion).DevicePasswordLessBuildVersion
"OLD=$old"
"NEW=$new"
