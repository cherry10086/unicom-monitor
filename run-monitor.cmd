@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

REM Unicom 5G plan monitor launcher.
REM Usage: run-monitor.cmd [-SelfTest] [-NoArchive] [-ConfigPath <path>]

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor.ps1" %*
set RC=%ERRORLEVEL%

if not "%RC%"=="0" (
    echo.
    echo [ERROR] monitor.ps1 exited with code %RC%. See output\logs for details.
)

endlocal & exit /b %RC%
