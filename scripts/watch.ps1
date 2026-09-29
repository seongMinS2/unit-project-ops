# Entry point of the Windows task "unit-project-pr-watch" (every minute, weekdays 09-19).
# Runs the watcher without any model and keeps a daily log of the checks that actually did something
# (a "nothing to do" line every minute would bury them).
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
New-Item -ItemType Directory -Force logs | Out-Null
$log = "logs\watch-$(Get-Date -Format 'yyyyMMdd').log"
try {
  $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sync-if-needed.ps1 2>&1 | ForEach-Object { "$_" })
  if ($LASTEXITCODE) { $out += "exit code $LASTEXITCODE" }
} catch { $out = @("watcher failed: $_") }
$quiet = ($out.Count -eq 1 -and $out[0] -eq 'no conflicting agent PRs')
# A waiting state ("lanes all busy", "dev settling") repeats every minute; log it once, not 60 times an hour.
$text = $out -join "`r`n           "
$lastFile = 'logs\watch-last.txt'
$last = if (Test-Path $lastFile) { [IO.File]::ReadAllText((Resolve-Path $lastFile)) } else { '' }
if (-not $quiet -and $text -ne $last) {
  Add-Content -Encoding UTF8 $log ("[$(Get-Date -Format 'HH:mm:ss')] " + $text)
}
[IO.File]::WriteAllText((Join-Path $root $lastFile), $text)
