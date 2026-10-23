@echo off
setlocal
if not defined GUAVA_SWIFT_EXECUTABLE set "GUAVA_SWIFT_EXECUTABLE=swift"
if /i not "%~1"=="studio" goto forward
set "GUAVA_STUDIO_ARGS="
shift
:collect
if "%~1"=="" goto studio
set "GUAVA_STUDIO_ARGS=%GUAVA_STUDIO_ARGS% "%~1""
shift
goto collect
:studio
"%GUAVA_SWIFT_EXECUTABLE%" build --package-path "%~dp0Tools\Developer" --product guava-dev --jobs 4
if errorlevel 1 exit /b %errorlevel%
set "GUAVA_PRODUCTS_FILE=%TEMP%\guava-dev-products-%RANDOM%-%RANDOM%.txt"
"%GUAVA_SWIFT_EXECUTABLE%" build --package-path "%~dp0Tools\Developer" --show-bin-path > "%GUAVA_PRODUCTS_FILE%"
if errorlevel 1 (
    del /q "%GUAVA_PRODUCTS_FILE%"
    exit /b %errorlevel%
)
set /p GUAVA_STUDIO_PRODUCTS=<"%GUAVA_PRODUCTS_FILE%"
del /q "%GUAVA_PRODUCTS_FILE%"
set "GUAVA_ROOT=%~dp0"
"%GUAVA_STUDIO_PRODUCTS%\guava-dev.exe" %GUAVA_STUDIO_ARGS%
exit /b %errorlevel%
:forward
if not defined GUAVA_SDK_ROOT set "GUAVA_SDK_ROOT=%~dp0GuavaUI"
"%~dp0GuavaUI\guava.cmd" %*
exit /b %errorlevel%
