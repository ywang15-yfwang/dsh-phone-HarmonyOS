param(
    [Parameter(Mandatory = $true)][int]$Port
)

$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $dir "restrict-ssh-$stamp.log"
$backup = Join-Path $dir "ssh-firewall-backup-$stamp.json"

function Write-Log([string]$line) {
    $line | Tee-Object -FilePath $log -Append | Out-Host
}

$rules = @(Get-NetFirewallRule -Direction Inbound | Where-Object {
    $ports = @((Get-NetFirewallPortFilter -AssociatedNetFirewallRule $_).LocalPort)
    $ports -contains [string]$Port
})
if ($rules.Count -eq 0) {
    Write-Log 'NO_RULE_FOUND'
    exit 1
}

$snapshot = foreach ($rule in $rules) {
    $af = $rule | Get-NetFirewallAddressFilter
    [pscustomobject]@{
        Name = $rule.Name
        DisplayName = $rule.DisplayName
        Enabled = [string]$rule.Enabled
        Profile = [string]$rule.Profile
        RemoteAddress = @($af.RemoteAddress)
    }
}
$snapshot | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backup -Encoding UTF8
Write-Log "BACKUP=$backup"

$allowed = @('100.64.0.0/10', '127.0.0.1')
foreach ($rule in $rules) {
    try {
        Set-NetFirewallRule -Name $rule.Name -RemoteAddress $allowed -ErrorAction Stop
        Write-Log "UPDATED=$($rule.Name)"
    } catch {
        Write-Log "ERROR=$($rule.Name) $($_.Exception.Message)"
    }
}

$after = Get-NetFirewallRule -Direction Inbound | Where-Object {
    $ports = @((Get-NetFirewallPortFilter -AssociatedNetFirewallRule $_).LocalPort)
    $ports -contains [string]$Port
} | ForEach-Object {
    $af = $_ | Get-NetFirewallAddressFilter
    [pscustomobject]@{
        DisplayName = $_.DisplayName
        Enabled = [string]$_.Enabled
        Profile = [string]$_.Profile
        RemoteAddress = (@($af.RemoteAddress) -join ',')
    }
}
$after | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_ }
Write-Log 'DONE'
