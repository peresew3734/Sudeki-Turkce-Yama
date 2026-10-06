@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TurkceYama\Kur.ps1"
set "SUDEKI_YAMA_EXIT=%ERRORLEVEL%"
pause
exit /b %SUDEKI_YAMA_EXIT%
