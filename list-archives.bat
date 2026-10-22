@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0list-archives.ps1" %*
rem Keep the window open when launched by double-click
echo %cmdcmdline% | find /i "%~0" >nul && pause
