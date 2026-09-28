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
    gitea.ps1 pr-get        -Number 28          (mergeable, head/base, body)
    gitea.ps1 close-merged  [-DryRun]           (close issues whose agent/issue-N PR was merged)
    gitea.ps1 handle-rejected [-DryRun]         (PR closed unmerged -> copy reason to issue, re-queue or block)
    gitea.ps1 pr-feedback                       (open agent PRs with human comments not yet answered)
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
  [string]$Description = '',
  [switch]$DryRun
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

# Must be a plain .NET string: Get-Content attaches PSPath/PSProvider/PSDrive note properties, and
# ConvertTo-Json -Depth 10 then walks those provider objects for minutes (looked like a hung API call).
function Read-Body {
  if (-not $BodyFile) { throw '-BodyFile 가 필요합니다.' }
  [IO.File]::ReadAllText((Resolve-Path $BodyFile).ProviderPath, [Text.Encoding]::UTF8)
}

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
      @{ number = $_.number; title = $_.title; head = $_.head.ref; base = $_.base.ref; url = $_.html_url; merged = $_.merged; mergeable = $_.mergeable }
    })
  }
  'close-merged' {
    # Close issues whose agent PR (head agent/issue-N) has been merged by a human.
    # This is the ONLY way agents close issues: the merge itself is the human approval.
    $merged = @(Get-All "/repos/$owner/$Repo/pulls?state=closed" | Where-Object { $_.merged -and $_.head.ref -match '^agent/issue-(\d+)$' })
    $done = @()
    foreach ($p in $merged) {
      $n = [int]([regex]::Match($p.head.ref, '^agent/issue-(\d+)$').Groups[1].Value)
      $i = Invoke-Gitea GET "/repos/$owner/$Repo/issues/$n"
      if ($i.state -ne 'open') { continue }
      $entry = [pscustomobject]@{ issue = $n; pr = $p.number; mergedAt = $p.merged_at; title = $i.title }
      if (-not $DryRun) {
        $msg = "PR #$($p.number) 이 $($p.merged_at) 에 merge 되어 자동으로 닫습니다. 문제가 남아 있으면 다시 열어 주세요."
        Invoke-Gitea POST "/repos/$owner/$Repo/issues/$n/comments" @{ body = $msg } | Out-Null
        foreach ($l in @($i.labels | Where-Object { $_.name -eq 'agent:pr-open' })) {
          try { Invoke-Gitea DELETE "/repos/$owner/$Repo/issues/$n/labels/$($l.id)" | Out-Null } catch { }
        }
        Invoke-Gitea PATCH "/repos/$owner/$Repo/issues/$n" @{ state = 'closed' } | Out-Null
      }
      $done += $entry
    }
    Out-Json @{ dryRun = [bool]$DryRun; closed = $done }
  }
  'pr-feedback' {
    # Open agent PRs where a human commented after our last "## 리뷰 반영" marker = a change request
    # that nothing acts on today (the agents only read issues). Lists them for /revise-pr.
    $mine = '^(##\s*(리뷰 반영|dev 반영 및 충돌 해결|PR #)|에이전트 처리)'
    $out = @()
    foreach ($p in @(Get-All "/repos/$owner/$Repo/pulls?state=open" | Where-Object { $_.head.ref -like 'agent/*' })) {
      $comments = @(Get-All "/repos/$owner/$Repo/issues/$($p.number)/comments")
      $lastMark = @($comments | Where-Object { $_.body -match '^##\s*리뷰 반영' } | Select-Object -Last 1)
      $since = if ($lastMark.Count) { [datetime]$lastMark[0].created_at } else { [datetime]::MinValue }
      $pending = @($comments | Where-Object { $_.body -and $_.body -notmatch $mine -and ([datetime]$_.created_at) -gt $since })
      if ($pending.Count) {
        $out += [pscustomobject]@{ pr = $p.number; head = $p.head.ref; title = $p.title; mergeable = $p.mergeable
          pending = @($pending | ForEach-Object { @{ user = $_.user.login; at = $_.created_at; body = $_.body } }) }
      }
    }
    Out-Json @{ prs = $out }
  }
  'handle-rejected' {
    # An agent PR closed WITHOUT merge is a rejection. The reason is written on the PR, which the next
    # attempt never reads (resolve-issue reads the issue), so copy it onto the issue and re-queue.
    # "보류"/"중단" in the rejection means "don't try again" -> agent:blocked.
    $ours = '^(## PR #|## dev 반영 및 충돌 해결|에이전트 처리|PR #\d+ 이 .* merge 되어)'
    $closed = @(Get-All "/repos/$owner/$Repo/pulls?state=closed" | Where-Object { -not $_.merged -and $_.head.ref -match '^agent/issue-(\d+)$' })
    $done = @()
    foreach ($p in $closed) {
      $n = [int]([regex]::Match($p.head.ref, '^agent/issue-(\d+)$').Groups[1].Value)
      $i = Invoke-Gitea GET "/repos/$owner/$Repo/issues/$n"
      if ($i.state -ne 'open') { continue }
      # NOT $labels: that is the script's [string]$Labels parameter, and assigning an array to it
      # silently joins it into one string, which made this check skip every issue.
      $issueLabels = @($i.labels | ForEach-Object { $_.name })
      if ($issueLabels -notcontains 'agent:pr-open') { continue }   # already handled or never ours
      $reasons = @(Get-All "/repos/$owner/$Repo/issues/$($p.number)/comments" | Where-Object { $_.body -and $_.body -notmatch $ours } |
        ForEach-Object { "> **$($_.user.login)** ($($_.created_at.Substring(0,16))): " + ($_.body -replace "`r?`n", "`n> ") })
      # No stated reason -> do not retry: the next attempt would most likely rebuild the same PR.
      $hold = ($reasons.Count -eq 0) -or (($reasons -join ' ') -match '보류|중단|hold')
      $next = if ($hold) { 'agent:blocked' } else { 'agent:todo' }
      $body = "## PR #$($p.number) 반려됨 (merge 없이 닫힘)`n`n" +
              "- 닫힌 시각: $($p.closed_at)`n- 브랜치 ``$($p.head.ref)`` 는 원격에 남아 있습니다. 다시 시도할 때는 최신 dev 에서 새로 시작합니다.`n`n### 반려 사유`n" +
              $(if ($reasons.Count) { ($reasons -join "`n`n") } else { '닫을 때 남긴 사유가 없습니다. 사유를 모른 채 다시 시도하면 같은 PR 을 또 만들 가능성이 큽니다.' }) +
              "`n`n### 다음`n" +
              $(if ($reasons.Count -eq 0) { '`agent:blocked` 로 두었습니다. **이 이슈에 반려 사유를 코멘트로 남기고 `agent:todo` 라벨을 붙여 주세요.** 그러면 사유를 반영해 다시 시도합니다.' }
                elseif ($hold) { '`agent:blocked` 로 두었습니다. 다시 맡기시려면 `agent:todo` 라벨을 붙여 주세요.' }
                else { '`agent:todo` 로 되돌렸습니다. 다음 처리 회차에서 위 사유를 반영해 다시 시도합니다.' })
      if (-not $DryRun) {
        Invoke-Gitea POST "/repos/$owner/$Repo/issues/$n/comments" @{ body = $body } | Out-Null
        foreach ($l in @($i.labels | Where-Object { $_.name -eq 'agent:pr-open' })) {
          try { Invoke-Gitea DELETE "/repos/$owner/$Repo/issues/$n/labels/$($l.id)" | Out-Null } catch { }
        }
        $id = (Get-All "/repos/$owner/$Repo/labels" | Where-Object { $_.name -eq $next } | Select-Object -First 1).id
        Invoke-Gitea POST "/repos/$owner/$Repo/issues/$n/labels" @{ labels = @([int64]$id) } | Out-Null
      }
      $done += [pscustomobject]@{ issue = $n; pr = $p.number; next = $next; reasons = $reasons.Count }
    }
    Out-Json @{ dryRun = [bool]$DryRun; handled = $done }
  }
  'pr-get' {
    $p = Invoke-Gitea GET "/repos/$owner/$Repo/pulls/$Number"
    Out-Json @{ number = $p.number; title = $p.title; state = $p.state; merged = $p.merged; mergeable = $p.mergeable
      head = $p.head.ref; headSha = $p.head.sha; base = $p.base.ref; mergeBase = $p.merge_base; url = $p.html_url; body = $p.body }
  }
  default { throw "알 수 없는 명령: $Command" }
}
