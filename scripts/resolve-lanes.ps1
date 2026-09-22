# Run several resolve-issue queues in parallel. Each lane is processed in order by
# resolve-queue.ps1; lanes run side by side, each issue in its own git worktree.
# Put issues that touch the same files in the SAME lane, or their PRs will conflict.
#
#   scripts\resolve-lanes.ps1 -Lanes "13,16,19;11,10;15,14,17,18"
# (lanes separated by ';' in ONE string: `powershell -File` cannot pass PowerShell arrays)
param(
  [Parameter(Mandatory = $true)][string]$LaneSpec,
  [int]$MaxLanes = 3   # each lane runs a full Gradle test suite; 3 fits 28 cores / 32 GB
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$Lanes = @($LaneSpec -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Lanes.Count -gt $MaxLanes) { throw "레인이 $($Lanes.Count)개입니다. 최대 $MaxLanes 개까지 허용됩니다 (-MaxLanes 로 조정)." }

$jobs = @()
$i = 0
foreach ($lane in $Lanes) {
  $i++
  $nums = @($lane -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
  $jobs += Start-Job -Name "lane$i" -ArgumentList $root, ($nums -join ','), $i -ScriptBlock {
    param($root, $spec, $i)
    Set-Location $root
    & powershell -NoProfile -ExecutionPolicy Bypass -File scripts\resolve-queue.ps1 -Numbers $spec *> "logs\lane$i.log"
  }
  Write-Host "lane$i 시작: #$($nums -join ' → #')"
  Start-Sleep -Seconds 20   # stagger so the lanes don't all fetch/create worktrees at the same instant
}
$jobs | Wait-Job | Out-Null
foreach ($j in $jobs) { Write-Host "--- $($j.Name)"; Get-Content -Encoding UTF8 (Join-Path $root "logs\$($j.Name).log") | Select-String '결과|중단' | ForEach-Object { $_.Line } }
