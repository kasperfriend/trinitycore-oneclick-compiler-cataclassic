<#
.SYNOPSIS
    One-click BUILD for a TrinityCore "cata_classic" (WoW 4.4.2 Cataclysm Classic) private server:
    installs tooling, sets up dependencies, compiles the server, prepares databases and configs,
    then STOPS - it never launches bnetserver.exe / worldserver.exe (worldserver would crash
    without extracted map data; starting the servers is intentionally left as a manual step).

.DESCRIPTION
    This script automates:
      1. Checking/installing build tools (Git, CMake, 7-Zip, Visual Studio 2022 Build Tools w/ C++ workload) via winget
      2. Setting up vcpkg and building OpenSSL through it
      3. Building Boost through vcpkg (same mechanism as OpenSSL)
      4. Cloning the TrinityCore cata_classic branch
      5. Downloading a portable MariaDB (no system-wide install, no admin service) and initializing it
      6. Creating the auth/characters/world databases
      7. Compiling TrinityCore (servers + extraction tools) with CMake + MSBuild
      8. Downloading the matching TDB (world database content) release and dropping it next to worldserver.exe
         so TrinityCore's built-in auto-updater imports it on first boot
     9. Writing working bnetserver.conf / worldserver.conf pointed at the portable DB,
        plus a start-database.bat in the server folder to bring the portable DB back up
        after a reboot (it is not installed as a Windows service)
    10. STOPPING here - bnetserver.exe / worldserver.exe are NOT started (by design).
         worldserver crashes on first start without extracted map/vmap/mmap data, so launching
         the servers is a deliberate manual step AFTER extraction (see "Next steps" at the end).

.NOTES
    - Run this from an elevated (Administrator) PowerShell window on Windows 10/11 x64.
    - This is a LONG process. Boost install is a few minutes. vcpkg building OpenSSL is ~5-15 min.
      Compiling TrinityCore itself is commonly 20-60+ minutes depending on your CPU.
    - This script does NOT and CANNOT extract map/vmap/mmap/DBC data without a client. If you pass
    - The "Whitemane-sourced client" swap is a manual last step: point that client's Config.wtf portal at
      localhost, and its build number must match 4.4.2.60895 or it will refuse to connect.
    - This script intentionally does NOT start bnetserver.exe / worldserver.exe. Start them manually
      after the map/vmap/mmap extraction is done (see the final "Next steps" block).

.PARAMETER InstallRoot
    Root folder everything gets installed under. Defaults to the folder this script itself is
    sitting in (so wherever you drop/run it from is where everything lands).

.PARAMETER SqlPort
    Port for the portable MariaDB instance. Default 3307 (avoids clashing with any existing MySQL/MariaDB).

.PARAMETER PortalDomain
    Domain used for the Battle.net login portal hostnames written into bnetserver.conf
    (LoginREST.ExternalAddress / LoginREST.LocalAddress = localhost.actual.<PortalDomain>).
    Default: wowemu.dev - must match the patched client (its exe dials us.actual.wowemu.dev).

.EXAMPLE
    .\Compile-TrinityCore-CataClassic.ps1
#>

[CmdletBinding()]
param(
    [string]$InstallRoot        = $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }),
    [int]   $SqlPort            = 3307,
    [string]$SqlRootPassword    = "RootPass123!",
    [string]$TrinityDbPassword  = "trinity",
    [string]$PortalDomain       = "wowemu.dev",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"   # speeds up Invoke-WebRequest a lot
# PowerShell 7.3+ auto-converts a non-zero exit code from ANY native command into a terminating
# error that respects $ErrorActionPreference above - regardless of stream redirection. This script
# checks $LASTEXITCODE itself wherever it matters, so that auto-behavior is disabled here. Harmless
# no-op on Windows PowerShell 5.1, where this preference variable doesn't exist.
$PSNativeCommandUseErrorActionPreference = $false

