param([Parameter(Mandatory = $true)][string]$Directory)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $Directory).Path.TrimEnd('\', '/')
$prefix = $root + [IO.Path]::DirectorySeparatorChar
$items = @(Get-Item -LiteralPath $root) + @(Get-ChildItem -LiteralPath $root -Force -Recurse)
if ($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
    throw 'Liens et jonctions interdits dans le paquet.'
}
$manifestPath = Join-Path $root 'review-package.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.schema -ne 1 -or $manifest.production_ready -ne $false -or !$manifest.files) {
    throw 'Manifeste de revue absent ou invalide.'
}
$expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
[void]$expected.Add('review-package.json')
foreach ($file in $manifest.files) {
    if (!$file.path -or [IO.Path]::IsPathRooted($file.path) -or $file.path.Contains(':')) { throw 'Chemin invalide.' }
    $full = [IO.Path]::GetFullPath((Join-Path $root $file.path))
    if (!$full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Chemin hors du paquet.' }
    $relative = $full.Substring($prefix.Length).Replace('\', '/')
    if (!$expected.Add($relative)) { throw 'Chemin duplique dans le manifeste.' }
    if (!(Test-Path -LiteralPath $full -PathType Leaf)) { throw ('Fichier absent : ' + $relative) }
    if ($file.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ne $file.sha256) {
        throw ('Integrite invalide : ' + $relative)
    }
}
foreach ($file in $items | Where-Object { !$_.PSIsContainer }) {
    $relative = $file.FullName.Substring($prefix.Length).Replace('\', '/')
    if (!$expected.Contains($relative)) { throw ('Fichier non declare : ' + $relative) }
}
if (!$expected.Contains('shopikaiss_terminal.exe') -or !$expected.Contains('integration-only.json')) {
    throw 'Paquet incomplet.'
}
Write-Output ('Integrite valide : ' + $manifest.files.Count + ' fichiers. Revue uniquement, non signe.')
