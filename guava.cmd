@echo off
setlocal
if not defined GUAVA_SWIFT_EXECUTABLE set "GUAVA_SWIFT_EXECUTABLE=swift"
call :select_sdk
if errorlevel 1 exit /b %errorlevel%
if /i not "%~1"=="studio" goto forward
set "GUAVA_STUDIO_ARGS="
shift
:collect
if "%~1"=="" goto studio
set "GUAVA_STUDIO_ARGS=%GUAVA_STUDIO_ARGS% "%~1""
shift
goto collect
:studio
"%GUAVA_SWIFT_EXECUTABLE%" build --package-path "%~dp0Tools\Developer" --product guava-dev --jobs 4 1>&2
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
"%GUAVA_SDK_ROOT%\guava.cmd" %*
exit /b %errorlevel%
:select_sdk
if defined GUAVA_SDK_ROOT goto verify_selection
set "GUAVA_SDK_ROOT=%~dp0GuavaUI"
if exist "%GUAVA_SDK_ROOT%\Tools\Guava\Sources\GuavaCLI\SDK.json" goto run
goto fetch
:verify_selection
if exist "%GUAVA_SDK_ROOT%\Tools\Guava\Sources\GuavaCLI\SDK.json" goto run
echo Guava SDK not found at "%GUAVA_SDK_ROOT%". Set GUAVA_SDK_ROOT to a checkout of https://github.com/AlexCat315/GuavaUI.>&2
exit /b 1
:fetch
for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "(Get-Content -Raw '%~dp0Editor\guava.json' | ConvertFrom-Json).toolchain.sdkVersion"`) do set "GUAVA_SDK_VERSION=%%v"
if not defined GUAVA_SDK_VERSION (
    echo Editor\guava.json must declare toolchain.sdkVersion>&2
    exit /b 1
)
echo Fetching Guava SDK v%GUAVA_SDK_VERSION% into GuavaUI/>&2
git clone --depth 1 --branch "v%GUAVA_SDK_VERSION%" --recurse-submodules --shallow-submodules https://github.com/AlexCat315/GuavaUI.git "%~dp0GuavaUI"
if errorlevel 1 exit /b %errorlevel%
set "GUAVA_SDK_ROOT=%~dp0GuavaUI"
:run
exit /b 0
