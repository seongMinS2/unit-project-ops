# Publish the Agent HQ dashboard on the Linux server through an SSH reverse tunnel.
# The dashboard server keeps running on this PC (it reads logs/ here); the Linux box only relays.
#
#   scripts\dashboard-tunnel.ps1 -User <ssh-user>
#
# Linux side: 127.0.0.1:18787 (tunnel end) -> nginx listens on :8787 and proxies to it.
# Starts dashboard\server.ps1 if it is not running, then keeps the tunnel up (reconnects on drop).
param(
  [Parameter(Mandatory = $true)][string]$User,
  [string]$HostName = '172.23.239.8',
  [int]$LocalPort = 8787,
  [int]$RemotePort = 18787
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

function Test-Local {
  try { (Invoke-WebRequest "http://localhost:$LocalPort/api/state" -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200 } catch { $false }
}
if (-not (Test-Local)) {
  Write-Host "dashboard server 시작 (port $LocalPort)"
  Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'dashboard\server.ps1'), '-Port', $LocalPort, '-NoBrowser'
  for ($i = 0; $i -lt 20 -and -not (Test-Local); $i++) { Start-Sleep -Milliseconds 500 }
  if (-not (Test-Local)) { throw "dashboard server 가 port $LocalPort 에서 응답하지 않습니다." }
}

while ($true) {
  Write-Host "$(Get-Date -Format 'HH:mm:ss') 터널 연결: ${HostName}:127.0.0.1:$RemotePort -> localhost:$LocalPort"
  ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 `
    -R "127.0.0.1:${RemotePort}:127.0.0.1:${LocalPort}" "$User@$HostName"
  Write-Host "$(Get-Date -Format 'HH:mm:ss') 터널 끊김 (exit $LASTEXITCODE), 10초 후 재연결"
  Start-Sleep -Seconds 10
}
