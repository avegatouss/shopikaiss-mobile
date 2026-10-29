param([string]$CMake)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (!$CMake) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath
    if (!$installation) { throw 'CMake Visual Studio introuvable.' }
    $CMake = Join-Path $installation 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
}
$build = Join-Path $repoRoot 'build/windows-native-tests'
& $CMake -S (Join-Path $repoRoot 'test/windows/native') -B $build -A x64
if ($LASTEXITCODE -ne 0) { throw 'Configuration native en echec.' }
& $CMake --build $build --config Release
if ($LASTEXITCODE -ne 0) { throw 'Compilation native en echec.' }
$ctest = Join-Path (Split-Path $CMake) 'ctest.exe'
& $ctest --test-dir $build -C Release --output-on-failure
if ($LASTEXITCODE -ne 0) { throw 'Verification native en echec.' }
