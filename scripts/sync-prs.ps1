# Runs "/sync-prs" headless (Opus) under a lock. Started in the background by sync-if-needed.ps1 —
# a sync takes tens of minutes and the watcher runs every minute, so it must not wait for it.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if (-not $env:GITEA_TOKEN) { $env:GITEA_TOKEN = [Environment]::GetEnvironmentVariable('GITEA_TOKEN', 'User') }
. "$PSScriptRoot\locks.ps1"

# One sync at a time (the lock is taken over if the holder hangs past the stale window).
$lock = 'logs\sync-prs.lock'
if (Test-LockHeld $lock) { Write-Host 'sync-prs already running, skipping'; exit 0 }
Set-Lock $lock
try {
  $stamp = Get-Date -Format 'MMdd-HHmm'
  $env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS = '0'   # let a full test run finish instead of cutting the session
  $ErrorActionPreference = 'Continue'               # CLI warnings on stderr must not kill this script
  '/sync-prs' | claude -p --model claude-opus-5-5 --permission-mode auto --output-format stream-json --verbose > "logs\sync-prs-$stamp.jsonl" 2> "logs\sync-prs-$stamp.err"
  $ErrorActionPreference = 'Stop'
  $r = Get-Content -Encoding UTF8 "logs\sync-prs-$stamp.jsonl" | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } | Where-Object { $_.type -eq 'result' } | Select-Object -Last 1
  Write-Host "sync-prs finished (is_error=$($r.is_error)):"; Write-Host $r.result
} finally { Clear-Lock $lock }
