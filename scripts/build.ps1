param(
    [ValidateSet('windows', 'android', 'all')][string]$Target = 'all',
    [string]$Flutter = 'flutter',
    [string]$IperfDirectory = ''
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
if ($Flutter -eq 'flutter' -and (Test-Path -LiteralPath "$projectRoot\.tools\flutter\bin\flutter.bat")) {
    $Flutter = "$projectRoot\.tools\flutter\bin\flutter.bat"
}
function Invoke-Flutter([string[]]$Arguments) {
    & $Flutter @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Flutter failed: $($Arguments -join ' ')" }
}
Invoke-Flutter -Arguments @('pub', 'get')
Invoke-Flutter -Arguments @('analyze')
Invoke-Flutter -Arguments @('test')
New-Item -ItemType Directory -Path "$projectRoot\dist" -Force | Out-Null
if ($Target -in 'windows', 'all') {
    Invoke-Flutter -Arguments @('build', 'windows', '--release')
    $windowsOut = "$projectRoot\dist\windows"
    New-Item -ItemType Directory -Path $windowsOut -Force | Out-Null
    Copy-Item -Path "$projectRoot\build\windows\x64\runner\Release\*" -Destination $windowsOut -Recurse -Force
    $vswherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswherePath) {
        $vsRoot = & $vswherePath -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($vsRoot) {
            $redistRoot = Join-Path $vsRoot 'VC\Redist\MSVC'
            $redistVersion = Get-ChildItem -LiteralPath $redistRoot -Directory | Where-Object { $_.Name -match '^\d+\.' } | Sort-Object Name -Descending | Select-Object -First 1
            if ($redistVersion) {
                $crtDirectory = Join-Path $redistVersion.FullName 'x64\Microsoft.VC143.CRT'
                if (Test-Path -LiteralPath $crtDirectory) {
                    Copy-Item -Path "$crtDirectory\*.dll" -Destination $windowsOut -Force
                }
            }
        }
    }
    if ($IperfDirectory) {
        $enginePath = Join-Path $IperfDirectory 'iperf3.exe'
        if (!(Test-Path -LiteralPath $enginePath)) { throw 'IperfDirectory must contain iperf3.exe' }
        # Keep the engine DLLs next to its executable.
        Get-ChildItem -LiteralPath $IperfDirectory -File | Where-Object {
            $_.Extension -in '.exe', '.dll' -or $_.Name -match 'LICENSE|COPYING'
        } | Copy-Item -Destination $windowsOut -Force
        $licensePath = Join-Path $IperfDirectory 'licenses'
        if (Test-Path -LiteralPath $licensePath) {
            Copy-Item -LiteralPath $licensePath -Destination $windowsOut -Recurse -Force
        }
    }
    Copy-Item -LiteralPath "$projectRoot\docs\WINDOWS.txt" -Destination "$windowsOut\使用说明.txt" -Force
    Compress-Archive -Path "$windowsOut\*" -DestinationPath "$projectRoot\dist\lan-iperf-windows.zip" -Force
}
if ($Target -in 'android', 'all') {
    Invoke-Flutter -Arguments @('build', 'apk', '--release')
    Copy-Item -LiteralPath "$projectRoot\build\app\outputs\flutter-apk\app-release.apk" `
        -Destination "$projectRoot\dist\lan-iperf-android.apk" -Force
}
Write-Host "Build output: $projectRoot\dist"
