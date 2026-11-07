# netmon seed — публикация пакета
# Копирует свежий клиент в public\, считает SHA-256, пишет manifest.json,
# коммитит изменения и (с -Push) отправляет в GitHub.
#
#   .\publish.ps1 -Version 2.3.1
#   .\publish.ps1 -Version 2.3.1 -Push
param(
    [string]$Version = '',
    [string]$Source = '..\tools\netmon_cpp\netmon.exe',
    [string]$Remote = 'origin',
    [string]$Branch = 'main',
    [switch]$Push
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$public = Join-Path $root 'public'

if (-not $Version) {
    # версию берём из самого клиента
    $exe = Join-Path $root $Source
    if (Test-Path $exe) {
        $out = & $exe --cli self 2>&1 | Out-String
        if ($out -match 'версия\s*:\s*([0-9]+\.[0-9]+\.[0-9]+)') { $Version = $Matches[1] }
    }
    if (-not $Version) { throw 'укажите -Version x.y.z' }
}

$srcExe = Resolve-Path (Join-Path $root $Source)
New-Item -ItemType Directory -Path $public -Force | Out-Null
$dstExe = Join-Path $public 'netmon.exe'
Copy-Item -LiteralPath $srcExe -Destination $dstExe -Force

$hash = (Get-FileHash -LiteralPath $dstExe -Algorithm SHA256).Hash.ToLower()
$size = (Get-Item -LiteralPath $dstExe).Length

$manifest = [ordered]@{
    version = $Version
    file    = 'netmon.exe'
    sha256  = $hash
    size    = $size
    notes   = 'netmon seed: мониторинг сети, VPN, хотспот, самодиагностика'
    updated = (Get-Date).ToString('yyyy-MM-dd')
}
$manifestPath = Join-Path $public 'manifest.json'
($manifest | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Host ("version:  " + $Version)
Write-Host ("sha256:   " + $hash)
Write-Host ("size:     " + $size + " bytes")
Write-Host ("manifest: " + $manifestPath)

if (-not (Test-Path (Join-Path $root '.git'))) {
    git -C $root init | Out-Null
    git -C $root branch -M $Branch
}
git -C $root add -A
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
git -C $root commit -m ("seed " + $Version + " (" + $stamp + ")") | Out-Null
Write-Host 'committed'

if ($Push) {
    Write-Host ("pushing to " + $Remote + " " + $Branch)
    git -C $root push -u $Remote $Branch
} else {
    Write-Host 'push skipped (use -Push); remote must point to your GitHub repository'
}
