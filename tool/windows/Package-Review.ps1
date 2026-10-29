$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$releaseDir = Join-Path $repoRoot 'build/windows/x64/runner/Release'
$integration = Get-Content -LiteralPath (Join-Path $releaseDir 'integration-only.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($integration.production_ready -ne $false) { throw 'Build de revue requis.' }
$sourceItems = @(Get-ChildItem -LiteralPath $releaseDir -Force -Recurse)
if ($sourceItems | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
    throw 'Liens et jonctions interdits dans les fichiers a distribuer.'
}
$id = [Guid]::NewGuid().ToString('N')
$stage = Join-Path $repoRoot ('build/windows-review/' + $id)
[void](New-Item -ItemType Directory -Path $stage)
Get-ChildItem -LiteralPath $releaseDir -Force | Copy-Item -Destination $stage -Recurse
if ((Get-FileHash -LiteralPath (Join-Path $stage 'shopikaiss_terminal.exe') -Algorithm SHA256).Hash -ne $integration.executable_sha256) {
    throw 'Executable different du build annonce.'
}
$prefix = $stage.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$files = @(Get-ChildItem -LiteralPath $stage -Force -File -Recurse | Sort-Object FullName | ForEach-Object {
    [ordered]@{ path = $_.FullName.Substring($prefix.Length).Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
[ordered]@{
    schema = 1
    production_ready = $false
    signed = $false
    build_commit = $integration.commit
    build_dirty = $integration.dirty
    build_utc = $integration.built_utc
    files = $files
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'review-package.json') -Encoding UTF8
& (Join-Path $PSScriptRoot 'Verify-Package.ps1') -Directory $stage
$outputDir = Join-Path $repoRoot 'dist/windows-review'
[void](New-Item -ItemType Directory -Path $outputDir -Force)
$archive = Join-Path $outputDir ('shopikaiss-windows-review-' + $id + '.zip')
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $archive, [IO.Compression.CompressionLevel]::Optimal, $false)
$extracted = Join-Path $repoRoot ('build/windows-review/check-' + $id)
[IO.Compression.ZipFile]::ExtractToDirectory($archive, $extracted)
& (Join-Path $PSScriptRoot 'Verify-Package.ps1') -Directory $extracted
(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash | Set-Content -LiteralPath ($archive + '.sha256') -Encoding ASCII
Write-Output ('Paquet de revue : ' + $archive)
Write-Output 'Non signe, sans installation ni mise a jour automatique. Recette uniquement.'
