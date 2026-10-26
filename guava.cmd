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
if exist "%GUAVA_SDK_ROOT%\guava.exe" (
    "%GUAVA_SDK_ROOT%\guava.exe" %*
) else (
    call "%GUAVA_SDK_ROOT%\guava.cmd" %*
)
exit /b %errorlevel%
:select_sdk
if defined GUAVA_SDK_ROOT exit /b 0
if not defined GUAVA_HOME set "GUAVA_HOME=%LOCALAPPDATA%\Guava"
for /f "usebackq delims=" %%V in (`powershell.exe -NoProfile -Command "(Get-Content -LiteralPath '%~dp0Editor\guava.json' -Raw | ConvertFrom-Json).toolchain.sdkVersion"`) do set "GUAVA_REQUIRED=%%V"
set "GUAVA_SDK_ROOT=%GUAVA_HOME%\versions\%GUAVA_REQUIRED%"
if exist "%GUAVA_HOME%\sdk.json" for /f "usebackq delims=" %%R in (`powershell.exe -NoProfile -Command "$p=(Get-Content -LiteralPath '%GUAVA_HOME%\sdk.json' -Raw | ConvertFrom-Json).path; if((Get-Content -LiteralPath ($p + '/Tools/Guava/Sources/GuavaCLI/SDK.json') -Raw | ConvertFrom-Json).version -eq '%GUAVA_REQUIRED%'){$p}"`) do set "GUAVA_SDK_ROOT=%%R"
if exist "%GUAVA_SDK_ROOT%\Package.swift" goto sdk_selected
call guava sdk install "%GUAVA_REQUIRED%"
if errorlevel 1 exit /b %errorlevel%

:sdk_selected
exit /b 0
