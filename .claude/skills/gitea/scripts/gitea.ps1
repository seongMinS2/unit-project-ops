<#
  Gitea API wrapper for unit-project-ops.
  Token is read ONLY from $env:GITEA_TOKEN. Never pass it on the command line.
  All output is JSON on stdout (UTF-8).

  Usage:
    gitea.ps1 ping
    gitea.ps1 repo-ensure   -Repo unit-project-ops [-Description "..."]
    gitea.ps1 labels-sync   [-Repo unit-project]
    gitea.ps1 issue-list    [-State open|closed|all] [-Labels "agent:found"]
    gitea.ps1 issue-get     -Number 12
    gitea.ps1 issue-find-fp -Fingerprint "rule:path:symbol"
    gitea.ps1 issue-create  -Title "..." -BodyFile body.md -Labels "agent:found,severity/high"
    gitea.ps1 issue-comment -Number 12 -BodyFile c.md
    gitea.ps1 label-add     -Number 12 -Labels "agent:in-progress"
    gitea.ps1 label-remove  -Number 12 -Labels "agent:in-progress"
    gitea.ps1 pr-create     -Head agent/issue-12 -Title "..." -BodyFile pr.md [-Base dev]
    gitea.ps1 pr-list       [-State open]
#>
param(
  [Parameter(Position = 0, Mandatory = $true)][string]$Command,
  [string]$Repo,
  [int]$Number,
  [string]$Title,
  [string]$BodyFile,
  [string]$Labels,
  [string]$State = 'open',
  [string]$Fingerprint,
  [string]$Head,
  [string]$Base,
  [string]$Description = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$cfg = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '..\..\..\..\config\ops.json') | ConvertFrom-Json
$labelsFile = Join-Path $PSScriptRoot '..\..\..\..\config\labels.json'
if (-not $Repo) { $Repo = $cfg.targetRepo }
if (-not $Base) { $Base = $cfg.baseBranch }
$api = "$($cfg.giteaUrl)/api/v1"
$owner = $cfg.owner

if (-not $env:GITEA_TOKEN) {
  $env:GITEA_TOKEN = [Environment]::GetEnvironmentVariable('GITEA_TOKEN', 'User')
}
if (-not $env:GITEA_TOKEN) { throw 'GITEA_TOKEN 환경변수가 없습니다. Gitea > 설정 > 애플리케이션에서 토큰을 발급해 사용자 환경변수로 등록하세요.' }

function Invoke-Gitea([string]$Method, [string]$Path, $Body = $null) {
  $headers = @{ Authorization = "token $env:GITEA_TOKEN"; Accept = 'application/json' }
  $params = @{ Method = $Method; Uri = "$api$Path"; Headers = $headers; UseBasicParsing = $true }
  if ($null -ne $Body) {
    $params.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10 -Compress))
    $params.ContentType = 'application/json; charset=utf-8'
  }
  $resp = Invoke-WebRequest @params
  if (-not $resp.Content) { return $null }
  # Decode as UTF-8 explicitly; PS 5.1 may guess the wrong charset.
  $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
  return $text | ConvertFrom-Json
}

function Get-All([string]$Path) {
  $sep = if ($Path.Contains('?')) { '&' } else { '?' }
  $page = 1; $all = @()
  while ($true) {
    # PS 5.1 ConvertFrom-Json emits a JSON array as ONE object; pipe it to unroll (an empty page then yields nothing).
    $batch = @(Invoke-Gitea GET "$Path${sep}limit=50&page=$page" | ForEach-Object { $_ })
    if ($batch.Count -eq 0) { break }
    $all += $batch
    if ($batch.Count -lt 50) { break }
    $page++
  }
  return $all
}

function Read-Body { if (-not $BodyFile) { throw '-BodyFile 가 필요합니다.' }; Get-Content -Raw -Encoding UTF8 $BodyFile }

