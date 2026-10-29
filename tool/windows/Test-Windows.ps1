param([Parameter(Mandatory = $true)][string]$FlutterRoot)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$flutter = Join-Path $FlutterRoot 'bin/flutter.bat'
$dart = Join-Path $FlutterRoot 'bin/cache/dart-sdk/bin/dart.exe'
if (!(Test-Path -LiteralPath $flutter) -or !(Test-Path -LiteralPath $dart)) {
    throw 'Flutter et Dart doivent être installés avant les tests.'
}
$previousDart = $env:SHOPIKAISS_DART_EXECUTABLE
Push-Location $repoRoot
try {
    $env:SHOPIKAISS_DART_EXECUTABLE = $dart
    & $dart analyze lib/src/windows test/windows
    if ($LASTEXITCODE -ne 0) { throw 'Analyse Windows en échec.' }
    & $flutter test --no-pub test/windows
    if ($LASTEXITCODE -ne 0) { throw 'Tests Windows en échec.' }
} finally {
    $env:SHOPIKAISS_DART_EXECUTABLE = $previousDart
    Pop-Location
}
