# Process every issue a human handed to the agents with the `agent:todo` label.
#   1. /plan-todo (Sonnet) groups the issues into lanes by overlapping files -> JSON
#   2. scripts\resolve-lanes.ps1 runs the lanes in parallel, each lane in order
#      (resolve-queue drops agent:todo per issue as it starts it)
#
# Batches may run side by side: an issue labelled while an earlier batch is still working must not wait
# hours for it. The lock only covers planning + launch (two planners would pick the same issues); issues
# already sitting in a running lane are "claimed" and excluded, and the lane budget is shared.
#
#   scripts\run-todo.ps1            # plan + run
#   scripts\run-todo.ps1 -DryRun    # plan only, print lanes, change nothing
#   scripts\run-todo.ps1 -CheckOnly # no lock, no model: prints GO when there is something to plan
param([switch]$DryRun, [switch]$CheckOnly, [int]$MaxLanes = 5)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
New-Item -ItemType Directory -Force logs | Out-Null
if (-not $env:GITEA_TOKEN) { $env:GITEA_TOKEN = [Environment]::GetEnvironmentVariable('GITEA_TOKEN', 'User') }
$gitea = '.claude/skills/gitea/scripts/gitea.ps1'
$stamp = Get-Date -Format 'MMdd-HHmm'

. "$PSScriptRoot\locks.ps1"
$lock = 'logs\run-todo.lock'
if (-not $CheckOnly) {
  if (Test-LockHeld $lock) { Write-Host 'run-todo already planning'; exit 0 }
  Set-Lock $lock
}
try {

# Lanes of earlier batches still running: their issues are claimed, their slots are taken.
$live = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'resolve-queue\.ps1' })
$claimed = @($live | ForEach-Object { [regex]::Match($_.CommandLine, '-Numbers\s+"?([\d,]+)').Groups[1].Value -split ',' } |
  Where-Object { $_ } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
$budget = $MaxLanes - $live.Count

# Cheap pre-check so a day with nothing to do costs no model call.
$todo = @(powershell -NoProfile -ExecutionPolicy Bypass -File $gitea issue-list -Labels 'agent:todo' | Out-String | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.number })
$busy = @('agent:in-progress', 'agent:pr-open')
$cand = @($todo | Where-Object { $claimed -notcontains $_.number -and -not (@($_.labels) | Where-Object { $busy -contains $_ }) } | ForEach-Object { [int]$_.number } | Sort-Object)
if ($cand.Count -eq 0) { Write-Host "새로 맡을 agent:todo 이슈 없음$(if ($claimed) { " (진행 중: #$($claimed -join ', #'))" })"; return }
if ($budget -le 0) { Write-Host "레인 $MaxLanes 개가 모두 사용 중 — #$($cand -join ', #') 는 레인이 비면 시작"; return }

# The watcher calls this every minute. When the last plan deferred everything (overlaps with the running
# lanes) and nothing has changed since, planning again would just burn a model call to defer again.
$sig = "todo=$($cand -join ',')|claimed=$($claimed -join ',')|budget=$budget"
$sigFile = 'logs\plan-todo-idle.sig'
if ((Test-Path $sigFile) -and (Get-Content $sigFile) -eq $sig) { Write-Host "변화 없음 — 지난 계획에서 모두 미룸 ($sig)"; return }
if ($CheckOnly) { Write-Host 'GO'; return }

Write-Host "agent:todo 이슈 $($cand.Count)건: #$($cand -join ', #')$(if ($claimed) { "  (진행 중: #$($claimed -join ', #'), 남은 레인 $budget)" })"
$prompt = "/plan-todo $($cand -join ' ') --max-lanes $budget$(if ($claimed) { " --in-flight $($claimed -join ',')" })"
$prompt | claude -p --model sonnet --permission-mode auto --output-format json > "logs\plan-todo-$stamp.json" 2> "logs\plan-todo-$stamp.err"
$result = (Get-Content -Raw -Encoding UTF8 "logs\plan-todo-$stamp.json" | ConvertFrom-Json).result
$json = [regex]::Match($result, '\{[\s\S]*"lanes"[\s\S]*\}').Value
if (-not $json) { throw "plan-todo 가 계획 JSON 을 내지 않았습니다. logs\plan-todo-$stamp.json 확인" }
$plan = $json | ConvertFrom-Json
$lanes = @($plan.lanes | ForEach-Object { , @($_ | ForEach-Object { [int]$_ } | Where-Object { $cand -contains $_ }) } | Where-Object { $_.Count -gt 0 })
if ($lanes.Count -gt $budget) {   # the planner overshot: fold the extra lanes onto the first ones, in order
  $fold = @(); 1..$budget | ForEach-Object { $fold += , (New-Object Collections.ArrayList) }
  for ($k = 0; $k -lt $lanes.Count; $k++) { [void]$fold[$k % $budget].AddRange(@($lanes[$k])) }
  $lanes = @($fold | ForEach-Object { , @($_) })
}

foreach ($s in @($plan.skipped)) { if ($s) { Write-Host "  건너뜀 #$($s.issue): $($s.reason)" } }
foreach ($d in @($plan.deferred)) { if ($d) { Write-Host "  미룸 #$(if ($d.issue) { "$($d.issue): $($d.reason)" } else { $d })" } }
if ($lanes.Count -eq 0) { Write-Host '처리할 레인 없음'; if (-not $DryRun) { Set-Content $sigFile $sig }; return }
Remove-Item $sigFile -ErrorAction SilentlyContinue
$spec = ($lanes | ForEach-Object { $_ -join ',' }) -join ';'
$i = 0; foreach ($l in $lanes) { $i++; Write-Host "  lane$i : #$($l -join ' -> #')" }
if ($DryRun) { Write-Host "DryRun: LaneSpec = $spec (라벨·실행 변경 없음)"; return }

# Launch, then release the lock as soon as the lanes exist (their issues are now claimed), so the next
# batch can be planned while these run. This process stays to collect the lane summary for its log.
$flag = "logs\lanes-launched-$PID.flag"
$rlog = "logs\resolve-lanes-$stamp.log"
$rl = Start-Process powershell -PassThru -WindowStyle Hidden -WorkingDirectory $root `
  -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts\resolve-lanes.ps1', '-LaneSpec', $spec, '-MaxLanes', $budget, '-LaunchedFlag', $flag `
  -RedirectStandardOutput $rlog -RedirectStandardError "$rlog.err"
while (-not (Test-Path $flag) -and -not $rl.HasExited) { Start-Sleep -Seconds 5 }
Remove-Item $flag -ErrorAction SilentlyContinue
Clear-Lock $lock
$rl.WaitForExit()
Get-Content -Encoding UTF8 $rlog -ErrorAction SilentlyContinue | Write-Host

} finally { Clear-Lock $lock }
