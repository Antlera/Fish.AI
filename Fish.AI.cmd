@echo off
rem Fish.AI - double-click to start. Same as running start.ps1 from PowerShell.
rem -ExecutionPolicy Bypass applies to this process only, so no policy change is needed.
cd /d "%~dp0"
title Fish.AI
where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
)
if not %errorlevel%==0 (
    echo.
    echo Fish.AI stopped with an error. See above, or logs\ in this folder.
    pause
)
