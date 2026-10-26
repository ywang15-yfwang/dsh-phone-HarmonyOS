# 电脑端脚本

这些脚本让手机能远程启停电脑上的 dsh、把 SSH 收紧到只认公钥、以及让 Windows 开机自动登录。

## dsh-launcher

把脚本装到 `%LOCALAPPDATA%\dsh-phone\`，手机通过 SSH 调用。

```powershell
# 按你的实际路径传参（示例值请替换）
powershell -ExecutionPolicy Bypass -File install-phone-scripts.ps1 `
  -DshHome '<DSH_HOME>' -NpmBin '<npm 全局 bin 目录>' -WorkDir '<dsh 工作目录>'

# 注册通用计划任务（无触发器，交互身份）
powershell -ExecutionPolicy Bypass -File install-launch-task.ps1
```

装好后：

- `launcher-command.ps1 -Port <端口>`：手机发来的「开启」命令，按端口找实例并拉起 dsh；`-Port` 必填，没有默认端口；
- `stop-command.ps1 -Port <端口>`：关闭该端口的 dsh；
- `power-command.ps1`：关机（带确认/干跑参数见脚本头）；
- `repair-workspace.ps1 -DshHome <DSH_HOME>`：把 `workspace.json` 漏掉的会话补回来。

> 计划任务是**交互身份**：电脑必须已登录桌面，才会真的拉起 dsh。

## ssh-hardening

```powershell
# 把手机公钥加入管理员授权文件（会去重）
powershell -File add-phone-key.ps1 -Key 'ssh-ed25519 AAAA... dsh-phone'

# 关闭密码类登录，只留公钥（-Port 必填）
powershell -File disable-password-auth.ps1 -Port <sshd 端口> `
  -PhonePubKey '<手机公钥文件>' [-TestKeyPub '<测试公钥文件>']

# 防火墙只放行 tailnet + 回环（-Port 必填）
powershell -File restrict-ssh-firewall.ps1 -Port <sshd 端口>
```

脚本会先备份 `sshd_config` 和防火墙规则到本地 `_versions\` / `*.json`，可回滚。

## autologon

```powershell
powershell -File enable-autologon-checkbox.ps1
```

执行后打开 `netplwiz`，勾掉「要使用本计算机，用户必须输入用户名和密码」，按提示输入一次 Windows 密码。这样电脑开机后无需人工登录，计划任务才能把 dsh 拉起来。

> 只建议在可信的物理环境使用自动登录；需要更高安全性时，改为远程桌面登录后再由手机拉起 dsh。

