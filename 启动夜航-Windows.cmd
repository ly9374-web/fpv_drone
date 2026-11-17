@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-nightflight.ps1"
set "launch_status=%ERRORLEVEL%"
if "%launch_status%"=="-1073741510" exit /b 0
if not "%launch_status%"=="0" pause
exit /b %launch_status%
