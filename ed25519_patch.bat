@echo off
setlocal
cd /d "%~dp0"

rem ============================================================================
rem  patch-client.bat
rem  Patches the CLEAN WowClassic.exe (4.4.2, build 60895) in this same folder
rem  with the TrinityCore Ed25519 key, using ed25519_patch.ps1.
rem
rem  - Put this .bat next to BOTH:  WowClassic.exe  and  ed25519_patch.ps1
rem  - The original WowClassic.exe is never modified - a new file
rem    WowClassic-ed25519.exe is created next to it.
rem  - Run it, answer the confirmation, done.
rem  - No administrator rights needed (it only reads/writes files in this
rem    folder) unless WowClassic.exe lives in a protected location.
rem ============================================================================

if not exist "%~dp0WowClassic.exe" (
    echo [X] WowClassic.exe not found in this folder:
    echo     %~dp0
    echo     Put this .bat next to your clean 4.4.2 (build 60895) WowClassic.exe
    echo     and next to ed25519_patch.ps1, then re-run.
    pause
    exit /b 1
)

if not exist "%~dp0ed25519_patch.ps1" (
    echo [X] ed25519_patch.ps1 not found next to this .bat - keep them together.
    pause
    exit /b 1
)

echo.
echo  This will patch:  %~dp0WowClassic.exe
echo  Output will be:   %~dp0WowClassic-ed25519.exe
echo  (the original WowClassic.exe is left untouched)
echo.
choice /c YN /m "Apply the TrinityCore Ed25519 patch now"
if errorlevel 2 (
    echo.
    echo  Skipped - no changes were made.
    pause
    exit /b 0
)

echo.
echo  Patching...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ed25519_patch.ps1" -Patch -Exe "%~dp0WowClassic.exe"
echo.
echo  Done. If you see "SUCCESS: TrinityCore Ed25519 key written." above,
echo  you can use  WowClassic-ed25519.exe  to log in.
pause
