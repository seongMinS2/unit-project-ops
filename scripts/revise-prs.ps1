# Apply review comments left on open agent PRs: /revise-pr updates the SAME branch, so the PR is
# refreshed instead of closed and rebuilt. One PR at a time; the lock keeps the 30-minute watcher
# from starting a second pass while this one runs.
#
#   scripts\revise-prs.ps1            # all open agent PRs with unanswered human comments
#   scripts\revise-prs.ps1 -Prs "75"  # only these
#   scripts\revise-prs.ps1 -DryRun    # list what would be revised
param([string]$Prs = '', [switch]$DryRun)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. "$PSScriptRoot\locks.ps1"
New-Item -ItemType Directory -Force logs | Out-Null
if (-not $env:GITEA_TOKEN) { $env:GITEA_TOKEN = [Environment]::GetEnvironmentVariable('GITEA_TOKEN', 'User') }
$env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS = '0'   # a full test run must not cut the session short
$gitea = '.claude/skills/gitea/scripts/gitea.ps1'

$targets = @($Prs -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
if ($targets.Count -eq 0) {
  $fb = powershell -NoProfile -ExecutionPolicy Bypass -File $gitea pr-feedback | Out-String | ConvertFrom-Json
  $targets = @($fb.prs | Where-Object { $_ } | ForEach-Object { [int]$_.pr })
}
if ($targets.Count -eq 0) { Write-Host 'no PR feedback to apply'; exit 0 }
Write-Host "리뷰 반영 대상: PR #$($targets -join ', #')"
if ($DryRun) { exit 0 }

$lock = 'logs\revise-prs.lock'
if (Test-LockHeld $lock) { Write-Host 'revise-prs already running'; exit 0 }
Set-Lock $lock
try {
  foreach ($n in $targets) {
    $start = Get-Date
    Write-Host "=== PR #$n 반영 시작 $($start.ToString('HH:mm'))"
    $ErrorActionPreference = 'Continue'   # CLI warnings on stderr must not kill the loop
    "/revise-pr $n" | claude -p --model opus --permission-mode auto --output-format stream-json --verbose > "logs\revise-pr-$n.jsonl" 2> "logs\revise-pr-$n.err"
    $exit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $mins = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
    # The skill leaves a "## 리뷰 반영" comment on success; that comment is also what marks the
    # feedback as answered, so its presence is the outcome check.
    $answered = @(powershell -NoProfile -ExecutionPolicy Bypass -File $gitea pr-feedback | Out-String | ConvertFrom-Json).prs |
      Where-Object { $_ -and [int]$_.pr -eq $n }
    $outcome = if ($answered) { 'unanswered' } else { 'applied' }
    Write-Host "=== PR #$n 결과: $outcome (exit $exit, $mins 분)"
  }
} finally { Clear-Lock $lock }
