param([string]$Prefix = "$env:LOCALAPPDATA\Guava")
$ErrorActionPreference = "Stop"
$GuavaSwift = if ($env:GUAVA_SWIFT_EXECUTABLE) { $env:GUAVA_SWIFT_EXECUTABLE } else { "swift" }
if (-not (Get-Command $GuavaSwift -ErrorAction SilentlyContinue)) {
    throw "Install Swift 6.4.1 and its Visual Studio C++ / Windows SDK prerequisites: https://www.swift.org/install/windows/. Then rerun this installer."
}
& $GuavaSwift build --package-path $PSScriptRoot --configuration release --product guava
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$GuavaProducts = & $GuavaSwift build --package-path $PSScriptRoot --configuration release --show-bin-path
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $GuavaSwift "$PSScriptRoot/install.swift" $GuavaProducts $Prefix
exit $LASTEXITCODE
