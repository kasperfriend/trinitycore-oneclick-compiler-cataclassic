@echo off
setlocal
cd /d "%~dp0"

rem ============================================================================
rem  make-bnet-cert.bat
rem  Runs make-bnet-cert.ps1 (cert generation + Root store install + hosts
rem  check) with the -Hosts option by default, elevating to Administrator
rem  automatically via UAC. The cert files are created in THIS folder.
rem
rem  Usage: double-click, or run from cmd:
rem      make-bnet-cert.bat
rem  You can also pass extra arguments straight to the .ps1:
rem      make-bnet-cert.bat -CertCN "localhost.actual.wowemu.dev"
rem ============================================================================

if not exist "%~dp0make-bnet-cert.ps1" (
    echo [X] make-bnet-cert.ps1 not found next to this .bat - keep them together.
    pause
    exit /b 1
)

rem --- elevate if not already admin -----------------------------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

rem --- run the script (already elevated, -Hosts by default) ------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0make-bnet-cert.ps1" -Hosts %*

echo.
pause
