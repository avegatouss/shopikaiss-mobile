$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$releaseDir = Join-Path $repoRoot 'build/windows/x64/runner/Release'
$executable = Join-Path $releaseDir 'shopikaiss_terminal.exe'
if (!(Test-Path -LiteralPath $executable)) { throw 'Compiler la version de revue avant cet essai.' }
if (Get-Process shopikaiss_terminal -ErrorAction SilentlyContinue) {
    throw 'Une caisse est deja ouverte : essai annule pour la laisser intacte.'
}
# MainWindowHandle ignores hidden windows. Enumerate only our child process,
# then close its real runner window through the normal WM_CLOSE lifecycle.
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class ShopikaissLaunchProbe {
    private delegate bool WindowVisitor(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowVisitor visitor, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int size);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
    public static IntPtr Find(uint process) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((window, unused) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != process) return true;
            var name = new StringBuilder(256);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() != "FLUTTER_RUNNER_WIN32_WINDOW") return true;
            found = window;
            return false;
        }, IntPtr.Zero);
        return found;
    }
}
'@
$reviewApp = Start-Process -FilePath $executable -WorkingDirectory $releaseDir -WindowStyle Hidden -PassThru `
    -RedirectStandardError (Join-Path $repoRoot 'build/windows-launch-stderr.log') `
    -RedirectStandardOutput (Join-Path $repoRoot 'build/windows-launch-stdout.log')
# Retain the process handle before it exits (Windows PowerShell Start-Process).
$processHandle = $reviewApp.Handle
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $window = [IntPtr]::Zero
    do {
        if ($reviewApp.WaitForExit(500)) { throw ('Arret premature : ' + $reviewApp.ExitCode) }
        $window = [ShopikaissLaunchProbe]::Find([uint32]$reviewApp.Id)
    } while ($window -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if ($window -eq [IntPtr]::Zero) { throw 'Fenetre native non creee apres 30 secondes.' }
    if ($reviewApp.WaitForExit(3000)) { throw 'Arret inattendu apres creation de la fenetre.' }
    if (![ShopikaissLaunchProbe]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) {
        throw 'Envoi WM_CLOSE impossible.'
    }
    if (!$reviewApp.WaitForExit(8000)) { throw 'Fermeture normale hors delai.' }
    if ($reviewApp.ExitCode -ne 0) { throw ('Sortie en erreur : ' + $reviewApp.ExitCode) }
    Write-Output 'PASS : fenetre native creee, processus stable, fermeture normale (0).'
    Write-Output 'Essai masque : aucune validation visuelle ni vente ni verification du moteur metier.'
} finally {
    $reviewApp.Refresh()
    if (!$reviewApp.HasExited) { Stop-Process -Id $reviewApp.Id }
}
