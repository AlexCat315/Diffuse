@echo off
setlocal
if not defined COVE_SWIFT_EXECUTABLE set "COVE_SWIFT_EXECUTABLE=swift"
call :select_sdk
if errorlevel 1 exit /b %errorlevel%
if /i "%~1"=="plugin" (
    if /i "%~2"=="build" (
        set "DIFFUSE_ARGS=plugin-build"
        shift
        shift
        goto collect
    )
)
if /i not "%~1"=="studio" goto forward
set "DIFFUSE_ARGS="
shift
:collect
if "%~1"=="" goto studio
set "DIFFUSE_ARGS=%DIFFUSE_ARGS% "%~1""
shift
goto collect
:studio
"%COVE_SWIFT_EXECUTABLE%" build --package-path "%~dp0Tools\Developer" --product cove-dev --jobs 4 1>&2
if errorlevel 1 exit /b %errorlevel%
set "COVE_PRODUCTS_FILE=%TEMP%\cove-dev-products-%RANDOM%-%RANDOM%.txt"
"%COVE_SWIFT_EXECUTABLE%" build --package-path "%~dp0Tools\Developer" --show-bin-path > "%COVE_PRODUCTS_FILE%"
if errorlevel 1 (
    del /q "%COVE_PRODUCTS_FILE%"
    exit /b %errorlevel%
)
set /p DIFFUSE_PRODUCTS=<"%COVE_PRODUCTS_FILE%"
del /q "%COVE_PRODUCTS_FILE%"
set "COVE_ROOT=%~dp0"
"%DIFFUSE_PRODUCTS%\cove-dev.exe" %DIFFUSE_ARGS%
exit /b %errorlevel%
:forward
if exist "%COVE_SDK_ROOT%\cove.exe" (
    "%COVE_SDK_ROOT%\cove.exe" %*
) else (
    call "%COVE_SDK_ROOT%\cove.cmd" %*
)
exit /b %errorlevel%
:select_sdk
if defined COVE_SDK_ROOT exit /b 0
if not defined COVE_HOME set "COVE_HOME=%LOCALAPPDATA%\Cove"
for /f "usebackq delims=" %%V in (`powershell.exe -NoProfile -Command "(Get-Content -LiteralPath '%~dp0Editor\cove.json' -Raw | ConvertFrom-Json).toolchain.sdkVersion"`) do set "COVE_REQUIRED=%%V"
set "COVE_SDK_ROOT=%COVE_HOME%\versions\%COVE_REQUIRED%"
if exist "%COVE_HOME%\sdk.json" for /f "usebackq delims=" %%R in (`powershell.exe -NoProfile -Command "$p=(Get-Content -LiteralPath '%COVE_HOME%\sdk.json' -Raw | ConvertFrom-Json).path; if((Get-Content -LiteralPath ($p + '/Tools/Cove/Sources/CoveCLI/SDK.json') -Raw | ConvertFrom-Json).version -eq '%COVE_REQUIRED%'){$p}"`) do set "COVE_SDK_ROOT=%%R"
if exist "%COVE_SDK_ROOT%\Package.swift" goto sdk_selected
call cove sdk install "%COVE_REQUIRED%"
if errorlevel 1 exit /b %errorlevel%

:sdk_selected
exit /b 0
