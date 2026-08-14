@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"

echo ==============================================
echo      DD DevSpace Worktree Cleanup
echo ==============================================
echo.
echo Will keep:
echo   1. This main checkout
echo   2. Current Wave3 worktree repo-503b2173
echo.
echo Old worktrees are validated before removal.
echo The old uncommitted release draft is archived outside the repo first.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\cleanup-devspace-worktrees.ps1"
if errorlevel 1 goto :failed

echo.
echo [OK] Worktree cleanup finished.
echo.
pause
exit /b 0

:failed
echo.
echo [FAILED] Cleanup stopped before an unsafe removal.
echo Paste the error output back to ChatGPT.
echo.
pause
exit /b 1
