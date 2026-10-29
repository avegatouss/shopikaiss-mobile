param([Parameter(Mandatory = $true)][string]$FlutterRoot)
$ErrorActionPreference = 'Stop'
# Construit l'hôte du moteur de caisse Windows : build/windows-moteur/bundle/bin/shopikaiss_moteur.exe et
# bundle/lib/sqlite3.dll (hook natif du paquet sqlite3). Paquet séparé : l'APK Android n'embarque pas cette DLL.
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$flutter = Join-Path $FlutterRoot 'bin/flutter.bat'
$dart = Join-Path $FlutterRoot 'bin/cache/dart-sdk/bin/dart.exe'
if (!(Test-Path -LiteralPath $flutter) -or !(Test-Path -LiteralPath $dart)) { throw 'Flutter et Dart doivent être installés.' }
$output = Join-Path $repoRoot 'build/windows-moteur'
Push-Location $PSScriptRoot
try {
    # Versions verrouillées : pubspec.lock de l'hôte aligné sur celui de l'application (aucune résolution réseau).
    & $flutter pub get --offline --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Dépendances de l’hôte non résolues avec le verrou.' }
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
    & $dart build cli -o $output
    if ($LASTEXITCODE -ne 0) { throw 'Construction de l’hôte impossible.' }
    $exe = Join-Path $output 'bundle/bin/shopikaiss_moteur.exe'
    $dll = Join-Path $output 'bundle/lib/sqlite3.dll'
    if (!(Test-Path -LiteralPath $exe) -or !(Test-Path -LiteralPath $dll)) { throw 'Exécutable ou sqlite3.dll absent.' }
    $manifest = [ordered]@{
        production_ready = $false
        reason = 'Hôte non signé ; recette native et distribution signée requises.'
        commit = (& git -C $repoRoot rev-parse HEAD).Trim()
        dirty = [bool](& git -C $repoRoot status --porcelain)
        moteur_sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
        sqlite3_sha256 = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
        built_utc = [DateTime]::UtcNow.ToString('o')
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'bundle/integration-only.json') -Encoding UTF8
    Write-Output "Hôte construit : $exe"
} finally { Pop-Location }
