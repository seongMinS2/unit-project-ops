# Agent HQ: local dashboard server for unit-project-ops (PowerShell 5.1, no dependencies).
#   powershell -NoProfile -ExecutionPolicy Bypass -File dashboard\server.ps1 [-Port 8787] [-NoBrowser]
# Serves dashboard/*.html|js|css and a read-only JSON API over logs/, state/, reports/ and Gitea.
# The browser does all log parsing; this server only hands out raw jsonl bytes from an offset.
# GITEA_TOKEN stays on this side: it is used for API calls and never sent to the browser.
param([int]$Port = 8787, [switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$dash = $PSScriptRoot
$root = Split-Path $dash -Parent
$logs = Join-Path $root 'logs'
$utf8 = New-Object Text.UTF8Encoding($false)
$cfg = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'config\ops.json') | ConvertFrom-Json
if (-not $env:GITEA_TOKEN) { $env:GITEA_TOKEN = [Environment]::GetEnvironmentVariable('GITEA_TOKEN', 'User') }

$cache = @{}
function Cached([string]$key, [int]$seconds, [scriptblock]$make) {
  $c = $cache[$key]
  if ($c -and ((Get-Date) - $c.at).TotalSeconds -lt $seconds) { return $c.value }
  $v = & $make
  $cache[$key] = @{ at = Get-Date; value = $v }
  return $v
}

function Open-Shared([string]$path) {
  # Writers (claude -p, lane jobs) keep these files open; share everything so we never block them.
  return [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
}
function Read-SharedText([string]$path) {
  $fs = Open-Shared $path
  try { $sr = New-Object IO.StreamReader($fs, $utf8, $true); return $sr.ReadToEnd() } finally { $fs.Dispose() }
}
function To-Epoch([datetime]$t) { return [long]($t.ToUniversalTime() - [datetime]'1970-01-01').TotalMilliseconds }

function Send($ctx, [int]$code, [string]$type, [byte[]]$bytes, [hashtable]$headers = @{}) {
  $res = $ctx.Response
  $res.StatusCode = $code
  $res.ContentType = $type
  $res.Headers['Cache-Control'] = 'no-store'
  foreach ($k in $headers.Keys) { $res.Headers[$k] = [string]$headers[$k] }
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.OutputStream.Close()
}
function Send-Json($ctx, $obj, [int]$code = 200) {
  $json = ConvertTo-Json -InputObject $obj -Depth 8 -Compress
  Send $ctx $code 'application/json; charset=utf-8' $utf8.GetBytes($json)
}

function Get-Procs {
  Cached 'procs' 5 {
    @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
      $cl = [string]$_.CommandLine
      if ($cl -match '/resolve-issue (\d+)') { @{ kind = 'resolve'; issue = [int]$Matches[1]; pid = $_.ProcessId; started = (To-Epoch $_.CreationDate) } }
      elseif ($cl -match '/patrol') { @{ kind = 'patrol'; pid = $_.ProcessId; started = (To-Epoch $_.CreationDate) } }
    })
  }
}

function Get-Runs {
  $files = @(Get-ChildItem $logs -Filter *.jsonl -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object {
    @{ name = $_.Name; size = $_.Length; mtime = (To-Epoch $_.LastWriteTime) }
  })
  $lanes = @(Get-ChildItem $logs -Filter 'lane*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 8 | ForEach-Object {
    $lines = @((Read-SharedText $_.FullName) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 30)
    @{ name = $_.BaseName; mtime = (To-Epoch $_.LastWriteTime); lines = $lines }
  })
  $queues = @(Get-ChildItem $logs -Filter 'resolve-queue-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10 | ForEach-Object {
    $items = $null
    try { $items = @((Read-SharedText $_.FullName) | ConvertFrom-Json) } catch {}
    @{ name = $_.BaseName; mtime = (To-Epoch $_.LastWriteTime); items = $items }
  })
  return @{ now = (To-Epoch (Get-Date)); files = $files; lanes = $lanes; queues = $queues; procs = @(Get-Procs) }
}

function Get-Log($ctx, [string]$name, [long]$from) {
  if ($name -notmatch '^[\w.-]+\.jsonl$') { return Send-Json $ctx @{ error = 'bad name' } 400 }
  $path = Join-Path $logs $name
  if (-not (Test-Path $path)) { return Send-Json $ctx @{ error = 'not found' } 404 }
  $fs = Open-Shared $path
  try {
    $len = $fs.Length
    $reset = 0
    if ($from -gt $len) { $from = 0; $reset = 1 }   # file was rewritten (resolve retry overwrites its log)
    # PS 5.1 `>` writes UTF-16LE (runs started by resolve-lanes); a direct run writes UTF-8. Detect by BOM.
    $bom = New-Object byte[] 2
    $fs.Read($bom, 0, 2) | Out-Null
    $utf16 = ($bom[0] -eq 0xFF -and $bom[1] -eq 0xFE)
    if ($utf16 -and $from -eq 0) { $from = 2 }
    $n = [int][Math]::Min($len - $from, 16MB)
    $buf = New-Object byte[] $n
    $fs.Seek($from, 'Begin') | Out-Null
    $read = 0
    while ($read -lt $n) { $r = $fs.Read($buf, $read, $n - $read); if ($r -le 0) { break }; $read += $r }
    # Hand out complete lines only; the rest is picked up on the next poll.
    $cut = 0
    if ($utf16) {
      for ($i = $read - 2; $i -ge 0; $i -= 2) { if ($buf[$i] -eq 10 -and $buf[$i + 1] -eq 0) { $cut = $i + 2; break } }
      $out = $utf8.GetBytes([Text.Encoding]::Unicode.GetString($buf, 0, $cut))
    } else {
      if ($read -gt 0) { $cut = [Array]::LastIndexOf($buf, [byte]10, $read - 1) + 1 }
      $out = New-Object byte[] $cut
      [Array]::Copy($buf, $out, $cut)
    }
    Send $ctx 200 'text/plain; charset=utf-8' $out @{ 'X-Next-Offset' = ($from + $cut); 'X-Reset' = $reset; 'X-Size' = $len }
  } finally { $fs.Dispose() }
}