# ------------------------------------------------------------------------------------------------
#  Helpers
# ------------------------------------------------------------------------------------------------
function Write-Step   { param($msg) Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok     { param($msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn2  { param($msg) Write-Host "  [!]  $msg" -ForegroundColor Yellow }
function Write-Err2   { param($msg) Write-Host "  [X]  $msg" -ForegroundColor Red }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Ensure-Winget {
    if (-not (Test-CommandExists "winget")) {
        throw "winget was not found. Install 'App Installer' from the Microsoft Store, then re-run this script."
    }
}

function Ensure-WingetPackage {
    param([string]$Id, [string]$FriendlyName, [string]$Override = $null)
    $already = winget list --id $Id --accept-source-agreements 2>$null | Select-String -SimpleMatch $Id
    if ($already) {
        Write-Ok "$FriendlyName already installed"
        return
    }
    Write-Host "  Installing $FriendlyName ($Id) via winget..."
    $args = @("install", "--id", $Id, "-e", "--accept-source-agreements", "--accept-package-agreements", "--silent")
    if ($Override) { $args += @("--override", $Override) }
    $p = Start-Process winget -ArgumentList $args -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Warn2 "$FriendlyName install returned exit code $($p.ExitCode) - it may already be present under a different registration, continuing"
    } else {
        Write-Ok "$FriendlyName installed"
    }
}

function Invoke-DownloadFile {
    param([string]$Url, [string]$OutFile)
    Write-Host "  Downloading: $Url"
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

function Wait-ForTcpPort {
    param([string]$ComputerName = "127.0.0.1", [int]$Port, [int]$TimeoutSec = 60)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect($ComputerName, $Port)
            $client.Close()
            return $true
        } catch {
            Start-Sleep -Milliseconds 1000
        }
    }
    return $false
}

if (-not (Test-IsAdmin)) {
    Write-Warn2 "Not running as Administrator. Some installs (winget/VS Build Tools) may prompt or fail."
    Write-Warn2 "Recommended: close this and re-run PowerShell 'as Administrator'."
    Start-Sleep -Seconds 3
}

$null = New-Item -ItemType Directory -Force -Path $InstallRoot
Set-Location $InstallRoot

$SrcDir      = Join-Path $InstallRoot "TrinityCore"
$BuildDir    = Join-Path $InstallRoot "build"
$ServerDir   = Join-Path $InstallRoot "server"
$VcpkgDir    = Join-Path $InstallRoot "vcpkg"
$MariaDbDir  = Join-Path $InstallRoot "mariadb-portable"
$MariaDbData = Join-Path $MariaDbDir "data"
$ToolsDir    = Join-Path $InstallRoot "_tools"
$null = New-Item -ItemType Directory -Force -Path $ToolsDir

Write-Host "TrinityCore Cataclysm Classic (4.4.2) one-click setup" -ForegroundColor Magenta
Write-Host "Install root: $InstallRoot"

# ------------------------------------------------------------------------------------------------
#  1. Base tooling via winget
# ------------------------------------------------------------------------------------------------
Write-Step "Checking base tools (Git, CMake, 7-Zip, VS 2022 Build Tools)"
Ensure-Winget
Ensure-WingetPackage -Id "Git.Git"          -FriendlyName "Git"
Ensure-WingetPackage -Id "Kitware.CMake"    -FriendlyName "CMake"
Ensure-WingetPackage -Id "7zip.7zip"        -FriendlyName "7-Zip"

# VS Build Tools with the C++ desktop workload. This one can take a while the first time.
$vsOverride = '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools ' +
              '--add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 ' +
              '--add Microsoft.VisualStudio.Component.Windows11SDK.22621'
Ensure-WingetPackage -Id "Microsoft.VisualStudio.2022.BuildTools" -FriendlyName "VS 2022 Build Tools (C++ workload)" -Override $vsOverride

# Refresh PATH in this session so git/cmake/7z from a fresh winget install are visible
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

foreach ($cmd in @("git","cmake")) {
    if (-not (Test-CommandExists $cmd)) {
        Write-Err2 "$cmd is still not on PATH. Close this window, open a NEW PowerShell (Administrator), and re-run this script so PATH updates take effect."
        exit 1
    }
}
Write-Ok "Base tools ready"

# ------------------------------------------------------------------------------------------------
#  2. vcpkg + OpenSSL
# ------------------------------------------------------------------------------------------------
Write-Step "Setting up vcpkg and building OpenSSL (this can take 5-15 minutes)"
if (-not (Test-Path $VcpkgDir)) {
    git clone --depth 1 https://github.com/microsoft/vcpkg.git $VcpkgDir
}
$vcpkgExe = Join-Path $VcpkgDir "vcpkg.exe"
if (-not (Test-Path $vcpkgExe)) {
    & (Join-Path $VcpkgDir "bootstrap-vcpkg.bat") -disableMetrics
}
& $vcpkgExe install openssl:x64-windows
if ($LASTEXITCODE -ne 0) { throw "vcpkg failed to install openssl:x64-windows - scroll up for the package error." }

# TrinityCore needs the MySQL client development package (mysql.h + libmysql.lib)
# to compile. The MariaDB server ZIP provides the server/client executables, but it
# is not a reliable source for the Windows development headers/import library.
& $vcpkgExe install libmysql:x64-windows
if ($LASTEXITCODE -ne 0) { throw "vcpkg failed to install libmysql:x64-windows - scroll up for the package error." }
$vcpkgToolchain = Join-Path $VcpkgDir "scripts\buildsystems\vcpkg.cmake"
$vcpkgInstalled = Join-Path $VcpkgDir "installed\x64-windows"
$opensslRoot = $vcpkgInstalled
Write-Ok "OpenSSL ready via vcpkg at $opensslRoot"

# ------------------------------------------------------------------------------------------------
#  3. Boost via vcpkg (same mechanism as OpenSSL - more reliable than the prebuilt
#     installer's silent-mode switches, which vary by build and aren't worth guessing at)
# ------------------------------------------------------------------------------------------------
Write-Step "Installing Boost via vcpkg (this is the slow one - can take 30-90+ minutes)"
& $vcpkgExe install boost:x64-windows
if ($LASTEXITCODE -ne 0) { throw "vcpkg failed to install boost:x64-windows - scroll up for the specific package error." }
$boostRoot = $vcpkgInstalled
$boostConfig = Get-ChildItem (Join-Path $boostRoot "share\boost") -Filter "BoostConfig.cmake" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $boostConfig) { throw "vcpkg installed Boost, but BoostConfig.cmake was not found under $boostRoot\share\boost. Re-run vcpkg install boost:x64-windows." }
$boostDir = $boostConfig.Directory.FullName
Write-Ok "Boost ready via vcpkg at $boostRoot (config: $boostDir)"
[System.Environment]::SetEnvironmentVariable("BOOST_ROOT", $boostRoot, "User")
$env:BOOST_ROOT = $boostRoot

# ------------------------------------------------------------------------------------------------
#  4. Clone TrinityCore cata_classic
# ------------------------------------------------------------------------------------------------
Write-Step "Cloning TrinityCore (cata_classic branch)"
if (Test-Path (Join-Path $SrcDir ".git")) {
    Write-Ok "Source already cloned, pulling latest"
    Push-Location $SrcDir
    git fetch origin
    git checkout cata_classic
    git pull origin cata_classic
    Pop-Location
} else {
    git clone --single-branch --branch cata_classic https://github.com/TrinityCore/TrinityCore.git $SrcDir
}
Write-Ok "Source ready at $SrcDir"

