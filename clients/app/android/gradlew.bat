@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "GRADLE_VERSION=9.1.0"
set "GRADLE_CACHE_ROOT=%USERPROFILE%\.gradle\openimx"
set "GRADLE_HOME=%GRADLE_CACHE_ROOT%\gradle-%GRADLE_VERSION%"
set "GRADLE_EXE=%GRADLE_HOME%\bin\gradle.bat"

if not defined JAVA_HOME (
  for /d %%D in ("%ProgramFiles%\Microsoft\jdk-*") do set "JAVA_HOME=%%~fD"
)

if not defined JAVA_HOME (
  echo Java was not found. Set JAVA_HOME to a JDK 17 or newer. 1>&2
  exit /b 1
)

if not exist "%GRADLE_EXE%" (
  if not exist "%GRADLE_CACHE_ROOT%" mkdir "%GRADLE_CACHE_ROOT%"
  set "GRADLE_ARCHIVE=%TEMP%\openimx-gradle-%RANDOM%-%RANDOM%.zip"
  echo Downloading Gradle %GRADLE_VERSION%...
  curl.exe --fail --location --silent --show-error "https://services.gradle.org/distributions/gradle-!GRADLE_VERSION!-bin.zip" --output "!GRADLE_ARCHIVE!"
  if errorlevel 1 exit /b !ERRORLEVEL!

  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '!GRADLE_ARCHIVE!' -DestinationPath '!GRADLE_CACHE_ROOT!' -Force"
  set "EXPAND_EXIT=!ERRORLEVEL!"
  del /q "!GRADLE_ARCHIVE!" >nul 2>&1
  if not "!EXPAND_EXIT!"=="0" exit /b !EXPAND_EXIT!
)

if not exist "%GRADLE_EXE%" (
  echo Gradle installation is incomplete: %GRADLE_EXE% 1>&2
  exit /b 1
)

call "%GRADLE_EXE%" %*
exit /b %ERRORLEVEL%
