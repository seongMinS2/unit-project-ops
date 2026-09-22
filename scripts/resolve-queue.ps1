# Resolve issues one at a time (they share workspace/unit-project, so never in parallel).
# After each run, the issue's labels decide what happens next:
#   agent:pr-open  -> next issue
#   agent:blocked  -> issue-specific problem, recorded, next issue
#   anything else  -> the run itself broke (crash, auth, build tooling): stop the queue
#   scripts\resolve-queue.ps1 -Numbers "13,16,19"
# (a single string: `powershell -File` cannot pass PowerShell arrays)
param([Parameter(Mandatory = $true)][string]$Numbers)
$list = @($Numbers -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
New-Item -ItemType Directory -Force logs | Out-Null
if (-not $env:GITEA_TOKEN) { $env:GITEA_TOKEN = [Environment]::GetEnvironmentVariable('GITEA_TOKEN', 'User') }
$gitea = '.claude/skills/gitea/scripts/gitea.ps1'
$summary = @()

foreach ($n in $list) {
  $start = Get-Date
  Write-Host "=== #$n 시작 $($start.ToString('HH:mm'))"
  claude -p "/resolve-issue $n" --model opus --permission-mode auto --output-format stream-json --verbose > "logs\resolve-$n.jsonl" 2> "logs\resolve-$n.err"
  $exit = $LASTEXITCODE
  $issue = powershell -NoProfile -ExecutionPolicy Bypass -File $gitea issue-get -Number $n | Out-String | ConvertFrom-Json
  $labels = @($issue.labels)
  $outcome = if ($labels -contains 'agent:pr-open') { 'pr-open' } elseif ($labels -contains 'agent:blocked') { 'blocked' } else { 'broken' }
  $mins = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
  $summary += [pscustomobject]@{ issue = $n; outcome = $outcome; exit = $exit; minutes = $mins }
  Write-Host "=== #$n 결과: $outcome (exit $exit, ${mins}분)"
  if ($outcome -eq 'broken') { Write-Host "대기열 중단: #$n 실행이 정상 종료되지 않았습니다. logs\resolve-$n.* 확인"; break }
}
$summary | ConvertTo-Json | Set-Content -Encoding UTF8 "logs\resolve-queue-$($list -join '-').json"
$summary | Format-Table -AutoSize | Out-String | Write-Host
