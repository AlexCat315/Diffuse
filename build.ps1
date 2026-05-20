param(
    [ValidateSet("engine", "editor")]
    [string]$Package = "editor",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$SwiftBuildArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$packagePath = switch ($Package) {
    "engine" { Join-Path $root "Engine" }
    "editor" { Join-Path $root "Editor" }
}

function Import-VSDevEnvironment {
    $isWindowsPlatform = $env:OS -eq "Windows_NT" -or [System.IO.Path]::DirectorySeparatorChar -eq "\"
    if (-not $isWindowsPlatform -or $env:VCToolsInstallDir) {
        return
    }

    $candidates = @()
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($installPath) {
            $candidates += Join-Path $installPath "VC\Auxiliary\Build\vcvarsall.bat"
        }
    }

    $candidates += @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvarsall.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
    )

    $vcvars = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $vcvars) {
        Write-Warning "Visual Studio C++ build tools were not found automatically; continuing with the current environment."
        return
    }

    cmd /s /c "`"$vcvars`" x64 >nul && set" | ForEach-Object {
        $index = $_.IndexOf("=")
        if ($index -gt 0) {
            $name = $_.Substring(0, $index)
            $value = $_.Substring($index + 1)
            Set-Item -Path "Env:$name" -Value $value
        }
    }
}

Import-VSDevEnvironment
$env:MIMALLOC_DISABLE_REDIRECT = "1"

$swiftBuild = Get-Command swift-build -ErrorAction SilentlyContinue
if ($swiftBuild) {
    & $swiftBuild.Source --package-path $packagePath @SwiftBuildArgs
    exit $LASTEXITCODE
}

$swift = Get-Command swift -ErrorAction SilentlyContinue
if (-not $swift) {
    throw "Swift was not found on PATH. Install a Swift toolchain or add swift/swift-build to PATH."
}

& $swift.Source build --package-path $packagePath @SwiftBuildArgs
exit $LASTEXITCODE
