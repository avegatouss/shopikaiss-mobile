param([Parameter(Mandatory = $true)][string]$FlutterRoot)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$flutter = Join-Path $FlutterRoot 'bin/flutter.bat'
if (!(Test-Path -LiteralPath $flutter)) { throw 'Flutter introuvable.' }
Push-Location $repoRoot
try {
    & $flutter build windows --release --no-pub --target lib/src/windows/main_windows.dart
    if ($LASTEXITCODE -ne 0) { throw 'Compilation Windows impossible : consulter les prérequis documentés.' }
    $exe = Join-Path $repoRoot 'build/windows/x64/runner/Release/shopikaiss_terminal.exe'
    if (!(Test-Path -LiteralPath $exe)) { throw 'Exécutable attendu absent.' }
    $commit = (& git rev-parse HEAD).Trim()
    $manifest = [ordered]@{
        production_ready = $false
        reason = 'Moteur partagé non raccordé ; recette native et intégration requises.'
        commit = $commit
        dirty = [bool](& git status --porcelain)
        executable_sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
        built_utc = [DateTime]::UtcNow.ToString('o')
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path $exe) 'integration-only.json') -Encoding UTF8
    Write-Output 'Build de revue seulement. Ne pas distribuer en production.'
} finally { Pop-Location }
