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
# Which repo does the git command act on? `git -C <dir>` wins, then the last `cd <dir>` in the
# command, then the session cwd. (Checking cwd alone blocked a legit `cd ops && git push origin main`.)
function Resolve-Dir([string]$base, [string]$p) {
  $p = $p -replace '^(?i)/(mnt/)?([a-z])/', '$2:/'          # /c/dev -> c:/dev
  try {
    if (-not [IO.Path]::IsPathRooted($p) -or $p -match '^[\\/]') { $p = Join-Path $base $p }
    return [IO.Path]::GetFullPath($p)
  } catch { return $p }
}
$target = $cwd
foreach ($m in [regex]::Matches($cmd, '(?i)(?:^|[;&|]\s*|\s)(?:cd|Set-Location)\s+("?)([^";&|\s]+)\1')) {
  $target = Resolve-Dir $target $m.Groups[2].Value
}
if ($cmd -match '(?i)\bgit\s+-C\s+("?)([^";&|\s]+)\1') { $target = Resolve-Dir $target $Matches[2] }
$inWorkspace = $target -match '(?i)workspace[\\/]+unit-project'
if ($target -match '(?i)^c:[\\/]+dev[\\/]+unit-project([\\/]|$)') {
  Block '사용자 작업 폴더 C:\dev\unit-project 로 이동하거나 그 안에서 명령을 실행할 수 없습니다.'
}

if ($cmd -match $userCheckout) {
  Block '사용자 작업 폴더 C:\dev\unit-project 를 대상으로 하는 명령은 허용되지 않습니다.'
}
if ($cmd -match '(?i)/pulls/\d+/merge') {
  Block 'PR merge 는 사람만 수행합니다.'
}
if ($cmd -match '(?i)\bgit\b[^;|&\n]*\bpush\b[^;|&\n]*') {
  $push = $Matches[0]
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
if ($inWorkspace -and $cmd -match '(?i)\bgit\b[^;|&\n]*\bmerge\b' -and $cmd -notmatch '(?i)merge-base') {
  Block '작업 공간에서 git merge 는 허용되지 않습니다. 브랜치는 origin/dev 에서 새로 만드세요.'
}
exit 0
