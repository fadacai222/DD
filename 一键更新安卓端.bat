@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

echo ==========================================
echo        DD Android One-Click Updater
echo ==========================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\update-android-client.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo Update FAILED. Error code: %EXIT_CODE%
    echo Please read the error above. If the phone asked for USB install permission,
    echo allow it on the phone and run this file again.
) else (
    echo Update finished. DD has been restarted on the phone.
)
echo.
pause
exit /b %EXIT_CODE%
