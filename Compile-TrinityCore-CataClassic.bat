@echo off
REM ============================================================================
REM  TrinityCore Cataclysm Classic (4.4.2) one-click setup - batch launcher
REM
REM  Just double-click this file. It will:
REM    - re-launch itself as Administrator if it isn't already (one UAC prompt)
REM    - run Setup-TrinityCore-CataClassic.ps1, which MUST be in this same folder
REM    - install everything (source, build, portable MariaDB, compiled server)
REM      into this same folder, wherever you dropped it
REM ============================================================================

setlocal
set "SCRIPT_DIR=%~dp0"
set "PS1_PATH=%SCRIPT_DIR%Compile-TrinityCore-CataClassic.ps1"

REM Strip the trailing backslash for the -InstallRoot argument - a trailing
REM backslash right before a closing quote escapes the quote on the command
REM line (e.g. "E:\CataC\" is parsed as E:\CataC" ) and breaks PowerShell's
REM argument parsing.
set "INSTALL_ROOT_ARG=%SCRIPT_DIR%"
if "%INSTALL_ROOT_ARG:~-1%"=="\" set "INSTALL_ROOT_ARG=%INSTALL_ROOT_ARG:~0,-1%"

REM --- Check for Administrator rights, self-elevate if needed ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

if not exist "%PS1_PATH%" (
    echo ERROR: Could not find Compile-TrinityCore-CataClassic.ps1
    echo It needs to be in the same folder as this .bat file:
    echo   %SCRIPT_DIR%
    pause
    exit /b 1
)

echo.
echo Installing everything into: %SCRIPT_DIR%
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%" -InstallRoot "%INSTALL_ROOT_ARG%" %*

echo.
echo ============================================================
echo  Script finished (or stopped on an error above).
echo ============================================================
pause
