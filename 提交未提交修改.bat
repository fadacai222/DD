@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"

echo ==============================================
echo      DD Commit Pending Work
echo ==============================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\commit-pending-work.ps1"
if errorlevel 1 goto :failed

echo.
echo [OK] Pending work was committed.
echo.
pause
exit /b 0

:failed
echo.
echo [FAILED] Commit process stopped before an unsafe action.
echo Paste the error output back to ChatGPT.
echo.
pause
exit /b 1