function Invoke-Gitea([string]$path) {
  $headers = @{ Authorization = "token $env:GITEA_TOKEN"; Accept = 'application/json' }
  $resp = Invoke-WebRequest -Uri "$($cfg.giteaUrl)/api/v1$path" -Headers $headers -UseBasicParsing -TimeoutSec 10
  return ($utf8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json)
}
function Get-Gitea {
  if (-not $env:GITEA_TOKEN) { return @{ error = 'GITEA_TOKEN not set' } }
  Cached 'gitea' 30 {
    try {
      $repo = "/repos/$($cfg.owner)/$($cfg.targetRepo)"
      $issues = @(Invoke-Gitea "$repo/issues?state=all&type=issues&limit=50" | ForEach-Object {
        @{ number = $_.number; title = $_.title; state = $_.state; updated = $_.updated_at; url = $_.html_url
           labels = @($_.labels | ForEach-Object { $_.name }) }
      })
      $pulls = @(Invoke-Gitea "$repo/pulls?state=all&limit=30" | ForEach-Object {
        @{ number = $_.number; title = $_.title; state = $_.state; merged = $_.merged; head = $_.head.ref; updated = $_.updated_at; url = $_.html_url }
      })
      @{ at = (To-Epoch (Get-Date)); issues = $issues; pulls = $pulls; webUrl = "$($cfg.giteaUrl)/$($cfg.owner)/$($cfg.targetRepo)" }
    } catch { @{ error = $_.Exception.Message } }
  }
}

function Get-State {
  $patrol = $null
  try { $patrol = Read-SharedText (Join-Path $root 'state\patrol.json') | ConvertFrom-Json } catch {}
  $reports = @(Get-ChildItem (Join-Path $root 'reports') -Filter '20*.md' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 14 | ForEach-Object { $_.Name })
  return @{ patrol = $patrol; reports = $reports }
}

$mime = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.svg' = 'image/svg+xml' }
function Serve-Static($ctx, [string]$p) {
  if ($p -eq '/') { $p = '/index.html' }
  $name = $p.TrimStart('/')
  if ($name -notmatch '^[\w.-]+$' -or -not $mime.ContainsKey([IO.Path]::GetExtension($name))) { return Send-Json $ctx @{ error = 'not found' } 404 }
  $file = Join-Path $dash $name
  if (-not (Test-Path $file)) { return Send-Json $ctx @{ error = 'not found' } 404 }
  Send $ctx 200 $mime[[IO.Path]::GetExtension($name)] ([IO.File]::ReadAllBytes($file))
}

# 대기 중인 agent:todo 이슈 처리를 지금 시작한다(감시 작업의 30분 주기를 기다리지 않게).
# POST 만 받는다 — 이 대시보드에는 인증이 없어서, GET 으로 열리면 링크 미리보기나 크롤러가 실행시킬 수 있다.
function Start-RunTodo($ctx) {
  if ($ctx.Request.HttpMethod -ne 'POST') { return Send-Json $ctx @{ error = 'POST only' } 405 }
  $lock = Join-Path $root 'logs\run-todo.lock'
  if (Test-Path $lock) {
    $lockPid = [int](((Get-Content $lock -ErrorAction SilentlyContinue) -split '\|')[0])
    if ($lockPid -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
      return Send-Json $ctx @{ started = $false; reason = 'already-running'; pid = $lockPid }
    }
  }
  $log = "logs\run-todo-dash-$(Get-Date -Format 'MMdd-HHmm').log"
  Start-Process powershell -WindowStyle Hidden -WorkingDirectory $root `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts\run-todo.ps1' `
    -RedirectStandardOutput (Join-Path $root $log) -RedirectStandardError (Join-Path $root "$log.err") | Out-Null
  Send-Json $ctx @{ started = $true; log = [IO.Path]::GetFileName($log) }
}

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Agent HQ: http://localhost:$Port/  (Ctrl+C to stop)"
if (-not $NoBrowser) { Start-Process "http://localhost:$Port/" }
try {
  while ($listener.IsListening) {
    $task = $listener.GetContextAsync()
    while (-not $task.AsyncWaitHandle.WaitOne(500)) {}   # poll so Ctrl+C can interrupt
    $ctx = $task.GetAwaiter().GetResult()
    $url = $ctx.Request.Url
    $q = [Web.HttpUtility]::ParseQueryString($url.Query)
    try {
      switch ($url.AbsolutePath) {
        '/api/runs'  { Send-Json $ctx (Get-Runs) }
        '/api/log'   { Get-Log $ctx $q['name'] ([long]("0" + $q['from'])) }
        '/api/gitea' { Send-Json $ctx (Get-Gitea) }
        '/api/state' { Send-Json $ctx (Get-State) }
        '/api/run-todo' { Start-RunTodo $ctx }
        default      { Serve-Static $ctx $url.AbsolutePath }
      }
    } catch {
      Write-Host "ERR $($url.AbsolutePath): $($_.Exception.Message)"
      try { Send-Json $ctx @{ error = $_.Exception.Message } 500 } catch {}
    }
  }
} finally { $listener.Stop() }
