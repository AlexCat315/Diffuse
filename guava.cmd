@echo off
setlocal
if not defined GUAVA_SWIFT_EXECUTABLE set "GUAVA_SWIFT_EXECUTABLE=swift"
"%GUAVA_SWIFT_EXECUTABLE%" run --package-path "%~dp0Tools\Guava" guava %*
exit /b %errorlevel%
