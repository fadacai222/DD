@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"

echo ==============================================
echo      DD Server Rebuild ^& Restart
echo ==============================================
echo.

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo [ERROR] powershell.exe not found.
    goto :failed
)

where docker.exe >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Docker CLI not found. Please start/install Docker Desktop first.
    goto :failed
)

docker info >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Docker Desktop is not running.
    echo Start Docker Desktop and run this BAT again.
    goto :failed
)

if exist "%~dp0.data\auth-dev.json" (
    echo [1/3] Stopping current DD server environment...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\stop-auth-dev.ps1"
    if errorlevel 1 (
        echo.
        echo [ERROR] Failed to stop the current DD server.
        echo The old server may still be running. Read the error above before retrying.
        goto :failed
    )
) else (
    echo [1/3] No active DD auth-dev state found. Starting cleanly...
)

echo.
echo [2/3] Rebuilding DD API and messaging worker, then restarting services...
echo       Client packages and Web client will NOT be rebuilt/started.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-auth-dev.ps1" -SkipClientBuild -SkipWeb
if errorlevel 1 (
    echo.
    echo [ERROR] DD server rebuild/restart failed.
    echo Check the error above and these logs if they exist:
    echo   .data\dd-auth-dev-api.err.log
    echo   .data\dd-auth-dev-worker.err.log
    goto :failed
)

echo.
echo [3/3] Checking API health...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18473/api/v1/system/live' -TimeoutSec 5; if($r.StatusCode -ne 200){exit 1}"
if errorlevel 1 (
    echo [ERROR] Server process started, but health check failed.
    echo Check .data\dd-auth-dev-api.err.log
    goto :failed
)

echo.
echo ==============================================
echo [OK] DD server rebuilt and restarted.
echo API: http://127.0.0.1:18473
echo Existing PostgreSQL data is preserved.
echo ==============================================
echo.
pause
exit /b 0

:failed
echo.
echo ==============================================
echo [FAILED] DD server was NOT confirmed healthy.
echo ==============================================
echo.
pause
exit /b 1
