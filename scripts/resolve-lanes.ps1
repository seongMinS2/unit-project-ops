# Run several resolve-issue queues in parallel. Each lane is processed in order by
# resolve-queue.ps1; lanes run side by side, each issue in its own git worktree.
# Put issues that touch the same files in the SAME lane, or their PRs will conflict.
#
#   scripts\resolve-lanes.ps1 -LaneSpec "13,16,19;11,10;15,14,17,18"
# (lanes separated by ';' in ONE string: `powershell -File` cannot pass PowerShell arrays)
#
# Lanes are separate PROCESSES, not PowerShell jobs: a job's runspace only completes once every
# grandchild closes the inherited pipe, and the Gradle daemon started by a test run keeps it open for
# hours — the launcher then sat "running" long after the lanes were done, holding the run-todo lock.
param(
  [Parameter(Mandatory = $true)][string]$LaneSpec,
  [int]$MaxLanes = 3,          # each lane runs a full Gradle test suite; 3 fits 28 cores / 32 GB
  [int]$TimeoutHours = 6       # a lane that outlives this is killed so the lock cannot be held forever
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$Lanes = @($LaneSpec -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Lanes.Count -gt $MaxLanes) { throw "레인이 $($Lanes.Count)개입니다. 최대 $MaxLanes 개까지 허용됩니다 (-MaxLanes 로 조정)." }

$stamp = Get-Date -Format 'MMdd-HHmm'
$runs = @()
$i = 0
foreach ($lane in $Lanes) {
  $i++
  $nums = @($lane -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
  $log = "logs\lane$i-$stamp.log"
  $p = Start-Process powershell -PassThru -WindowStyle Hidden -WorkingDirectory $root `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts\resolve-queue.ps1', '-Numbers', ($nums -join ',') `
    -RedirectStandardOutput $log -RedirectStandardError "$log.err"
  $runs += [pscustomobject]@{ name = "lane$i"; proc = $p; log = $log }
  Write-Host "lane$i (PID $($p.Id)) 시작: #$($nums -join ' → #')"
  Start-Sleep -Seconds 20   # stagger so the lanes don't all fetch/create worktrees at the same instant
}

$deadline = (Get-Date).AddHours($TimeoutHours)
foreach ($r in $runs) {
  $left = [int]($deadline - (Get-Date)).TotalMilliseconds
  if ($left -le 0 -or -not $r.proc.WaitForExit($left)) {
    Write-Host "$($r.name) 이 $TimeoutHours 시간을 넘겨 종료합니다 (PID $($r.proc.Id))"
    try { Stop-Process -Id $r.proc.Id -Force -ErrorAction Stop } catch { }
  }
}
foreach ($r in $runs) {
  Write-Host "--- $($r.name)"
  Get-Content -Encoding UTF8 $r.log -ErrorAction SilentlyContinue | Select-String 'result|stopped|re-queued' | ForEach-Object { '   ' + $_.Line }
}
