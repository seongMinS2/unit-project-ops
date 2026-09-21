# One-time setup: create the ops repo on Gitea, sync labels on unit-project,
# clone the agent workspace, and push this repo.
# Requires $env:GITEA_TOKEN (user environment variable).
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$cfg = Get-Content -Raw -Encoding UTF8 config/ops.json | ConvertFrom-Json
$gitea = '.claude/skills/gitea/scripts/gitea.ps1'
function G { powershell -NoProfile -ExecutionPolicy Bypass -File $gitea @args; if ($LASTEXITCODE) { throw "gitea.ps1 $args 실패" } }
function Git-Checked { git @args; if ($LASTEXITCODE) { throw "git $args 실패 (exit $LASTEXITCODE)" } }

# Use GITEA_TOKEN for git over HTTP instead of whatever Windows Credential Manager has cached
# (a cached account without write access caused 403 on push).
$helper = '!sh "' + ((Join-Path $root 'scripts/git-credential-gitea.sh') -replace '\\', '/') + '"'
function Set-TokenHelper([string]$repoDir) {
  git -C $repoDir config --local --replace-all credential.helper ''
  git -C $repoDir config --local --add credential.helper $helper
}
Set-TokenHelper $root

Write-Host '[1/5] Gitea 연결 확인'
G ping

Write-Host '[2/5] unit-project 라벨 동기화'
G labels-sync -Repo $cfg.targetRepo

Write-Host '[3/5] ops 저장소 확인/생성'
G repo-ensure -Repo $cfg.opsRepo -Description 'unit-project 관제 에이전트 조직 (리뷰·이슈·PR 자동화)'

Write-Host '[4/5] 에이전트 전용 작업 공간 클론'
if (-not (Test-Path $cfg.workspace)) {
  Git-Checked -c "credential.helper=" -c "credential.helper=$helper" clone --branch $cfg.baseBranch "$($cfg.giteaUrl)/$($cfg.owner)/$($cfg.targetRepo).git" $cfg.workspace
}
Set-TokenHelper $cfg.workspace
Git-Checked -C $cfg.workspace fetch origin --prune

Write-Host '[5/5] ops 저장소 push'
if (-not (git remote 2>$null | Select-String -Quiet '^origin$')) {
  git remote add origin "$($cfg.giteaUrl)/$($cfg.owner)/$($cfg.opsRepo).git"
}
Git-Checked push -u origin main
Write-Host '완료. 이제 이 폴더에서 Claude Code 를 열고 /patrol 을 실행해 보세요.'
