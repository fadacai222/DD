@echo off
setlocal
cd /d "%~dp0"

title DD Client Build Junk Cleaner

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\clean-client-build-junk.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%EXIT_CODE%"=="0" goto CLEAN_OK

echo Cleanup was not fully successful. See the errors above.
goto CLEAN_END

:CLEAN_OK
echo Cleanup finished.

:CLEAN_END
echo.
pause
exit /b %EXIT_CODE%
