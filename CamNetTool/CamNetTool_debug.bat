@echo off
rem CamNetTool - debug mode (keeps this console window open)
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0CamNetTool.ps1"
echo.
echo ExitCode=%errorlevel%
pause
