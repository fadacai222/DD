@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

title DD 客户端构建垃圾清理

echo ==============================================
echo       DD 客户端构建垃圾一键清理
echo ==============================================
echo.
echo 将清理可重新生成的 Flutter/Windows/Android 构建产物。
echo 不会删除源码、Git、配置、签名文件和依赖定义。
echo.
echo 建议先关闭正在运行的 DD Windows 客户端。
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\clean-client-build-junk.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo 清理未完全成功，请看上面的红字。
    echo 如果提示文件被占用，关闭 DD / Flutter 构建窗口后再运行一次。
) else (
    echo 清理完成。
)
echo.
pause
exit /b %EXIT_CODE%
