# Prints one line per lane event plus which resolve-issue sessions are alive. Used by monitors.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Set-Location (Split-Path $PSScriptRoot -Parent)
Get-ChildItem logs\lane*.log -ErrorAction SilentlyContinue | ForEach-Object {
  $n = $_.BaseName
  Get-Content -Encoding UTF8 $_.FullName -ErrorAction SilentlyContinue | Select-String '=== #|중단|Exception' | ForEach-Object { "$n " + $_.Line.Trim() }
}
$alive = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
  Where-Object { $_.CommandLine -match '/resolve-issue (\d+)' } |
  ForEach-Object { [regex]::Match($_.CommandLine, '/resolve-issue (\d+)').Groups[1].Value } | Sort-Object -Unique)
if ($alive.Count -eq 0) { 'IDLE' } else { 'RUNNING #' + ($alive -join ',#') }
