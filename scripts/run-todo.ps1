# Process every issue a human handed to the agents with the `agent:todo` label.
#   1. /plan-todo (Sonnet) groups the issues into lanes by overlapping files -> JSON
#   2. swap agent:todo off (resolve-issue then sets agent:in-progress) so the next run won't pick them again
#   3. scripts\resolve-lanes.ps1 runs the lanes in parallel, each lane in order
#
#   scripts\run-todo.ps1            # plan + run
#   scripts\run-todo.ps1 -DryRun    # plan only, print lanes, change nothing
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
New-Item -ItemType Directory -Force logs | Out-Null
if (-not $env:GITEA_TOKEN) { $env:GITEA_TOKEN = [Environment]::GetEnvironmentVariable('GITEA_TOKEN', 'User') }
$gitea = '.claude/skills/gitea/scripts/gitea.ps1'
$stamp = Get-Date -Format 'MMdd-HHmm'

# One todo run at a time. Lanes can take hours, and the 30-minute watcher starts this script too;
# a second run would create the same worktrees and clash with the first (that happened once on PR #37).
$lock = 'logs\run-todo.lock'
if (Test-Path $lock) {
  $lockPid = [int](Get-Content $lock -ErrorAction SilentlyContinue)
  if ($lockPid -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) { Write-Host "run-todo already running (PID $lockPid)"; exit 0 }
}
Set-Content $lock $PID
try {

# Cheap pre-check so a day with nothing to do costs no model call.
$todo = @(powershell -NoProfile -ExecutionPolicy Bypass -File $gitea issue-list -Labels 'agent:todo' | Out-String | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.number })
if ($todo.Count -eq 0) { Write-Host 'agent:todo 이슈 없음'; return }
Write-Host "agent:todo 이슈 $($todo.Count)건: #$(($todo | ForEach-Object number) -join ', #')"

'/plan-todo' | claude -p --model sonnet --permission-mode auto --output-format json > "logs\plan-todo-$stamp.json" 2> "logs\plan-todo-$stamp.err"
$result = (Get-Content -Raw -Encoding UTF8 "logs\plan-todo-$stamp.json" | ConvertFrom-Json).result
$json = [regex]::Match($result, '\{[\s\S]*"lanes"[\s\S]*\}').Value
if (-not $json) { throw "plan-todo 가 계획 JSON 을 내지 않았습니다. logs\plan-todo-$stamp.json 확인" }
$plan = $json | ConvertFrom-Json
$lanes = @($plan.lanes | ForEach-Object { , @($_ | ForEach-Object { [int]$_ }) } | Where-Object { $_.Count -gt 0 })

foreach ($s in @($plan.skipped)) { if ($s) { Write-Host "  건너뜀 #$($s.issue): $($s.reason)" } }
foreach ($d in @($plan.deferred)) { if ($d) { Write-Host "  다음 실행으로 미룸 #$d" } }
if ($lanes.Count -eq 0) { Write-Host '처리할 레인 없음'; return }
$spec = ($lanes | ForEach-Object { $_ -join ',' }) -join ';'
$i = 0; foreach ($l in $lanes) { $i++; Write-Host "  lane$i : #$($l -join ' -> #')" }
if ($DryRun) { Write-Host "DryRun: LaneSpec = $spec (라벨·실행 변경 없음)"; return }

foreach ($n in ($lanes | ForEach-Object { $_ })) {
  powershell -NoProfile -ExecutionPolicy Bypass -File $gitea label-remove -Number $n -Labels 'agent:todo' | Out-Null
}
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\resolve-lanes.ps1 -LaneSpec $spec -MaxLanes 3

} finally { Remove-Item $lock -ErrorAction SilentlyContinue }
