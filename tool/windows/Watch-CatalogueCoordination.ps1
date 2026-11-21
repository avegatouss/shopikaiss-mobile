param(
    [string]$Coordination = 'C:\laragon\www\_coordination\caisse-autonome',
    [ValidateRange(1,60)][int]$IntervalMinutes = 5,
    [ValidateRange(1,24)][int]$DurationHours = 5
)
$ErrorActionPreference = 'Stop'
$mutex = New-Object System.Threading.Mutex($false, 'Local\ShopikaissCatalogueCoordinationC')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
    $started = [DateTime]::UtcNow
    $end = $started.AddHours($DurationHours)
    $previous = @{}
    $initialized = $false
    $statePath = Join-Path $Coordination 'VEILLE-C-CATALOGUE.json'
    $eventsPath = Join-Path $Coordination 'VEILLE-C-CATALOGUE-EVENEMENTS.jsonl'
    $stopPath = Join-Path $Coordination 'VEILLE-C-CATALOGUE.stop'
    do {
        $now = [DateTime]::UtcNow
        $changes = @()
        # Only coordination artifacts: no customer data or secrets.
        $files = Get-ChildItem -LiteralPath $Coordination -File |
            Where-Object { $_.Name -match '^(INBOX-[ABC]|JOURNAL|.*CATALOGUE.*)\.md$' }
        foreach ($file in $files) {
            try {
                $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                if ($initialized -and (-not $previous.ContainsKey($file.Name) -or $previous[$file.Name] -ne $hash)) {
                    $changes += $file.Name
                }
                $previous[$file.Name] = $hash
            } catch {
                # A concurrent writer can briefly lock a file; retry next check.
                $changes += ('Lecture a reprendre : ' + $file.Name)
            }
        }
        $initialized = $true
        if ($changes.Count -gt 0) {
            @{ checkedUtc=$now.ToString('o'); files=$changes; action='Relecture requise, aucune integration automatique' } |
                ConvertTo-Json -Compress | Add-Content -LiteralPath $eventsPath -Encoding UTF8
        }
        $stopped = Test-Path -LiteralPath $stopPath
        $finished = $stopped -or $now -ge $end
        $state = @{
            pid=$PID; startedUtc=$started.ToString('o'); endUtc=$end.ToString('o')
            lastCheckUtc=$now.ToString('o'); intervalMinutes=$IntervalMinutes
            status=$(if ($finished) {'complete'} else {'watching'})
            nextCheckUtc=$(if ($finished) {$null} else {$now.AddMinutes($IntervalMinutes).ToString('o')})
            files=$previous; automaticIntegration=$false
        }
        $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$statePath.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$statePath.tmp" -Destination $statePath -Force
        if ($finished) { break }
        # Short waits allow an explicit stop file to end the watcher promptly.
        $next = $now.AddMinutes($IntervalMinutes)
        while ([DateTime]::UtcNow -lt $next -and [DateTime]::UtcNow -lt $end -and -not (Test-Path -LiteralPath $stopPath)) {
            Start-Sleep -Seconds 5
        }
    } while ($true)
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
