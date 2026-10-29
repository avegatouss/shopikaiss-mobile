param([switch]$DesktopShortcut)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$source = Join-Path $repoRoot 'build/windows/x64/runner/Release'
$manifest = Get-Content -LiteralPath (Join-Path $source 'integration-only.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.production_ready -ne $false -or $manifest.engine_connected -ne $true) { throw 'Build de recette raccorde requis.' }
if ($manifest.dirty -ne $false) { throw 'Compiler depuis un commit propre avant installation.' }
$exeName = 'shopikaiss_terminal.exe'
if ((Get-FileHash -LiteralPath (Join-Path $source $exeName) -Algorithm SHA256).Hash -ne $manifest.executable_sha256) { throw 'Empreinte du build incorrecte.' }
$version = $manifest.commit.Substring(0, 12)
$destination = Join-Path $env:LOCALAPPDATA ('Programs/Shopikaiss-Recette/' + $version)
if (Test-Path -LiteralPath $destination) { throw 'Cette version est deja installee ; aucun fichier remplace.' }
$files = @(Get-ChildItem -LiteralPath $source -Recurse -Force)
if ($files | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'Lien inattendu dans le build.' }
New-Item -ItemType Directory -Path $destination | Out-Null
Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $destination -Recurse
$prefix = $source.TrimEnd('\') + '\'
foreach ($file in $files | Where-Object { !$_.PSIsContainer }) {
    $relative = $file.FullName.Substring($prefix.Length)
    if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath (Join-Path $destination $relative)).Hash) { throw 'Copie incomplete ; raccourci non cree.' }
}
$shell = New-Object -ComObject WScript.Shell
$menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Shopikaiss Recette'
New-Item -ItemType Directory -Path $menu -Force | Out-Null
$links = @(Join-Path $menu 'Shopikaiss Windows - Recette.lnk')
if ($DesktopShortcut) { $links += Join-Path ([Environment]::GetFolderPath('Desktop')) 'Shopikaiss Windows - Recette.lnk' }
foreach ($link in $links) {
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = Join-Path $destination $exeName
    $shortcut.WorkingDirectory = $destination
    $shortcut.Description = 'Caisse Windows de recette - non signee'
    $shortcut.Save()
}
Write-Output ('Installe : ' + (Join-Path $destination $exeName))
Write-Output 'Donnees LocalAppData/ShopiKaiss/caisse conservees. Aucun demarrage automatique ni service ajoute.'
