@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" -Bootstrap %*
exit /b %ERRORLEVEL%