# ------------------------------------------------------------------------------------------------
#  5. Portable MariaDB
# ------------------------------------------------------------------------------------------------
Write-Step "Setting up portable MariaDB (no system install, runs on port $SqlPort)"
$mysqldExe = Join-Path $MariaDbDir "bin\mysqld.exe"
if (-not (Test-Path $mysqldExe)) {
    Write-Host "  Looking up latest stable MariaDB release..."
    $rest = Invoke-RestMethod -Uri "https://downloads.mariadb.org/rest-api/mariadb/"
    $stableSeries = ($rest.major_releases | Where-Object { $_.release_status -eq "Stable" } | Sort-Object release_id -Descending | Select-Object -First 1).release_id
    $verInfo = Invoke-RestMethod -Uri "https://downloads.mariadb.org/rest-api/mariadb/$stableSeries/"
    $latest  = ($verInfo.releases.PSObject.Properties.Value | Sort-Object release_id -Descending | Select-Object -First 1)
    # The MariaDB series endpoint lists the debug-symbols zip BEFORE the real
    # server zip. Only the plain "mariadb-<ver>-winx64.zip" contains bin\mysqld.exe.
    $zipAsset = $latest.files | Where-Object { $_.file_name -match '^mariadb-.*-winx64\.zip$' -and $_.file_name -notmatch 'debugsymbols' } | Select-Object -First 1
    if (-not $zipAsset) {
        $zipAsset = $latest.files | Where-Object { $_.os -eq "Windows" -and $_.cpu -eq "x86_64" -and $_.file_name -like "*.zip" -and $_.file_name -notmatch 'debugsymbols' } | Select-Object -First 1
    }
    if (-not $zipAsset) { throw "Could not find a Windows x86_64 zip package for MariaDB $($latest.release_id). Check https://mariadb.org/download/ manually." }

    $mariaZip = Join-Path $ToolsDir "mariadb.zip"
    Invoke-DownloadFile -Url $zipAsset.file_download_url -OutFile $mariaZip
    Write-Host "  Extracting MariaDB..."
    Expand-Archive -Path $mariaZip -DestinationPath $ToolsDir -Force
    $extracted = Get-ChildItem $ToolsDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName "bin\mysqld.exe") } | Select-Object -First 1
    if (-not $extracted) { throw "Downloaded zip ($($zipAsset.file_name)) contains no bin\mysqld.exe - delete $ToolsDir\mariadb.zip and re-run." }
    if (Test-Path $MariaDbDir) { Remove-Item $MariaDbDir -Recurse -Force }
    Move-Item $extracted.FullName $MariaDbDir -Force
    Write-Ok "Portable MariaDB downloaded to $MariaDbDir"
} else {
    Write-Ok "Portable MariaDB already downloaded"
}

# Data-dir initialization is checked separately from the download/extract above, so a prior run
# that got MariaDB extracted but failed to initialize (e.g. an install_db flag error) resumes
# correctly instead of skipping straight to (and failing) mysqld startup again.
if (-not (Test-Path (Join-Path $MariaDbData "mysql"))) {
    Write-Host "  Initializing data directory..."
    $installDb = Get-ChildItem (Join-Path $MariaDbDir "bin") -Filter "mariadb-install-db.exe" | Select-Object -First 1
    if (-not $installDb) {
        $installDb = Get-ChildItem (Join-Path $MariaDbDir "bin") -Filter "mysql_install_db.exe" | Select-Object -First 1
    }
    if (-not $installDb) { throw "Could not find mariadb-install-db.exe or mysql_install_db.exe under $MariaDbDir\bin" }
    & $installDb.FullName "--datadir=$MariaDbData"
    if (-not (Test-Path (Join-Path $MariaDbData "mysql"))) {
        throw "MariaDB data directory initialization did not produce $MariaDbData\mysql - scroll up for the actual error from $($installDb.Name), fix it, delete '$MariaDbData' (not the whole mariadb-portable folder), and re-run."
    }
    Write-Ok "Data directory initialized"
} else {
    Write-Ok "Data directory already initialized"
}

$iniPath = Join-Path $MariaDbDir "my.ini"
if (-not (Test-Path $iniPath)) {
@"
[mysqld]
port=$SqlPort
datadir=$($MariaDbData -replace '\\','/')
basedir=$($MariaDbDir -replace '\\','/')
bind-address=127.0.0.1
skip-networking=0
"@ | Set-Content -Path $iniPath -Encoding ASCII
}

