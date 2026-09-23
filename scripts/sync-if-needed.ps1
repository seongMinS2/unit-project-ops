# Cheap watcher for agent PRs, meant to run every ~30 min during work hours.
#   - nothing to do            -> exits without calling a model
#   - merged PR, issue open    -> gitea.ps1 close-merged (script only, no model)
#   - agent PR conflicts w/dev -> "/sync-prs" headless (Opus), unless a previous sync is still running
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
New-Item -ItemType Directory -Force logs | Out-Null
if (-not $env:GITEA_TOKEN) { $env:GITEA_TOKEN = [Environment]::GetEnvironmentVariable('GITEA_TOKEN', 'User') }
$gitea = '.claude/skills/gitea/scripts/gitea.ps1'
function Gitea { powershell -NoProfile -ExecutionPolicy Bypass -File $gitea @args | Out-String | ConvertFrom-Json }

# 1. merged agent PRs whose issue is still open: close them (no model needed)
$toClose = @((Gitea close-merged -DryRun).closed | Where-Object { $_ })
if ($toClose.Count -gt 0) {
  if ($DryRun) { Write-Host "would close: #$(($toClose | ForEach-Object issue) -join ', #')" }
  else { $c = Gitea close-merged; Write-Host "closed: $((@($c.closed) | ForEach-Object { "#$($_.issue) (PR #$($_.pr))" }) -join ', ')" }
}

. "$PSScriptRoot\locks.ps1"

# 2. issues handed to the agents with agent:todo — start a run in the background (it can take hours,
#    so this watcher must not wait for it; run-todo.ps1 holds its own lock against a second start).
$todo = @(Gitea issue-list -Labels 'agent:todo' | ForEach-Object { $_ } | Where-Object { $_.number })
if ($todo.Count -gt 0) {
  Write-Host "agent:todo: #$(($todo | ForEach-Object number) -join ', #')"
  if (Test-LockHeld 'logs\run-todo.lock') { Write-Host '  run-todo already running, skipping' }
  elseif (Test-LockHeld 'logs\sync-prs.lock') { Write-Host '  sync-prs running, todo waits for the next check' }
  elseif ($DryRun) { Write-Host '  would start run-todo.ps1' }
  else {
    $log = "logs\run-todo-$(Get-Date -Format 'MMdd-HHmm').log"
    Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts\run-todo.ps1' -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WorkingDirectory $root
    Write-Host "  started run-todo.ps1 in the background -> $log"
  }
}

# 3. open agent PRs that conflict with dev
$conflicts = @(Gitea pr-list -State open | ForEach-Object { $_ } | Where-Object { $_.head -like 'agent/*' -and $_.mergeable -eq $false })
if ($conflicts.Count -eq 0) { Write-Host 'no conflicting agent PRs'; exit 0 }
Write-Host "conflicting agent PRs: #$(($conflicts | ForEach-Object number) -join ', #')"
if ($DryRun) { exit 0 }

# One sync at a time (the lock is taken over if the holder hangs past the stale window).
$lock = 'logs\sync-prs.lock'
if (Test-LockHeld $lock) { Write-Host 'sync-prs already running, skipping'; exit 0 }
Set-Lock $lock
try {
  $stamp = Get-Date -Format 'MMdd-HHmm'
  $env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS = '0'   # let a full test run finish instead of cutting the session
  $ErrorActionPreference = 'Continue'               # CLI warnings on stderr must not kill this script
  '/sync-prs' | claude -p --model opus --permission-mode auto --output-format stream-json --verbose > "logs\sync-prs-$stamp.jsonl" 2> "logs\sync-prs-$stamp.err"
  $ErrorActionPreference = 'Stop'
  $r = Get-Content -Encoding UTF8 "logs\sync-prs-$stamp.jsonl" | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } | Where-Object { $_.type -eq 'result' } | Select-Object -Last 1
  Write-Host "sync-prs finished (is_error=$($r.is_error)):"; Write-Host $r.result
} finally { Clear-Lock $lock }
