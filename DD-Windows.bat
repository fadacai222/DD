@echo off
setlocal
set "ROOT=%~dp0"
set "EXE=%ROOT%clients\app\build\windows\x64\runner\Release\im_client.exe"

if not exist "%EXE%" set "EXE=%ROOT%clients\app\build_win_fresh\windows\x64\runner\Release\im_client.exe"

if not exist "%EXE%" (
  echo [DD] Windows client not found.
  echo [DD] Please rebuild the Windows client first.
  pause
  exit /b 1
)

start "DD" /D "%~dp0" "%EXE%"
exit /b 0
