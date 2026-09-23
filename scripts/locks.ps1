# Shared lock helpers. Dot-source: . "$PSScriptRoot\locks.ps1"
#
# A lock file holds "<pid>|<ISO start time>". A lock is only honoured while its process is alive AND
# younger than $MaxHours — a run that hangs (it happened: a killed headless session left a live but
# stuck PowerShell) must not block every later run for the rest of the day.

function Test-LockHeld([string]$File, [double]$MaxHours = 3) {
  if (-not (Test-Path $File)) { return $false }
  $parts = (Get-Content $File -ErrorAction SilentlyContinue) -split '\|'
  $lockPid = [int]($parts[0])
  if (-not $lockPid -or -not (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) { return $false }
  # [datetime]::TryParse with [ref]$null does not bind in PS 5.1 — parse defensively instead.
  $started = $null
  if ($parts.Count -gt 1) { try { $started = [datetime]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture) } catch { } }
  if ($started -and ((Get-Date) - $started).TotalHours -gt $MaxHours) {
    Write-Host "  stale lock: PID $lockPid running since $($started.ToString('HH:mm')) (> $MaxHours h), taking over"
    try { Stop-Process -Id $lockPid -Force -ErrorAction Stop } catch { }
    return $false
  }
  return $true
}

function Set-Lock([string]$File) { Set-Content $File "$PID|$((Get-Date).ToString('o'))" }
function Clear-Lock([string]$File) { Remove-Item $File -ErrorAction SilentlyContinue }
