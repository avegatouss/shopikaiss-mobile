param([Parameter(Mandatory = $true)][string]$FlutterRoot, [switch]$WithEngine)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$flutter = Join-Path $FlutterRoot 'bin/flutter.bat'
if (!(Test-Path -LiteralPath $flutter)) { throw 'Flutter introuvable.' }
Push-Location $repoRoot
try {
    $defines = @()
    if ($WithEngine) {
        & (Join-Path $PSScriptRoot 'moteur/Build-Moteur.ps1') -FlutterRoot $FlutterRoot
        $bundle = Join-Path $repoRoot 'build/windows-moteur/bundle'
        $engineHash = (Get-FileHash -LiteralPath (Join-Path $bundle 'bin/shopikaiss_moteur.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
        $sqliteHash = (Get-FileHash -LiteralPath (Join-Path $bundle 'lib/sqlite3.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
        $defines = @('--dart-define=SHOPIKAISS_WINDOWS_REVIEW_ENGINE=true', "--dart-define=SHOPIKAISS_ENGINE_SHA256=$engineHash", "--dart-define=SHOPIKAISS_SQLITE_SHA256=$sqliteHash")
    }
    & $flutter build windows @defines --release --no-pub --target lib/src/windows/main_windows.dart
    if ($LASTEXITCODE -ne 0) { throw 'Compilation Windows impossible : consulter les prérequis documentés.' }
    $exe = Join-Path $repoRoot 'build/windows/x64/runner/Release/shopikaiss_terminal.exe'
    if (!(Test-Path -LiteralPath $exe)) { throw 'Exécutable attendu absent.' }
    if ($WithEngine) {
        $engineDestination = Join-Path (Split-Path $exe) 'moteur'
        New-Item -ItemType Directory -Path $engineDestination -Force | Out-Null
        Get-ChildItem -LiteralPath $bundle | Copy-Item -Destination $engineDestination -Recurse -Force
    }
    $commit = (& git rev-parse HEAD).Trim()
    $manifest = [ordered]@{
        production_ready = $false
        reason = 'Build de recette ; distribution production non autorisee.'
        engine_connected = [bool]$WithEngine
        commit = $commit
        dirty = [bool](& git status --porcelain)
        executable_sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
        built_utc = [DateTime]::UtcNow.ToString('o')
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path $exe) 'integration-only.json') -Encoding UTF8
    Write-Output 'Build de revue seulement. Ne pas distribuer en production.'
} finally { Pop-Location }
