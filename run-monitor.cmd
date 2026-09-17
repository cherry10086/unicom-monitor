@echo off
setlocal
cd /d "%~dp0"

REM Unicom 5G plan monitor launcher.
REM Usage: run-monitor.cmd [-SelfTest] [-NoArchive] [-ConfigPath <path>]

REM 记住调用者当前的代码页，结束时还原（chcp 会改掉整个控制台窗口的代码页）
for /f "tokens=2 delims=:" %%c in ('chcp') do set "OLDCP=%%c"
set "OLDCP=%OLDCP: =%"
chcp 65001 >nul

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor.ps1" %*
set RC=%ERRORLEVEL%

if not "%RC%"=="0" (
    echo.
    echo [ERROR] monitor.ps1 exited with code %RC%. See output\logs for details.
)

if defined OLDCP chcp %OLDCP% >nul

endlocal & exit /b %RC%