function Resolve-LabelIds([string]$Names, [string]$R = $Repo) {
  if (-not $Names) { return @() }
  $existing = Get-All "/repos/$owner/$R/labels"
  $ids = @()
  foreach ($n in ($Names -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $l = $existing | Where-Object { $_.name -eq $n } | Select-Object -First 1
    if (-not $l) { throw "라벨 '$n' 이 $R 에 없습니다. 먼저 labels-sync 를 실행하세요." }
    $ids += [int64]$l.id
  }
  return ,$ids
}

# -InputObject keeps arrays as arrays (piping would print nothing for @() and unwrap single items).
function Out-Json($o) { ConvertTo-Json -InputObject $o -Depth 10 }

function Slim-Issue($i) {
  [pscustomobject]@{
    number = $i.number; title = $i.title; state = $i.state
    labels = @($i.labels | ForEach-Object { $_.name }); url = $i.html_url
    updated = $i.updated_at; body = $i.body
  }
}

switch ($Command) {
  'ping' {
    $u = Invoke-Gitea GET '/user'
    $r = Invoke-Gitea GET "/repos/$owner/$($cfg.targetRepo)"
    Out-Json @{ user = $u.login; repo = $r.full_name; defaultBranch = $r.default_branch; openIssues = $r.open_issues_count }
  }
  'repo-ensure' {
    try { $r = Invoke-Gitea GET "/repos/$owner/$Repo"; Out-Json @{ created = $false; url = $r.html_url; clone = $r.clone_url } }
    catch {
      $r = Invoke-Gitea POST '/user/repos' @{ name = $Repo; private = $true; description = $Description; default_branch = 'main'; auto_init = $false }
      Out-Json @{ created = $true; url = $r.html_url; clone = $r.clone_url }
    }
  }
  'labels-sync' {
    $existing = Get-All "/repos/$owner/$Repo/labels"
    $want = Get-Content -Raw -Encoding UTF8 $labelsFile | ConvertFrom-Json
    $created = @()
    foreach ($l in $want) {
      if (-not ($existing | Where-Object { $_.name -eq $l.name })) {
        Invoke-Gitea POST "/repos/$owner/$Repo/labels" @{ name = $l.name; color = $l.color; description = $l.description } | Out-Null
        $created += $l.name
      }
    }
    Out-Json @{ created = $created; total = $want.Count }
  }
  'issue-list' {
    $q = "/repos/$owner/$Repo/issues?type=issues&state=$State"
    if ($Labels) { $q += "&labels=$([uri]::EscapeDataString($Labels))" }
    Out-Json @(Get-All $q | ForEach-Object { $s = Slim-Issue $_; $s.PSObject.Properties.Remove('body'); $s })
  }
  'issue-get' {
    $i = Invoke-Gitea GET "/repos/$owner/$Repo/issues/$Number"
    $c = @(Get-All "/repos/$owner/$Repo/issues/$Number/comments" | ForEach-Object { @{ user = $_.user.login; body = $_.body; at = $_.created_at } })
    $s = Slim-Issue $i
    $s | Add-Member comments $c
    Out-Json $s
  }
  'issue-find-fp' {
    # Fingerprint lives in the body as <!-- fp:... -->. Scan every agent issue (open + closed).
    $needle = "<!-- fp:$Fingerprint -->"
    $hits = @(Get-All "/repos/$owner/$Repo/issues?type=issues&state=all&labels=agent:found" |
      Where-Object { $_.body -and $_.body.Contains($needle) } |
      ForEach-Object { $s = Slim-Issue $_; $s.PSObject.Properties.Remove('body'); $s })
    Out-Json @{ fingerprint = $Fingerprint; matches = $hits }
  }
  'issue-create' {
    $ids = Resolve-LabelIds $Labels
    $i = Invoke-Gitea POST "/repos/$owner/$Repo/issues" @{ title = $Title; body = (Read-Body); labels = $ids }
    Out-Json @{ number = $i.number; url = $i.html_url }
  }
  'issue-comment' {
    $c = Invoke-Gitea POST "/repos/$owner/$Repo/issues/$Number/comments" @{ body = (Read-Body) }
    Out-Json @{ id = $c.id; url = $c.html_url }
  }
  'label-add' {
    $ids = Resolve-LabelIds $Labels
    Invoke-Gitea POST "/repos/$owner/$Repo/issues/$Number/labels" @{ labels = $ids } | Out-Null
    Out-Json @{ number = $Number; added = ($Labels -split ',') }
  }
  'label-remove' {
    foreach ($id in (Resolve-LabelIds $Labels)) {
      try { Invoke-Gitea DELETE "/repos/$owner/$Repo/issues/$Number/labels/$id" | Out-Null } catch { }
    }
    Out-Json @{ number = $Number; removed = ($Labels -split ',') }
  }
  'pr-create' {
    $p = Invoke-Gitea POST "/repos/$owner/$Repo/pulls" @{ head = $Head; base = $Base; title = $Title; body = (Read-Body) }
    Out-Json @{ number = $p.number; url = $p.html_url }
  }
  'pr-list' {
    Out-Json @(Get-All "/repos/$owner/$Repo/pulls?state=$State" | ForEach-Object {
      @{ number = $_.number; title = $_.title; head = $_.head.ref; base = $_.base.ref; url = $_.html_url; merged = $_.merged }
    })
  }
  default { throw "알 수 없는 명령: $Command" }
}
