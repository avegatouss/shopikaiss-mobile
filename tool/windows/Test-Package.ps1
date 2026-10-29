$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture = Join-Path $repoRoot ('build/package-tests/' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixture)
$exe = Join-Path $fixture 'shopikaiss_terminal.exe'
$integration = Join-Path $fixture 'integration-only.json'
[IO.File]::WriteAllText($exe, 'test fixture, not an executable')
[IO.File]::WriteAllText($integration, '{"production_ready":false}')
$manifest = [ordered]@{
    schema = 1
    production_ready = $false
    files = @(
        [ordered]@{ path = 'shopikaiss_terminal.exe'; sha256 = (Get-FileHash $exe).Hash },
        [ordered]@{ path = 'integration-only.json'; sha256 = (Get-FileHash $integration).Hash }
    )
}
$manifestPath = Join-Path $fixture 'review-package.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
$verify = Join-Path $PSScriptRoot 'Verify-Package.ps1'
& $verify -Directory $fixture
function Assert-Rejected([string]$Case) {
    $rejected = $false
    try { & $verify -Directory $fixture } catch { $rejected = $true }
    if (!$rejected) { throw ('Cas non rejete : ' + $Case) }
    Write-Output ('PASS : ' + $Case)
}
[IO.File]::WriteAllText($exe, 'altered')
Assert-Rejected 'fichier altere'
[IO.File]::WriteAllText($exe, 'test fixture, not an executable')
$extra = Join-Path $fixture 'unexpected.txt'
[IO.File]::WriteAllText($extra, 'extra')
Assert-Rejected 'fichier supplementaire'
Remove-Item -LiteralPath $extra
$manifest.files[0].path = '../outside.exe'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Assert-Rejected 'chemin hors paquet'
Write-Output 'PASS : verification valide et trois refus attendus.'
