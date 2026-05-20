@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" engine %*
exit /b %ERRORLEVEL%
