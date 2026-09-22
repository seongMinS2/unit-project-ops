# PreToolUse guard for unit-project-ops.
# Blocks (exit 2): pushes to unit-project dev/main, force pushes, merges in the workspace,
# Gitea merge API calls, and any touch of the user's own checkout C:\dev\unit-project.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$raw = [Console]::In.ReadToEnd()
try { $in = $raw | ConvertFrom-Json } catch { exit 0 }

function Block([string]$why) {
  [Console]::Error.WriteLine("BLOCKED by unit-project-ops guard: $why")
  exit 2
}

# C:\dev\unit-project, /c/dev/unit-project — but not unit-project-ops or workspace/unit-project
$userCheckout = '(?i)(^|[\s"''=:])(c:|/c|/mnt/c)?[\\/]+dev[\\/]+unit-project(?![\w-])'

$tool = $in.tool_name
if ($tool -in @('Edit', 'Write', 'NotebookEdit')) {
  $p = [string]$in.tool_input.file_path
  if ($p -match '(?i)^(c:|/c|/mnt/c)?[\\/]+dev[\\/]+unit-project([\\/]|$)') {
    Block "사용자 작업 폴더($p)는 수정할 수 없습니다. workspace/unit-project 를 사용하세요."
  }
  exit 0
}


if ($tool -notin @('Bash', 'PowerShell')) { exit 0 }
$cmd = [string]$in.tool_input.command
$cwd = [string]$in.cwd

if ($cmd -match $userCheckout) {
  Block '사용자 작업 폴더 C:\dev\unit-project 를 대상으로 하는 명령은 허용되지 않습니다.'
}
if ($cmd -match '(?i)/pulls/\d+/merge') {
  Block 'PR merge 는 사람만 수행합니다.'
}

function Resolve-Dir([string]$base, [string]$p) {
  $p = $p -replace '^(?i)/(mnt/)?([a-z])/', '$2:/'          # /c/dev -> c:/dev
  try {
    if (-not [IO.Path]::IsPathRooted($p) -or $p -match '^[\\/]') { $p = Join-Path $base $p }
    return [IO.Path]::GetFullPath($p)
  } catch { return $p }
}

# Variables assigned inside the command itself ($wt = "...", wt="...") so `git -C $wt` can be resolved.
$vars = @{}
foreach ($m in [regex]::Matches($cmd, '(?:^|[\s;&])\$?(\w+)\s*=\s*["'']([^"'']+)["'']')) { $vars[$m.Groups[1].Value] = $m.Groups[2].Value }
function Expand([string]$s) {
  [regex]::Replace($s, '\$\{?(\w+)\}?', { param($x) if ($vars.ContainsKey($x.Groups[1].Value)) { $vars[$x.Groups[1].Value] } else { $x.Value } })
}

# Branches that the command itself will create for a worktree path (worktree add -B <branch> <path>),
# so a merge in a worktree created earlier in the same command can be judged before it exists.
$plannedBranch = @{}
foreach ($m in [regex]::Matches($cmd, '(?i)worktree\s+add\s+-[bB]\s+(\S+)\s+("?)([^";&|\s]+)\2')) {
  $plannedBranch[(Resolve-Dir $cwd (Expand $m.Groups[3].Value)).TrimEnd('\')] = $m.Groups[1].Value
}

# Judge every git invocation on its own: each segment's repo is its own `git -C`, else the latest
# `cd` before it, else the session cwd. (A single target for the whole command line mis-judged
# `git -C clone fetch; ...; git -C $wt merge origin/dev`.)
$cur = $cwd
foreach ($seg in ($cmd -split '(?:;|&&|\|\||\r?\n)')) {
  foreach ($m in [regex]::Matches($seg, '(?i)(?:^|\s)(?:cd|Set-Location)\s+("?)([^";&|\s]+)\1')) {
    $cur = Resolve-Dir $cur (Expand $m.Groups[2].Value)
  }
  if ($cur -match '(?i)^c:[\\/]+dev[\\/]+unit-project([\\/]|$)') {
    Block '사용자 작업 폴더 C:\dev\unit-project 로 이동하거나 그 안에서 명령을 실행할 수 없습니다.'
  }
  if ($seg -notmatch '(?i)\bgit\b') { continue }
  $target = $cur
  if ($seg -match '(?i)\bgit\s+-C\s+("?)([^";&|\s]+)\1') { $target = Resolve-Dir $cur (Expand $Matches[2]) }
  if ($target -match '(?i)^c:[\\/]+dev[\\/]+unit-project([\\/]|$)') {
    Block '사용자 작업 폴더 C:\dev\unit-project 에서 git 을 실행할 수 없습니다.'
  }
  $inWorkspace = $target -match '(?i)workspace[\\/]+(unit-project|wt)([\\/]|$)'

  if ($seg -match '(?i)\bgit\b.*\bpush\b(.*)$') {
    $push = ' ' + $Matches[1]
    if ($push -match '(?i)(\s--force(-with-lease)?\b|\s-f\b|\s\+\S)') {
      Block 'force push 는 허용되지 않습니다.'
    }
    if ($inWorkspace -and $push -match '(?i)(\s|:)(dev|main|master)(\s|$)') {
      Block 'unit-project 의 dev/main 으로 직접 push 할 수 없습니다. agent/issue-N 브랜치와 PR 을 사용하세요.'
    }
    if ($inWorkspace -and $push -match '(?i)\s--(all|mirror)\b') {
      Block 'push --all/--mirror 는 허용되지 않습니다.'
    }
  }

  # The only merge allowed in the workspace: bringing origin/dev INTO an agent/* branch inside an
  # issue worktree (how sync-prs resolves PR conflicts without a force push), plus --abort/--continue.
  $mm = [regex]::Match($seg, '(?i)\bgit\b.*\bmerge\b(?!-)(.*)$')
  if ($inWorkspace -and $mm.Success) {
    $margs = $mm.Groups[1].Value
    $stripped = $margs -replace '(?i)\s--(no-ff|no-edit|no-commit)\b', ''
    $allowedForm = ($margs -match '(?i)^\s*--(abort|continue)\s*$') -or ($stripped -match '(?i)^\s*origin/dev\s*$')
    if (-not $allowedForm) {
      Block '작업 공간에서 허용되는 merge 는 "git merge --no-edit origin/dev" (에이전트 브랜치로 dev 를 가져오기) 와 --abort/--continue 뿐입니다.'
    }
    if ($target -notmatch '(?i)workspace[\\/]+wt[\\/]') {
      Block 'merge 는 이슈 전용 worktree(workspace/wt/...) 안에서만 할 수 있습니다. 기본 클론은 patrol 전용입니다.'
    }
    $branch = if (Test-Path $target) { try { (& git -C $target rev-parse --abbrev-ref HEAD 2>$null) } catch { '' } } else { $plannedBranch[$target.TrimEnd('\')] }
    if ($branch -notmatch '^agent/') {
      Block "merge 는 agent/* 브랜치에서만 할 수 있습니다 (현재: $branch)."
    }
  }
}
exit 0