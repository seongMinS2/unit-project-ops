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
if (-not $quiet) {
  Add-Content -Encoding UTF8 $log ("[$(Get-Date -Format 'HH:mm:ss')] " + ($out -join "`r`n           "))
}
