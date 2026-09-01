# ============================================================================
# make-bnet-cert.ps1  --  self-signed cert for the local Battle.net portal
# ============================================================================
# 1. generates bnetserver.cert.pem / bnetserver.key.pem in the CURRENT folder:
#      openssl req -x509 -newkey rsa:2048 ... -subj "/CN=localhost.actual.wowemu.dev"
#      -addext "subjectAltName=DNS:localhost.actual.wowemu.dev,DNS:localhost"
# 2. installs the cert:  certutil -addstore -f Root bnetserver.cert.pem
# 3. with -Hosts: checks hosts and (on confirmation) adds 127.0.0.1 localhost.actual.wowemu.dev
#
# You then copy bnetserver.cert.pem + bnetserver.key.pem into the server folder
# yourself (overwriting the old ones) and restart bnetserver.
#
# Run as ADMINISTRATOR (certutil needs the Root store):
#   powershell -ExecutionPolicy Bypass -File make-bnet-cert.ps1
#   powershell -ExecutionPolicy Bypass -File make-bnet-cert.ps1 -Hosts
# ============================================================================

param(
    [string]$CertCN = "localhost.actual.wowemu.dev",
    [switch]$Hosts
)

$ErrorActionPreference = "Stop"

# --- admin check (certutil -addstore Root requires it) -----------------------
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Run as Administrator (certutil needs the Root store), then re-run." -ForegroundColor Red
    exit 1
}

# --- locate openssl ------------------------------------------------------------
$ossl = (Get-Command openssl -ErrorAction SilentlyContinue).Source
if (-not $ossl) {
    foreach ($c in @(
        "$env:VCPKG_ROOT\installed\x64-windows\tools\openssl\openssl.exe",
        "C:\Program Files\OpenSSL-Win64\bin\openssl.exe"
    )) { if (Test-Path $c) { $ossl = $c; break } }
}
if (-not $ossl) { Write-Host "openssl not found - put openssl.exe on PATH or install it." -ForegroundColor Red; exit 1 }

# --- 1. generate the cert in the current folder --------------------------------
$certPath = Join-Path (Get-Location) "bnetserver.cert.pem"
$keyPath  = Join-Path (Get-Location) "bnetserver.key.pem"
$san = "subjectAltName=DNS:$CertCN,DNS:localhost"
Write-Host ("Generating self-signed cert  CN={0}  SANs: {1}" -f $CertCN, $san)

# PS 5.1 guard: openssl writes progress dots to stderr; relax EAP for this call
# so they don't surface as a NativeCommandError, and check the real exit code.
$prev = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    & $ossl req -x509 -newkey rsa:2048 -keyout $keyPath -out $certPath -days 365 -nodes `
        -subj "/CN=$CertCN" -addext $san 2>&1 | Out-String | Write-Host
    $code = $LASTEXITCODE
} finally { $ErrorActionPreference = $prev }

if ($code -ne 0 -or -not (Test-Path $certPath) -or -not (Test-Path $keyPath)) {
    Write-Host "openssl failed (exit $code) - see output above." -ForegroundColor Red
    exit 1
}
Write-Host "Created: $certPath" -ForegroundColor Green
Write-Host "         $keyPath" -ForegroundColor Green

# --- 2. install into the Root store ---------------------------------------------
Write-Host "Installing into Root store..."
& certutil -addstore -f Root $certPath
if ($LASTEXITCODE -ne 0) { Write-Host "certutil failed - see output above." -ForegroundColor Red; exit 1 }
Write-Host "Installed into Root store." -ForegroundColor Green

# --- 3. optional hosts check/edit ------------------------------------------------
if ($Hosts) {
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $already = $false
    if (Test-Path $hostsPath) {
        $already = [bool](Get-Content $hostsPath | Where-Object {
            $_ -match [regex]::Escape($CertCN) -and $_ -notmatch '^\s*#'
        })
    }
    if ($already) {
        Write-Host "hosts already contains $CertCN" -ForegroundColor Green
    } else {
        $line = "127.0.0.1`t$CertCN"
        $answer = Read-Host "Add '$line' to hosts? [Y/n]"
        if ($answer -eq "" -or $answer -match '^[Yy]') {
            Add-Content -Path $hostsPath -Value $line
            Write-Host "Added to hosts." -ForegroundColor Green
            Write-Host "Note: run 'ipconfig /flushdns' if resolution does not pick it up." -ForegroundColor Yellow
        } else {
            Write-Host "Skipped hosts edit." -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "Now copy bnetserver.cert.pem + bnetserver.key.pem into the server folder" -ForegroundColor White
Write-Host "(overwriting the old ones) and restart bnetserver." -ForegroundColor White