Write-Host "  Starting mysqld..."
$mysqldRunning = Get-Process -Name "mysqld" -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $mysqldExe }
if (-not $mysqldRunning) {
    Start-Process -FilePath $mysqldExe -ArgumentList "--defaults-file=`"$(Join-Path $MariaDbDir 'my.ini')`"" -WindowStyle Minimized
}
if (-not (Wait-ForTcpPort -Port $SqlPort -TimeoutSec 45)) {
    Write-Err2 "MariaDB did not come up on port $SqlPort in time. Check for errors in $MariaDbData."
    exit 1
}
Write-Ok "MariaDB is listening on 127.0.0.1:$SqlPort"

$mysqlCli = Join-Path $MariaDbDir "bin\mysql.exe"

# MariaDB 11.4+ enables TLS certificate verification by default. During local bootstrap,
# explicitly disable certificate verification so a blank-password probe does not emit the
# "ssl-verify-server-cert is disabled because of an insecure passwordless login" warning.
# Native stderr must never be promoted to a terminating error here - the guard lives
# inside Invoke-MySqlBootstrap (see below).
function Invoke-MySqlBootstrap {
    param(
        [Parameter(Mandatory=$true)] [string[]]$Arguments
    )

    $outFile = Join-Path $ToolsDir "mysql-bootstrap.stdout.tmp"
    $errFile = Join-Path $ToolsDir "mysql-bootstrap.stderr.tmp"
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue

    # IMPORTANT: invoke mysql.exe directly through PowerShell rather than Start-Process.
    # Start-Process -ArgumentList flattens an argument array into a command line and can
    # split SQL such as "SELECT 1;" into separate arguments. mysql.exe then interprets the
    # trailing "1;" as a database name, producing: Unknown database '1;'.
    #
    # Windows PowerShell 5.1 (and PowerShell < 7.3) promote native-command stderr that is
    # redirected with 2> into a TERMINATING NativeCommandError whenever $ErrorActionPreference
    # is "Stop" - so mysql.exe's "ERROR 1045 (28000): Access denied" would abort the whole
    # script right here instead of being captured into $errFile and handled below. Relax EAP
    # for this one call so failures surface as an ordinary (nonzero) exit code. (On
    # PowerShell 7.3+ the $PSNativeCommandUseErrorActionPreference = $false set at the top
    # already prevents this; this block keeps 5.1 working too.)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $stdout = & $mysqlCli @Arguments 2> $errFile | Out-String
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $exitCode = $LASTEXITCODE
    Set-Content -Path $outFile -Value $stdout -Encoding UTF8

    $stderr = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { "" }
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue

    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

# First see whether the configured password already works (important for re-runs).
$rootWithPassword = Invoke-MySqlBootstrap @(
    "--disable-ssl-verify-server-cert",
    "--protocol=tcp", "-h", "127.0.0.1", "-P", "$SqlPort", "-u", "root",
    "-p$SqlRootPassword", "-e", "SELECT 1;"
)

if ($rootWithPassword.ExitCode -eq 0) {
    Write-Ok "MariaDB root password already configured"
} else {
    # Fresh MariaDB installations often allow an empty root password. Try that first.
    $rootBlank = Invoke-MySqlBootstrap @(
        "--disable-ssl-verify-server-cert",
        "--protocol=tcp", "-h", "127.0.0.1", "-P", "$SqlPort", "-u", "root",
        "-e", "SELECT 1;"
    )

    if ($rootBlank.ExitCode -eq 0) {
        $safeRootPassword = $SqlRootPassword -replace "'", "''"
        $setRoot = Invoke-MySqlBootstrap @(
            "--disable-ssl-verify-server-cert",
            "--protocol=tcp", "-h", "127.0.0.1", "-P", "$SqlPort", "-u", "root",
            "-e", "CREATE USER IF NOT EXISTS 'root'@'localhost' IDENTIFIED BY '$safeRootPassword'; ALTER USER 'root'@'localhost' IDENTIFIED BY '$safeRootPassword'; CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '$safeRootPassword'; ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '$safeRootPassword'; FLUSH PRIVILEGES;"
        )
        if ($setRoot.ExitCode -ne 0) {
            throw "MariaDB accepted the initial root connection but setting the root password failed. $($setRoot.StdErr.Trim())"
        }
        Write-Ok "MariaDB root password initialized"
    } else {
        # Neither the configured password nor a blank password works. This normally means a
        # previous run initialized root with a different password/plugin. Recover the local
        # portable instance using --skip-grant-tables rather than deleting the data directory.
        Write-Warn2 "Root authentication does not match the configured password or blank-password state. Starting local recovery mode..."

        $existingMaria = Get-Process -Name "mysqld" -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $mysqldExe }

        if ($existingMaria) {
            $existingMaria | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }

        # Wait briefly for the old listener to disappear before reusing the same port.
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            $probe = $null
            try {
                $probe = New-Object System.Net.Sockets.TcpClient
                $probe.Connect("127.0.0.1", $SqlPort)
                $probe.Close()
            } catch {
                if ($probe) { $probe.Close() }
                break
            }
            Start-Sleep -Milliseconds 250
        }

        $recoveryLog = Join-Path $ToolsDir "mariadb-root-recovery.log"
        $recoveryOut = Join-Path $ToolsDir "mariadb-root-recovery.stdout.tmp"
        $recoveryErr = Join-Path $ToolsDir "mariadb-root-recovery.stderr.tmp"
        Remove-Item $recoveryLog, $recoveryOut, $recoveryErr -Force -ErrorAction SilentlyContinue

        $recoveryArgs = @(
            "--defaults-file=$(Join-Path $MariaDbDir 'my.ini')",
            "--skip-grant-tables",
            "--skip-networking=0",
            "--bind-address=127.0.0.1"
        )
        $recoveryProc = Start-Process -FilePath $mysqldExe `
            -ArgumentList $recoveryArgs `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $recoveryOut `
            -RedirectStandardError $recoveryErr

        if (-not (Wait-ForTcpPort -Port $SqlPort -TimeoutSec 30)) {
            $recoveryText = ""
            if (Test-Path $recoveryOut) { $recoveryText += Get-Content $recoveryOut -Raw }
            if (Test-Path $recoveryErr) { $recoveryText += "`n" + (Get-Content $recoveryErr -Raw) }
            throw "MariaDB recovery mode did not start on port $SqlPort. $recoveryText"
        }

        $safeRootPassword = $SqlRootPassword -replace "'", "''"
        $recoverySql = @"
FLUSH PRIVILEGES;
CREATE USER IF NOT EXISTS 'root'@'localhost' IDENTIFIED BY '$safeRootPassword';
ALTER USER 'root'@'localhost' IDENTIFIED BY '$safeRootPassword';
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '$safeRootPassword';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '$safeRootPassword';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
"@
        $recoverySqlFile = Join-Path $ToolsDir "mariadb-root-recovery.sql"
        Set-Content -Path $recoverySqlFile -Value $recoverySql -Encoding UTF8

        # Feed the SQL directly to mysql.exe through StandardInput.
        # Using cmd.exe /c with "< file.sql" is fragile on Windows because cmd.exe has
        # special quoting rules and can produce "The filename, directory name, or
        # volume label syntax is incorrect." for perfectly valid paths.
        $cmdOut = Join-Path $ToolsDir "mysql-root-recovery.stdout.tmp"
        $cmdErr = Join-Path $ToolsDir "mysql-root-recovery.stderr.tmp"
        Remove-Item $cmdOut, $cmdErr -Force -ErrorAction SilentlyContinue

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $mysqlCli
        $psi.Arguments = "--disable-ssl-verify-server-cert --protocol=tcp -h 127.0.0.1 -P $SqlPort -u root"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $mysqlProc = New-Object System.Diagnostics.Process
        $mysqlProc.StartInfo = $psi
        $null = $mysqlProc.Start()

        # Send the recovery SQL over stdin, then close stdin so mysql knows the input is complete.
        $mysqlProc.StandardInput.Write($recoverySql)
        $mysqlProc.StandardInput.Close()

        $stdoutTask = $mysqlProc.StandardOutput.ReadToEndAsync()
        $stderrTask = $mysqlProc.StandardError.ReadToEndAsync()
        $mysqlProc.WaitForExit()

        $recoverRoot = [pscustomobject]@{
            ExitCode = $mysqlProc.ExitCode
            StdOut   = $stdoutTask.GetAwaiter().GetResult()
            StdErr   = $stderrTask.GetAwaiter().GetResult()
        }

        Set-Content -Path $cmdOut -Value $recoverRoot.StdOut -Encoding UTF8
        Set-Content -Path $cmdErr -Value $recoverRoot.StdErr -Encoding UTF8

        $recoveryOutput = $recoverRoot.StdOut
        if ($recoverRoot.StdErr) { $recoveryOutput += "`n" + $recoverRoot.StdErr }
        Set-Content -Path $recoveryLog -Value $recoveryOutput -Encoding UTF8
        Remove-Item $recoveryOut, $recoveryErr -Force -ErrorAction SilentlyContinue

        if ($recoverRoot.ExitCode -ne 0) {
            $recoveryText = ($recoverRoot.StdErr + " " + $recoverRoot.StdOut).Trim()
            if (Test-Path $recoveryLog) {
                $recoveryText += "`nMariaDB recovery log:`n" + (Get-Content $recoveryLog -Raw)
            }
            try { Stop-Process -Id $recoveryProc.Id -Force -ErrorAction SilentlyContinue } catch {}
            throw "MariaDB root recovery failed. $recoveryText"
        }

        try { Stop-Process -Id $recoveryProc.Id -Force -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Seconds 2

        # Start MariaDB normally again with the newly assigned password.
        Start-Process -FilePath $mysqldExe -ArgumentList "--defaults-file=`"$(Join-Path $MariaDbDir 'my.ini')`"" -WindowStyle Minimized
        if (-not (Wait-ForTcpPort -Port $SqlPort -TimeoutSec 30)) {
            throw "MariaDB did not return to normal mode after root-password recovery. Check $recoveryLog"
        }

        $verifyRoot = Invoke-MySqlBootstrap @(
            "--disable-ssl-verify-server-cert",
            "--protocol=tcp", "-h", "127.0.0.1", "-P", "$SqlPort", "-u", "root",
            "-p$SqlRootPassword", "-e", "SELECT 1;"
        )
        if ($verifyRoot.ExitCode -ne 0) {
            throw "MariaDB root password was recovered but verification failed. $($verifyRoot.StdErr.Trim())"
        }
        Write-Ok "MariaDB root password recovered and verified"
    }
}

# ------------------------------------------------------------------------------------------------
#  6. Create databases + trinity user via TrinityCore's own create_mysql.sql
# ------------------------------------------------------------------------------------------------
Write-Step "Creating auth/characters/world databases"
$createSqlPath = Join-Path $SrcDir "sql\create\create_mysql.sql"
if (-not (Test-Path $createSqlPath)) {
    throw "Could not find sql/create/create_mysql.sql in the source tree - the repo layout may have changed."
}
$createSql = Get-Content $createSqlPath -Raw
$createSql = $createSql -replace "trinity(?=['`"])", $TrinityDbPassword   # best-effort password substitution
$tmpSql = Join-Path $ToolsDir "create_mysql_patched.sql"
Set-Content -Path $tmpSql -Value $createSql -Encoding UTF8
Get-Content $tmpSql | & $mysqlCli "--disable-ssl-verify-server-cert" "-h" "127.0.0.1" "-P" "$SqlPort" "-u" "root" "-p$SqlRootPassword"
if ($LASTEXITCODE -eq 0) {
    Write-Ok "Databases + trinity user created"
} else {
    Write-Warn2 "Database initialization reported an error (the trinity user may already exist); continuing."
}

# create_mysql.sql only grants privileges on auth/characters/world by name. Other databases
# TrinityCore may reference (e.g. a separate "hotfixes" database for HotfixDatabaseInfo) need
# the same trinity user to be able to create and use them too - broaden the grant globally
# rather than trying to guess every database name in advance.
& $mysqlCli "-h" "127.0.0.1" "-P" "$SqlPort" "-u" "root" "-p$SqlRootPassword" "-e" "GRANT ALL PRIVILEGES ON *.* TO 'trinity'@'localhost'; FLUSH PRIVILEGES;"

# ------------------------------------------------------------------------------------------------
#  7. Configure + build
# ------------------------------------------------------------------------------------------------
if (-not $SkipBuild) {
    $cmakeCache = Join-Path $BuildDir "CMakeCache.txt"
    $reuseExistingConfigure = $false
    if (Test-Path $cmakeCache) {
        Write-Host "`nAn existing, already-configured CMake build directory was found at:" -ForegroundColor Yellow
        Write-Host "  $BuildDir" -ForegroundColor Yellow
        $answer = Read-Host "Reuse it and skip reconfiguring (faster, recommended if the last run got this far cleanly)? [Y/n]"
        if ($answer -eq "" -or $answer -match '^[Yy]') {
            $reuseExistingConfigure = $true
        }
    }

    if ($reuseExistingConfigure) {
        Write-Ok "Reusing existing CMake configuration at $BuildDir - skipping reconfigure"
    } else {
        Write-Step "Configuring CMake (this generates a VS2022 solution)"
        # Start the configure step from a clean cache. This prevents a previous failed
        # dependency probe from leaving *NOTFOUND values cached in CMakeCache.txt.
        if (Test-Path $BuildDir) {
            Remove-Item $BuildDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $null = New-Item -ItemType Directory -Force -Path $BuildDir
        # TrinityCore cata_classic uses its own Boost/OpenSSL/MySQL find modules.
        # Make every dependency location explicit instead of relying on PATH/registry discovery.
        # MariaDB remains the actual database server/client; libmysql supplies the C/C++ headers
        # and import library required to compile TrinityCore on Windows.
        $mysqlRoot = $vcpkgInstalled
        $mysqlIncludeDir = Join-Path $vcpkgInstalled "include\mysql"
        $mysqlLibrary = Join-Path $vcpkgInstalled "lib\libmysql.lib"
        $cmakeLog = Join-Path $ToolsDir "cmake-configure.log"

        foreach ($required in @(
            $mysqlIncludeDir,
            (Join-Path $mysqlIncludeDir "mysql.h"),
            $mysqlLibrary,
            (Join-Path $vcpkgInstalled "include\openssl\ssl.h"),
            (Join-Path $vcpkgInstalled "lib\libssl.lib"),
            (Join-Path $vcpkgInstalled "lib\libcrypto.lib"),
            (Join-Path $boostDir "BoostConfig.cmake")
        )) {
            if (-not (Test-Path $required)) {
                throw "Required build dependency file is missing: $required"
            }
        }

        $cmakeArgs = @(
            "-S", $SrcDir, "-B", $BuildDir,
            "-G", "Visual Studio 17 2022", "-A", "x64",
            "-DCMAKE_TOOLCHAIN_FILE=$vcpkgToolchain",
            "-DCMAKE_PREFIX_PATH=$vcpkgInstalled",
            "-DCMAKE_INSTALL_PREFIX=$ServerDir",
            "-DTOOLS=1",
            "-DSERVERS=1",
            "-DSCRIPTS=static",
            "-DWITH_WARNINGS=0",
            "-DBUILD_TESTING=0",
            "-DBoost_DIR=$boostDir",
            "-DBOOST_ROOT=$boostRoot",
            "-DOPENSSL_ROOT_DIR=$opensslRoot",
            "-DMYSQL_ROOT_DIR=$mysqlRoot",
            "-DMYSQL_INCLUDE_DIR=$mysqlIncludeDir",
            "-DMYSQL_LIBRARY=$mysqlLibrary",
            "-DMYSQL_EXECUTABLE=$(Join-Path $MariaDbDir 'bin\mysql.exe')"
        )

        Write-Host "  CMake dependency roots:"
        Write-Host "    Boost   : $boostDir"
        Write-Host "    OpenSSL : $opensslRoot"
        Write-Host "    MySQL headers: $mysqlIncludeDir"
        Write-Host "    MySQL library: $mysqlLibrary"
        Write-Host "    MariaDB : $MariaDbDir"
        Write-Host "  Writing full configure output to $cmakeLog"

        # Show CMake output LIVE. PowerShell 5.1 can turn native stderr into a terminating
        # error when $ErrorActionPreference is Stop, so temporarily relax it only for CMake.
        # We still capture the complete output to a log and preserve CMake's real exit code.
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & cmake @cmakeArgs 2>&1 | Tee-Object -FilePath $cmakeLog
            $cmakeExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }

        if ($cmakeExit -ne 0) {
            Write-Err2 "CMake configure failed (exit code $cmakeExit)."
            Write-Host "  Last 120 lines of ${cmakeLog}:" -ForegroundColor Yellow
            if (Test-Path $cmakeLog) { Get-Content $cmakeLog -Tail 120 }
            throw "CMake configure failed. Full log: $cmakeLog"
        }
    }


    Write-Step "Building TrinityCore (Release) - this is the long part, grab a coffee"
    & cmake --build $BuildDir --config Release --target install -- /m
    if ($LASTEXITCODE -ne 0) { throw "Build failed - scroll up for the compiler error." }
    Write-Ok "Build + install complete -> $ServerDir"
} else {
    Write-Warn2 "SkipBuild was set - assuming $ServerDir already has a compiled server"
}

# This branch's CMake install rule drops executables directly into $ServerDir, NOT into a
# $ServerDir\bin subfolder (unlike some other TrinityCore branches/forks). Detect where
# worldserver.exe actually landed instead of assuming, so this keeps working even if that
# ever changes. Also clears out a bogus zero-byte "bin" FILE that earlier buggy runs of this
# script could have created (Copy-Item treats a missing single-level destination as a rename).
$bogusBinFile = Join-Path $ServerDir "bin"
if ((Test-Path $bogusBinFile) -and -not (Test-Path $bogusBinFile -PathType Container)) {
    Write-Warn2 "Removing a bogus 'bin' file left over from an earlier failed run: $bogusBinFile"
    Remove-Item $bogusBinFile -Force
}

if (Test-Path (Join-Path $ServerDir "bin\worldserver.exe")) {
    $binDir = Join-Path $ServerDir "bin"
} elseif (Test-Path (Join-Path $ServerDir "worldserver.exe")) {
    $binDir = $ServerDir
} else {
    $found = Get-ChildItem $ServerDir -Filter "worldserver.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) { throw "Could not find worldserver.exe anywhere under $ServerDir after the build - something went wrong with the install step." }
    $binDir = $found.DirectoryName
}
Write-Ok "Server executables are in $binDir"

# The vcpkg MySQL client is dynamically linked on x64-windows. Make sure its runtime DLLs
# are next to the TrinityCore executables so the portable server does not depend on PATH.
# (CMake's own install step usually already copies these; this is a safety net.)
$runtimeBin = Join-Path $vcpkgInstalled "bin"
if (Test-Path $runtimeBin) {
    Get-ChildItem $runtimeBin -Filter "*.dll" | ForEach-Object {
        $dest = Join-Path $binDir $_.Name
        if (-not (Test-Path $dest)) {
            Copy-Item $_.FullName -Destination $binDir -Force
        }
    }
}

# ------------------------------------------------------------------------------------------------
#  8. Fetch matching TDB (world DB content) release for cata_classic (build family 442)
# ------------------------------------------------------------------------------------------------
Write-Step "Fetching latest TDB (world database) release for cata_classic"
$releases = Invoke-RestMethod -Uri "https://api.github.com/repos/TrinityCore/TrinityCore/releases?per_page=100" -Headers @{ "User-Agent" = "trinitycore-setup-script" }
$tdb = $releases | Where-Object { $_.tag_name -match "^TDB442\." } | Sort-Object published_at -Descending | Select-Object -First 1
if (-not $tdb) {
    Write-Warn2 "Could not find a TDB442.* release automatically. Go to https://github.com/TrinityCore/TrinityCore/releases, find the newest 'TDB 442.xxxxx' entry, download its .7z asset, and extract the TDB_full_world_*.sql AND TDB_full_hotfixes_*.sql files into $binDir manually."
} else {
    $asset = $tdb.assets | Where-Object { $_.name -like "*.7z" } | Select-Object -First 1
    Write-Host "  Using $($tdb.tag_name) -> $($asset.name)"
    $tdbArchive = Join-Path $ToolsDir $asset.name
    Invoke-DownloadFile -Url $asset.browser_download_url -OutFile $tdbArchive
    $sevenZip = "${env:ProgramFiles}\7-Zip\7z.exe"
    if (-not (Test-Path $sevenZip)) { $sevenZip = "${env:ProgramFiles(x86)}\7-Zip\7z.exe" }
    $tdbExtractDir = Join-Path $ToolsDir "tdb_extracted"
    & $sevenZip x $tdbArchive "-o$tdbExtractDir" -y | Out-Null
    # Copy BOTH the world and hotfixes full SQL files - worldserver's built-in
    # auto-updater imports the hotfixes file into the hotfixes DB when
    # Updates.EnableDatabases includes hotfixes (bit 8), i.e. 15 in worldserver.conf.
    Get-ChildItem $tdbExtractDir -Filter "TDB_full_*.sql" -Recurse | ForEach-Object {
        Copy-Item $_.FullName -Destination $binDir -Force
        Write-Ok "Copied $($_.Name) into $binDir (worldserver will auto-import these on first launch)"
    }
}

# ------------------------------------------------------------------------------------------------
#  9. Write working configs
# ------------------------------------------------------------------------------------------------
Write-Step "Writing bnetserver.conf / worldserver.conf"

# TrinityCore's .conf.dist files are UTF-8. Get-Content/Set-Content without an explicit
# -Encoding fall back to the system's default codepage (e.g. Windows-1251 on a Cyrillic
# Windows install), which silently mangles any multi-byte UTF-8 character on write-back -
# corrupting whatever line it happens to land on. Reading/writing via .NET's UTF8 APIs
# directly (with a MatchEvaluator, so $ in a value is never misread as a regex backreference)
# avoids that entirely.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Set-ConfValue {
    param([string]$Path, [string]$Key, [string]$Value)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $pattern = "(?m)^(\s*" + [regex]::Escape($Key) + "\s*=\s*).*$"
    $evaluator = { param($m) $m.Groups[1].Value + $Value }
    $text = [regex]::Replace($text, $pattern, $evaluator)
    [System.IO.File]::WriteAllText($Path, $text, $utf8NoBom)
}

# Repoints a "*DatabaseInfo" line (format: host;port;user;pass;database) at our portable
# MariaDB while PRESERVING whatever database name the .dist already specifies for that key -
# this matters especially for HotfixDatabaseInfo, whose default database name we shouldn't
# have to guess.
function Set-ConfDbConnection {
    param([string]$Path, [string]$Key)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $pattern = "(?m)^(\s*" + [regex]::Escape($Key) + "\s*=\s*)(.*)$"
    $matched = $false
    $evaluator = {
        param($m)
        $script:matched = $true
        $parts = $m.Groups[2].Value.Trim() -split ';'
        $dbName = if ($parts.Length -ge 5) { $parts[4] } else { $parts[-1] }
        $m.Groups[1].Value + "127.0.0.1;$SqlPort;trinity;$TrinityDbPassword;$dbName"
    }
    $text = [regex]::Replace($text, $pattern, $evaluator)
    [System.IO.File]::WriteAllText($Path, $text, $utf8NoBom)
    return $matched
}

foreach ($pair in @(
    @{ dist = "bnetserver.conf.dist";   conf = "bnetserver.conf";   updates = "7"  },
    @{ dist = "worldserver.conf.dist"; conf = "worldserver.conf"; updates = "15" }
)) {
    $distPath = Join-Path $binDir $pair.dist
    $confPath = Join-Path $binDir $pair.conf
    # Always regenerate from the pristine .dist template rather than only the first time.
    # A .conf created during an earlier broken run (e.g. before $binDir was pointing at the
    # right folder) would otherwise sit there corrupted/truncated forever, since later runs
    # would see it already exists and just re-edit the already-broken file.
    if (Test-Path $distPath) {
        Copy-Item $distPath $confPath -Force
    }
    if (Test-Path $confPath) {
        Set-ConfDbConnection -Path $confPath -Key "LoginDatabaseInfo" | Out-Null
        # Every server binary needs its own copy of Updates.EnableDatabases set - the earlier
        # version of this script only set it on worldserver.conf, so bnetserver never created
        # its auth-database tables and every query failed with "Table ... doesn't exist".
        # bnetserver = 7 (world+characters+auth); worldserver = 15 (adds hotfixes, bit 8).
        Set-ConfValue -Path $confPath -Key "Updates.EnableDatabases" -Value $pair.updates
        # The client's web-login + portal host MUST be a DNS name - a raw IP such as
        # 127.0.0.1 is refused by the client's embedded login page. These two keys
        # build the web-auth URL AND the /bnetserver/portal/ reply (the address the
        # client dials for the BGS session), so point them at a hostname that
        # resolves on the client machine (hosts entry) and is covered by the cert.
        if ($pair.conf -eq "bnetserver.conf") {
            Set-ConfValue -Path $confPath -Key "LoginREST.ExternalAddress" -Value "localhost.actual.$PortalDomain"
            Set-ConfValue -Path $confPath -Key "LoginREST.LocalAddress"    -Value "localhost.actual.$PortalDomain"
        }
        Write-Ok "$($pair.conf) configured (regenerated from $($pair.dist))"
    } else {
        Write-Warn2 "$($pair.conf) was not created - no $($pair.dist) found in $binDir. Check the login server manually."
    }
}

$wConf = Join-Path $binDir "worldserver.conf"
if (Test-Path $wConf) {
    Set-ConfDbConnection -Path $wConf -Key "WorldDatabaseInfo" | Out-Null
    Set-ConfDbConnection -Path $wConf -Key "CharacterDatabaseInfo" | Out-Null
    # HotfixDatabaseInfo defaults to TrinityCore's stock host/port (3306) if left untouched -
    # this is what was causing "Can't connect to MySQL server on '127.0.0.1:3306'".
    $hotfixSet = Set-ConfDbConnection -Path $wConf -Key "HotfixDatabaseInfo"
    if (-not $hotfixSet) {
        Write-Warn2 "No HotfixDatabaseInfo line found in worldserver.conf - if hotfix-related errors show up, check that key manually."
    }
    # Game data lives in a "Data" subfolder next to worldserver.exe
    # (dbc/maps/vmaps/mmaps go there - see the extractor step below).
    Set-ConfValue -Path $wConf -Key "DataDir" -Value '"./Data"'
}

# ------------------------------------------------------------------------------------------------
#  9b. Write start-database.bat into the server folder
# ------------------------------------------------------------------------------------------------
# A convenience launcher for later reboots: the portable MariaDB is not installed as a Windows
# service, so after a restart it has to be brought up manually before bnetserver/worldserver can
# connect. This .bat lives in $ServerDir, resolves the mariadb-portable folder relative to its
# own location (so the whole install root can be moved without breaking it), starts mysqld with
# the exact same --defaults-file argument this script uses, waits for the port to accept TCP
# connections, and refuses to start a second instance if one is already listening.
Write-Step "Writing start-database.bat into $ServerDir"
$null = New-Item -ItemType Directory -Force -Path $ServerDir
$startDbBat = Join-Path $ServerDir "start-database.bat"
$startDbBatContent = @"
@echo off
setlocal
rem ============================================================================
rem  start-database.bat - starts the portable MariaDB used by this TrinityCore
rem  server. Run this BEFORE starting bnetserver.exe / worldserver.exe.
rem  The database keeps running in this (minimized) console window; closing the
rem  window shuts the database down.
rem
rem  Paths are resolved relative to this .bat file, so the whole install folder
rem  can be moved without editing anything here.
rem ============================================================================

set "SERVER_DIR=%~dp0"
rem  Strip the trailing backslash from %~dp0 for consistent path joining.
if "%SERVER_DIR:~-1%"=="\" set "SERVER_DIR=%SERVER_DIR:~0,-1%"

set "MARIADB_DIR=%SERVER_DIR%\..\mariadb-portable"
set "MYSQLD=%MARIADB_DIR%\bin\mysqld.exe"
set "INI=%MARIADB_DIR%\my.ini"
set "DB_PORT=$SqlPort"

if not exist "%MYSQLD%" (
    echo [X] mysqld.exe not found at:
    echo     %MYSQLD%
    echo Expected the portable MariaDB in a "mariadb-portable" folder next to
    echo the "server" folder. Run the setup script first or restore that folder.
    pause
    exit /b 1
)

if not exist "%INI%" (
    echo [X] my.ini not found at:
    echo     %INI%
    echo Run the setup script first - it creates the portable DB configuration.
    pause
    exit /b 1
)

rem  Already listening on the DB port? Then mysqld is up and there is nothing
rem  to do. findstr matches the LISTENING line for 127.0.0.1:%DB_PORT% without
rem  false-matching numbers that merely end with the port (e.g. ephemeral
rem  client ports like 50986 never match the ":<port> " pattern).
netstat -an -p tcp | findstr /r /c:":%DB_PORT% .*LISTENING" >nul
if not errorlevel 1 (
    echo [!] MariaDB is already listening on port %DB_PORT% - nothing to start.
    timeout /t 3 >nul
    exit /b 0
)

echo Starting portable MariaDB on port %DB_PORT%...
start "TrinityCore MariaDB (port %DB_PORT%)" /min "%MYSQLD%" --defaults-file="%INI%"

rem  Wait up to ~30 seconds for the server to accept connections.
set /a tries=0
:waitdb
set /a tries+=1
netstat -an -p tcp | findstr /r /c:":%DB_PORT% .*LISTENING" >nul
if not errorlevel 1 goto dbup
if %tries% geq 30 goto dbfail
timeout /t 1 >nul
goto waitdb

:dbup
echo [OK] MariaDB is up and listening on 127.0.0.1:%DB_PORT%.
echo      It runs in the minimized "TrinityCore MariaDB" window - leave it open.
echo      Closing that window shuts the database down.
echo.
echo      You can now start bnetserver.exe and worldserver.exe.
timeout /t 5 >nul
exit /b 0

:dbfail
echo [X] MariaDB did not start listening on port %DB_PORT% within 30 seconds.
echo     Check the minimized MariaDB window / the data folder for errors:
echo       %MARIADB_DIR%\data
pause
exit /b 1
"@
Set-Content -Path $startDbBat -Value $startDbBatContent -Encoding ASCII
Write-Ok "Created $startDbBat"


# ------------------------------------------------------------------------------------------------
#  10. STOP - servers are intentionally NOT started
# ------------------------------------------------------------------------------------------------
# worldserver.exe crashes on first start when dbc/maps/vmaps/mmaps data has not been extracted,
# so this script deliberately stops here. Start the servers manually AFTER extraction.
Write-Step "Build complete - NOT starting servers (by design)"
Write-Ok "Compilation and preparation finished."
Write-Ok "Server executables are in: $binDir"
Write-Ok "bnetserver.exe / worldserver.exe were NOT launched."

if (-not ($ClientPath -and (Test-Path (Join-Path $ClientPath "Wow.exe")))) {
    Write-Warn2 "Map/vmap/mmap data was NOT extracted."
    Write-Warn2 "worldserver.exe will crash on first start until the extractors have been run -"
}

Write-Host "`n=================================================================" -ForegroundColor Magenta
Write-Host " DONE - compiled and ready, but nothing was launched."               -ForegroundColor Magenta
Write-Host " Start everything manually, in this order:"                          -ForegroundColor Magenta
Write-Host "   1) Database (portable MariaDB is NOT a Windows service):"         -ForegroundColor Magenta
Write-Host "        $(Join-Path $ServerDir 'start-database.bat')"                -ForegroundColor Magenta
Write-Host "   2) bnetserver.exe  (login server) - from $binDir"                 -ForegroundColor Magenta
Write-Host "   3) worldserver.exe (game server)  - from $binDir"                 -ForegroundColor Magenta
Write-Host "      Only AFTER map/vmap/mmap extraction. Its first launch imports" -ForegroundColor Magenta
Write-Host "      the TDB world database automatically - that can take minutes." -ForegroundColor Magenta
Write-Host "=================================================================" -ForegroundColor Magenta
Write-Host "Next steps:"
Write-Host " 1. If you don't have extracted data, run the map/vmap/mmap extraction (see warning above)"
Write-Host "    BEFORE starting worldserver - it crashes without dbc/maps/vmaps/mmaps."
Write-Host " 2. Battle.net accounts (what the 4.4.2 client uses) are created in the bnetserver console:"
Write-Host "      bnetaccount create email@example.com <password>"
Write-Host " 3. In the worldserver console, once it's fully up, to promote that account to GM, type:"
Write-Host "      account set gmlevel <hash number> 3 -1"
Write-Host " 4. To point your Whitemane-sourced client here: edit its Config.wtf to 'SET portal localhost(in quotes)'"
Write-Host "    - its build MUST be 4.4.2.60895 or it will refuse to connect."
Write-Host " 5. After a reboot, start the database first with:"
Write-Host "      $(Join-Path $ServerDir 'start-database.bat')"
Write-Host "    then launch bnetserver.exe and worldserver.exe from $binDir."
Write-Host " 6. Server files: $ServerDir  |  Portable DB: $MariaDbDir (port $SqlPort)"

