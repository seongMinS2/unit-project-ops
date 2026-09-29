# Entry point of the Windows task "unit-project-pr-watch" (every minute, weekdays 09-19).
# Runs the watcher without any model and keeps a daily log of the checks that actually did something
# (a "nothing to do" line every minute would bury them).
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
New-Item -ItemType Directory -Force logs | Out-Null
$log = "logs\watch-$(Get-Date -Format 'yyyyMMdd').log"
# Output goes through FILES, not a pipe: the watcher starts run-todo/sync-prs in the background, they
# inherit its handles, and a pipe would then stay open (and this task "running") for hours.
$tmp = "logs\watch-run.out"
try {
  $p = Start-Process powershell -PassThru -WindowStyle Hidden -WorkingDirectory $root `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts\sync-if-needed.ps1' `
    -RedirectStandardOutput $tmp -RedirectStandardError "$tmp.err"
  if (-not $p.WaitForExit(240000)) { Stop-Process -Id $p.Id -Force; $out = @('watcher timed out after 4 min') }
  else {
    $out = @(Get-Content -Encoding UTF8 $tmp, "$tmp.err" -ErrorAction SilentlyContinue | Where-Object { $_ })
    if ($p.ExitCode) { $out += "exit code $($p.ExitCode)" }
  }
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
