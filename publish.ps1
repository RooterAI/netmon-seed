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
    [switch]$Push,
    # Публикация файла, чьё дерево не совпадает с текущим, — только осознанно.
    [switch]$AllowTreeMismatch
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$public = Join-Path $root 'public'
$srcExe = if ([System.IO.Path]::IsPathRooted($Source)) { Resolve-Path $Source }
           else { Resolve-Path (Join-Path $root $Source) }

# Провенанс (B-1, этап 13). 00:23:52 и 23:57 в public лежали два разных образа
# с одной версией 3.20.21: у одного дерево менялось во время компиляции, у другого
# метки не было вовсе. Публикуем только файл, чья метка совпадает с деревом на диске.
$dirtyPath = "$srcExe.dirty"
if (Test-Path -LiteralPath $dirtyPath) {
    $why = Get-Content -LiteralPath $dirtyPath -Raw -ErrorAction SilentlyContinue
    if (-not $AllowTreeMismatch) {
        throw "файл помечен dirty, публикация запрещена ($dirtyPath): $why"
    }
    Write-Host "внимание: файл помечен dirty, публикация по -AllowTreeMismatch: $why"
}

function Get-TreeHashNow {
    param([string]$Dir)
    $parts = Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.cpp', '.h', '.rc' -and $_.Name -ne 'build_info.h' } |
        Sort-Object Name |
        ForEach-Object { "$($_.Name):$($_.Length):$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
    if (-not $parts) { return $null }
    $text = [Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))
    (Get-FileHash -InputStream ([IO.MemoryStream]::new($text)) -Algorithm SHA256).Hash.ToLower().Substring(0, 8)
}

$repoRoot = Split-Path -Parent $root
$srcDir = Join-Path $repoRoot 'tools\netmon_cpp\src'
$treeNow = Get-TreeHashNow $srcDir

# --local обязателен: без него команда уходит работающему окну, и версия берётся
# у живого процесса, а не у публикуемого файла (так манифест однажды разошёлся
# с бинарником). Тем же вызовом берём метку сборки и дерево.
$selfOut = & $srcExe --cli self --local 2>&1 | Out-String
$buildStamp = $null
$treeInExe = $null
if ($selfOut -match 'сборка\s*:\s*(\S+?),\s*дерево\s*(\S+)') {
    $buildStamp = $Matches[1]
    $treeInExe = $Matches[2]
}
if (-not $treeInExe -or $treeInExe -eq 'unknown') {
    if (-not $AllowTreeMismatch) { throw "публикуемый файл не сообщает дерево сборки (--cli self): $($srcExe)" }
    Write-Host 'внимание: файл без метки дерева, публикация по -AllowTreeMismatch'
} elseif ($treeNow -and $treeInExe -ne $treeNow) {
    if (-not $AllowTreeMismatch) {
        throw "дерево файла $treeInExe не совпадает с деревом на диске $treeNow — публикация запрещена"
    }
    Write-Host "внимание: дерево файла $treeInExe, на диске $treeNow — публикация по -AllowTreeMismatch"
}

if (-not $Version) {
    # версию берём из того же вызова, что и метку сборки
    if ($selfOut -match 'версия\s*:\s*([0-9]+\.[0-9]+\.[0-9]+)') { $Version = $Matches[1] }
    if (-not $Version) { throw 'укажите -Version x.y.z' }
}

New-Item -ItemType Directory -Path $public -Force | Out-Null
$dstExe = Join-Path $public 'netmon.exe'
Copy-Item -LiteralPath $srcExe -Destination $dstExe -Force

$hash = (Get-FileHash -LiteralPath $dstExe -Algorithm SHA256).Hash.ToLower()
$size = (Get-Item -LiteralPath $dstExe).Length

# Транспорт QUIC (msquic.dll, MIT) — нужен нашему протоколу hysteria2.
# Кладём рядом с netmon.exe: без него сеть работает, но туннель скажет «нет msquic.dll».
$qSrc = Join-Path (Split-Path -Parent $srcExe) 'msquic.dll'
$quicName = $null
$quicHash = $null
if (Test-Path -LiteralPath $qSrc) {
    $qDst = Join-Path $public 'msquic.dll'
    Copy-Item -LiteralPath $qSrc -Destination $qDst -Force
    $quicName = 'msquic.dll'
    $quicHash = (Get-FileHash -LiteralPath $qDst -Algorithm SHA256).Hash.ToLower()
}

$manifest = [ordered]@{
    version = $Version
    file    = 'netmon.exe'
    sha256  = $hash
    size    = $size
    notes   = 'netmon seed: мониторинг сети, VPN, хотспот, самодиагностика'
    updated = (Get-Date).ToString('yyyy-MM-dd')
}
# Провенанс в манифесте: по нему видно, из какого дерева собран образ, не запуская его.
if ($treeInExe) { $manifest.tree = $treeInExe }
if ($buildStamp) { $manifest.build = $buildStamp }
if ($quicName) {
    $manifest.msquic = $quicName
    $manifest.msquic_sha256 = $quicHash
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
