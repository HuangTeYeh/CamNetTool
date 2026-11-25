@echo off
rem CamNetTool - start without a console window
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0CamNetTool.ps1"
exit /b 0
