@echo off
setlocal
if not defined GUAVA_SWIFT_EXECUTABLE set "GUAVA_SWIFT_EXECUTABLE=swift"
"%GUAVA_SWIFT_EXECUTABLE%" build --package-path "%~dp0Tools\Guava" --product guava --jobs 4
if errorlevel 1 exit /b %errorlevel%
set "GUAVA_PRODUCTS_FILE=%TEMP%\guava-products-%RANDOM%-%RANDOM%.txt"
"%GUAVA_SWIFT_EXECUTABLE%" build --package-path "%~dp0Tools\Guava" --show-bin-path > "%GUAVA_PRODUCTS_FILE%"
if errorlevel 1 (
    del /q "%GUAVA_PRODUCTS_FILE%"
    exit /b %errorlevel%
)
set /p GUAVA_SOURCE_PRODUCTS=<"%GUAVA_PRODUCTS_FILE%"
del /q "%GUAVA_PRODUCTS_FILE%"
"%GUAVA_SOURCE_PRODUCTS%\guava.exe" %*
exit /b %errorlevel%
