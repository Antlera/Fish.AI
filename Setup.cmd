@echo off
rem Fish.AI - double-click to install. Same as running setup.ps1 from PowerShell.
cd /d "%~dp0"
title Fish.AI setup
where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
)
echo.
pause
