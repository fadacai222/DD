@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"
title DD - Windows + Android Packager

echo ==========================================
echo       DD Windows + Android 一键打包
echo ==========================================
echo.
echo 将生成：
echo   DD-Windows.zip
echo   DD-Windows.lnk
echo   DD-Android.apk
echo.
echo 正在构建，请不要关闭窗口...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build-client.ps1" -Target windows-android
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" goto :failed

if not exist "%~dp0DD-Windows.zip" (
    echo [ERROR] Windows 压缩包未生成：DD-Windows.zip
    set "EXIT_CODE=2"
    goto :failed
)
if not exist "%~dp0DD-Android.apk" (
    echo [ERROR] Android APK 未生成：DD-Android.apk
    set "EXIT_CODE=3"
    goto :failed
)
if not exist "%~dp0DD-Windows.lnk" (
    echo [ERROR] Windows 快捷方式未生成：DD-Windows.lnk
    set "EXIT_CODE=4"
    goto :failed
)

echo ==========================================
echo               打包成功
echo ==========================================
echo.
echo Windows 完整包：%~dp0DD-Windows.zip
echo Windows 本机启动：%~dp0DD-Windows.lnk
echo Android APK：%~dp0DD-Android.apk
echo.
explorer.exe /select,"%~dp0DD-Windows.zip"
echo 按任意键关闭窗口。
pause >nul
exit /b 0

:failed
echo ==========================================
echo               打包失败
echo ==========================================
echo.
echo 错误码：%EXIT_CODE%
echo 请把上面的报错截图发给我，不要直接关闭窗口。
echo.
pause
exit /b %EXIT_CODE%
