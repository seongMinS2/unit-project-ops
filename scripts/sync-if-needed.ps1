# Cheap watcher for agent PRs, run every minute during work hours by the Windows task
# "unit-project-pr-watch" (scripts\watch.ps1). A check takes a few seconds and calls no model.
#   - merged PR, issue open    -> gitea.ps1 close-merged (script only, no model)
#   - agent:todo / review comments / conflicts -> start the model run in the background and return
param([switch]$DryRun, [int]$GraceMinutes = 2, [int]$DevQuietMinutes = 3)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
New-Item -ItemType Directory -Force logs | Out-Null
if (-not $env:GITEA_TOKEN) { $env:GITEA_TOKEN = [Environment]::GetEnvironmentVariable('GITEA_TOKEN', 'User') }
$gitea = '.claude/skills/gitea/scripts/gitea.ps1'
function Gitea { powershell -NoProfile -ExecutionPolicy Bypass -File $gitea @args | Out-String | ConvertFrom-Json }
. "$PSScriptRoot\locks.ps1"

# 0. agent PRs closed WITHOUT merge = rejected. Copy the reason from the PR onto the issue (the next
#    attempt only reads the issue) and re-queue it, or block it when no reason was given.
$rejected = @((Gitea handle-rejected -GraceMinutes $GraceMinutes).handled | Where-Object { $_ })
foreach ($r in $rejected) { Write-Host "rejected: PR #$($r.pr) -> issue #$($r.issue) $($r.next) (사유 $($r.reasons)건)" }

# 0b. open agent PRs with review comments nobody answered: revise the branch in place (background,
#     it takes tens of minutes). Closing the PR is only for "wrong approach" — this is "fix this bit".
$feedback = @((Gitea pr-feedback -GraceMinutes $GraceMinutes).prs | Where-Object { $_ })
if ($feedback.Count -gt 0) {
  Write-Host "리뷰 코멘트 미반영: PR #$(($feedback | ForEach-Object { $_.pr }) -join ', #')"
  if (Test-LockHeld 'logs\revise-prs.lock') { Write-Host '  revise-prs already running, skipping' }
  elseif ($DryRun) { Write-Host '  would start revise-prs.ps1' }
  else {
    $rlog = "logs\revise-prs-$(Get-Date -Format 'MMdd-HHmm').log"
    Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts\revise-prs.ps1' -RedirectStandardOutput $rlog -RedirectStandardError "$rlog.err" -WorkingDirectory $root
    Write-Host "  started revise-prs.ps1 in the background -> $rlog"
  }
}

# 1. merged agent PRs whose issue is still open: close them (no model needed)
$toClose = @((Gitea close-merged -DryRun).closed | Where-Object { $_ })
if ($toClose.Count -gt 0) {
  if ($DryRun) { Write-Host "would close: #$(($toClose | ForEach-Object issue) -join ', #')" }
  else { $c = Gitea close-merged; Write-Host "closed: $((@($c.closed) | ForEach-Object { "#$($_.issue) (PR #$($_.pr))" }) -join ', ')" }
}

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
if (Test-LockHeld 'logs\sync-prs.lock') { Write-Host '  sync-prs already running, skipping'; exit 0 }
# Humans usually merge several PRs in a row. Syncing after the first merge means syncing again after
# the next one (an Opus run each), so wait until dev has been quiet for a few minutes.
$devAge = ((Get-Date) - [datetime](Gitea branch-get -Head dev).timestamp).TotalMinutes
if ($devAge -lt $DevQuietMinutes) { Write-Host ("  dev changed {0:N0} min ago, waiting for it to settle ({1} min)" -f $devAge, $DevQuietMinutes); exit 0 }
if ($DryRun) { Write-Host '  would start sync-prs.ps1'; exit 0 }
$slog = "logs\sync-prs-run-$(Get-Date -Format 'MMdd-HHmm').log"
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts\sync-prs.ps1' -RedirectStandardOutput $slog -RedirectStandardError "$slog.err" -WorkingDirectory $root
Write-Host "  started sync-prs.ps1 in the background -> $slog"
