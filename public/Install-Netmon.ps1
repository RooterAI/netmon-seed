#Requires -Version 5.1
<#
.SYNOPSIS
  Installs the netmon seed client on this PC (VR / Meta Quest helper).

.DESCRIPTION
  Downloads the public seed package (or uses a local copy), verifies SHA-256,
  copies the client to Program Files, registers a scheduled task that starts it
  at logon with highest privileges, and launches it.

.PARAMETER ManifestUrl   URL of manifest.json (public repository or server).
.PARAMETER InstallDir    Target directory (default: C:\Program Files\netmon).
.PARAMETER LocalPackage  Path to a local netmon.exe (skips downloading).
.PARAMETER NoTask        Do not create the scheduled task.
#>
[CmdletBinding()]
param(
    [string]$ManifestUrl = 'https://raw.githubusercontent.com/RooterAI/netmon-seed/main/public/manifest.json',
    [string]$InstallDir = 'C:\Program Files\netmon',
    [string]$LocalPackage = '',
    [string]$ManifestFile = '',
    [string]$ProxyBase = 'https://95-181-173-61.sslip.io:9443',
    [switch]$NoTask
)

$ErrorActionPreference = 'Stop'
Write-Host 'netmon seed installer'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'warning: installer is not elevated; the scheduled task will not be created'
}

$tmp = Join-Path $env:TEMP ('netmon-install-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$packageExe = $LocalPackage
$manifestText = $null
if ($ManifestFile) {
    $manifestText = Get-Content -LiteralPath $ManifestFile -Raw -Encoding UTF8
} elseif (-not $LocalPackage) {
    $manifestPath = Join-Path $tmp 'manifest.json'
    Write-Host ("downloading manifest: " + $ManifestUrl)
    Invoke-WebRequest -Uri $ManifestUrl -OutFile $manifestPath -UseBasicParsing
    $manifestText = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
}

if ($manifestText) {
    $manifest = $manifestText | ConvertFrom-Json
    Write-Host ("package version: " + $manifest.version)
    if (-not $packageExe) {
        $fileUrl = $manifest.file
        if ($fileUrl -notmatch '^[a-z]+://' -and $fileUrl -notmatch '^[A-Za-z]:') {
            $base = $ManifestUrl.Substring(0, $ManifestUrl.LastIndexOf('/') + 1)
            $fileUrl = $base + $fileUrl
        }
        $packageExe = Join-Path $tmp 'netmon.exe'
        Write-Host ("downloading package: " + $fileUrl)
        Invoke-WebRequest -Uri $fileUrl -OutFile $packageExe -UseBasicParsing
    }
    if ($manifest.sha256) {
        $hash = (Get-FileHash -LiteralPath $packageExe -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $manifest.sha256.ToLower()) {
            throw ("hash mismatch: expected " + $manifest.sha256 + ", got " + $hash)
        }
        Write-Host 'hash verified'
    }
}

if (-not (Test-Path -LiteralPath $packageExe)) { throw 'package file not found' }

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$target = Join-Path $InstallDir 'netmon.exe'
Stop-Process -Name netmon -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Copy-Item -LiteralPath $packageExe -Destination $target -Force
Write-Host ("installed: " + $target)

# Адрес серверного API-прокси: реальный ключ DeepSeek есть только на сервере.
# Клиентский ключ nsk_... выдаётся после регистрации (ai proxy import).
$ini = Join-Path $InstallDir 'netmon.ini'
$proxyLine = 'api_proxy_base=' + $ProxyBase
try {
    if (Test-Path -LiteralPath $ini) {
        $iniText = Get-Content -LiteralPath $ini -Raw -Encoding UTF8
        if ($iniText -notmatch '(?m)^\s*api_proxy_base\s*=') {
            $iniText = $iniText.TrimEnd() + "`r`n" + $proxyLine + "`r`n"
            [System.IO.File]::WriteAllText($ini, $iniText, (New-Object System.Text.UTF8Encoding($true)))
            Write-Host ('proxy base added to ' + $ini)
        }
    } else {
        $iniText = "[netmon]`r`n" + $proxyLine + "`r`n"
        [System.IO.File]::WriteAllText($ini, $iniText, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ('created ' + $ini)
    }
} catch {
    Write-Host ('warning: cannot write netmon.ini: ' + $_.Exception.Message)
}

if (-not $NoTask -and $isAdmin) {
    $action = '"{0}"' -f $target
    schtasks /Create /TN netmon /SC ONLOGON /RL HIGHEST /F /TR $action | Out-Null
    Write-Host 'scheduled task netmon created (logon, highest privileges)'
}

Start-Process -FilePath $target -WorkingDirectory $InstallDir
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'done'
