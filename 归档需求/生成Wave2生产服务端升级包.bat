@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"

echo ==============================================
echo      DD Wave2 Production Server Bundle
echo ==============================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\export-wave2-server-bundle.ps1"
if errorlevel 1 goto :failed

echo.
echo [OK] DD-Server-Wave2.bundle is ready in the project root.
echo Upload ONLY this bundle to the production server.
echo.
pause
exit /b 0

:failed
echo.
echo [FAILED] Server bundle was not generated.
echo.
pause
exit /b 1
