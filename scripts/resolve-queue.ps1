# Resolve issues in order within one lane (other lanes may run in parallel; each issue has its own worktree).
# After each run, the issue's labels decide what happens next:
#   agent:pr-open  -> next issue
#   agent:blocked  -> issue-specific problem, recorded, next issue
#   API error      -> transient (500/529/overloaded): clear our stale label + worktree, retry with backoff
#   anything else  -> the run itself broke (auth, build tooling, ...): stop the lane
#
#   scripts\resolve-queue.ps1 -Numbers "13,16,19"
# (a single string: `powershell -File` cannot pass PowerShell arrays)
param(
  [Parameter(Mandatory = $true)][string]$Numbers,
  [int]$MaxApiRetries = 2
)
$list = @($Numbers -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
New-Item -ItemType Directory -Force logs | Out-Null
if (-not $env:GITEA_TOKEN) { $env:GITEA_TOKEN = [Environment]::GetEnvironmentVariable('GITEA_TOKEN', 'User') }
$gitea = '.claude/skills/gitea/scripts/gitea.ps1'
function Gitea { powershell -NoProfile -ExecutionPolicy Bypass -File $gitea @args | Out-String }

function Get-RunError([string]$jsonl) {
  $r = Get-Content -Encoding UTF8 $jsonl -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } |
    Where-Object { $_.type -eq 'result' } | Select-Object -Last 1
  if ($r -and $r.is_error) { return [string]$r.result }
  return $null
}

# Undo what an interrupted run left behind so the retry passes resolve-issue's pre-checks.
function Reset-Attempt([int]$n) {
  Gitea label-remove -Number $n -Labels 'agent:in-progress' | Out-Null
  $wt = "C:/dev/unit-project-ops/workspace/wt/issue-$n"
  if (Test-Path $wt) {
    $ahead = git -C $wt rev-list --count origin/dev..HEAD 2>$null
    if ($ahead -eq '0') { git -C workspace/unit-project worktree remove --force $wt 2>$null }
    else { Write-Host "  #$n worktree 에 커밋 $ahead 개가 있어 보존합니다: $wt" }
  }
}

$summary = @()
foreach ($n in $list) {
  $start = Get-Date
  $attempt = 0
  while ($true) {
    $attempt++
    Write-Host "=== #$n start $($start.ToString('HH:mm')) (attempt $attempt)"
    claude -p "/resolve-issue $n" --model opus --permission-mode auto --output-format stream-json --verbose > "logs\resolve-$n.jsonl" 2> "logs\resolve-$n.err"
    $exit = $LASTEXITCODE
    $labels = @((Gitea issue-get -Number $n | ConvertFrom-Json).labels)
    $outcome = if ($labels -contains 'agent:pr-open') { 'pr-open' } elseif ($labels -contains 'agent:blocked') { 'blocked' } else { 'broken' }
    $apiErr = Get-RunError "logs\resolve-$n.jsonl"
    if ($outcome -eq 'broken' -and $apiErr -match 'API Error: (5\d\d|529)|Overloaded' -and $attempt -le $MaxApiRetries) {
      Copy-Item "logs\resolve-$n.jsonl" "logs\resolve-$n.attempt$attempt.jsonl" -Force
      Write-Host "  #$n API error, retrying in $(60 * $attempt)s: $($apiErr -replace '\s+',' ')"
      Reset-Attempt $n
      Start-Sleep -Seconds (60 * $attempt)
      continue
    }
    break
  }
  $mins = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
  $summary += [pscustomobject]@{ issue = $n; outcome = $outcome; attempts = $attempt; exit = $exit; minutes = $mins }
  Write-Host "=== #$n result: $outcome (attempts $attempt, exit $exit, $mins min)"
  if ($outcome -eq 'broken') {
    # The run itself failed (not an agent decision like `blocked`): hand the issue back to the
    # agent:todo queue so the next scheduled run retries it, and stop this lane.
    Reset-Attempt $n
    Gitea label-add -Number $n -Labels 'agent:todo' | Out-Null
    Write-Host "=== lane stopped at #${n} (re-queued as agent:todo): $($apiErr -replace '\s+',' ') -- see logs\resolve-$n.*"
    break
  }
}
$summary | ConvertTo-Json | Set-Content -Encoding UTF8 "logs\resolve-queue-$($list -join '-').json"
$summary | Format-Table -AutoSize | Out-String | Write-Host
