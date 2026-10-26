param(
    [Parameter(Mandatory = $true)][string]$KeyFile,
    [Parameter(Mandatory = $true)][string]$ResultFile
)

$ErrorActionPreference = 'Stop'
$result = @{ ok = $false; error = 'unknown' }

try {
    $key = (Get-Content -LiteralPath $KeyFile -Raw -Encoding UTF8).Trim()
    if ($key -notmatch '^ssh-(ed25519|rsa)\s+[A-Za-z0-9+/=]+') { throw 'bad-key' }
    $target = 'C:\ProgramData\ssh\administrators_authorized_keys'
    $body = ($key -split '\s+')[1]
    $exists = $false
    if (Test-Path -LiteralPath $target) {
        foreach ($line in (Get-Content -LiteralPath $target)) {
            $parts = $line.Trim() -split '\s+'
            if ($parts.Length -ge 2 -and $parts[1] -eq $body) { $exists = $true; break }
        }
    }
    if (-not $exists) {
        Add-Content -LiteralPath $target -Value $key -Encoding ascii
    }
    & icacls $target /inheritance:r | Out-Null
    & icacls $target /grant '*S-1-5-32-544:F' | Out-Null
    & icacls $target /grant '*S-1-5-18:F' | Out-Null
    $result = @{ ok = $true; added = (-not $exists) }
} catch {
    $result = @{ ok = $false; error = $_.Exception.Message }
}

$result | ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultFile -Encoding UTF8
