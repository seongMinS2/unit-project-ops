---
name: sync-prs
description: 에이전트가 만든 unit-project PR(agent/* 브랜치) 중 dev와 충돌이 난 PR을 찾아, 이슈별 worktree에서 origin/dev를 merge하고 conflict-resolver가 양쪽 의도를 보존해 충돌을 해결한 뒤, 전체 테스트와 fix-verifier 검증을 거쳐 같은 브랜치에 push하고 PR에 해결 내역을 남긴다. "PR 충돌 해결해줘", "#28 충돌 고쳐", "sync-prs", "열린 PR dev에 맞춰줘", 다른 PR을 merge한 뒤 나머지 PR 정리를 요청할 때, 그리고 예약 순찰 직후에 사용한다. PR을 merge하지는 않는다.
---

# Sync PRs: 에이전트 PR 충돌 해결

사람이 PR 하나를 merge하면, 같은 파일을 건드린 다른 에이전트 PR이 충돌 상태가 됩니다. 이 스킬은 그런 PR을 **dev에 맞춰 다시 merge 가능한 상태로** 만듭니다. merge 자체는 여전히 사람이 합니다.

인자로 PR 번호를 받으면 그 PR만, 없으면 열린 모든 에이전트 PR을 대상으로 합니다.

## 1. 대상 찾기

`gitea` 스킬로 `pr-list -State open`을 실행하고, `head`가 `agent/`로 시작하고 `mergeable`이 false인 PR만 고릅니다. 없으면 "충돌 PR 없음"을 보고하고 끝냅니다.

Gitea의 `mergeable`은 dev가 바뀐 직후 잠시 갱신되지 않을 수 있습니다. 애매하면 `pr-get`으로 한 번 더 확인하세요.

## 2. PR마다 처리 (한 번에 하나씩)

PR 번호를 N, head 브랜치를 B라고 합니다. worktree 경로는 **반드시 절대 경로**를 씁니다: `$WT = C:/dev/unit-project-ops/workspace/wt/pr-N`

1. **준비**
   ```powershell
   git -C workspace/unit-project fetch origin --prune
   git -C workspace/unit-project worktree add -B B C:/dev/unit-project-ops/workspace/wt/pr-N origin/B
   git -C $WT merge --no-edit origin/dev
   ```
   merge가 충돌 없이 끝났다면 Gitea 표시가 늦었던 것입니다. 이 경우 3번의 검증만 거쳐 push합니다.

2. **충돌 해결 (conflict-resolver)**: 다음 정보를 모아 `conflict-resolver`에게 넘깁니다.
   - `$WT`, B, PR 본문(`pr-get`), 원래 이슈 본문(브랜치 이름의 issue 번호로 `issue-get`)
   - dev 쪽 변경: `git -C $WT log --oneline <merge-base>..origin/dev -- <충돌 파일들>`과 그 커밋들이 속한 PR 번호(커밋 메시지의 "Merge pull request ... (#K)")

   결과에 `needsHuman`이 있으면 `git -C $WT merge --abort`로 되돌리고 5번(사람 판단 요청)으로 갑니다.

3. **검증**
   - `build-runner`에게 `$WT`에서 전체 `test`를 돌리게 합니다(ArchUnit 포함).
   - `fix-verifier`에게 **원래 이슈와 해결 결과**를 함께 넘깁니다. 확인할 것은 두 가지입니다. merge 결과(`git -C $WT diff origin/dev...HEAD`)가 여전히 이슈를 해결하는지, 그리고 dev 쪽 변경을 되돌리거나 약화하지 않았는지입니다. 후자는 `git -C $WT diff origin/dev HEAD`로 dev 대비 차이가 이 PR의 의도로만 설명되는지 보면 됩니다.
   - 테스트 실패나 REJECT가 나오면 사유를 conflict-resolver에게 돌려 다시 해결합니다. 최대 2회까지 반복하고, 그래도 안 되면 5번으로 갑니다.

4. **반영**
   ```powershell
   git -C $WT commit --no-edit        # merge 커밋 완료 (resolver 는 add 까지만 함)
   git -C $WT push origin B           # 일반 push. force push 는 쓰지 않는다
   ```
   PR에 코멘트를 남깁니다(`issue-comment -Number N`).
   ```markdown
   dev 반영 및 충돌 해결 (자동)
   - 원인: #K 가 먼저 merge 되며 `파일` 충돌
   - 해결: (resolver 의 파일별 resolution 요약)
   - dev 가 이미 달성해 뺀 변경: ...
   - 전체 테스트: N개 통과 · fix-verifier: APPROVE
   ```
   `git -C workspace/unit-project worktree remove $WT`로 정리합니다.

5. **사람 판단 요청** (해결하지 못한 경우): PR에 충돌 파일, 양쪽 의도, 판단이 필요한 질문을 코멘트로 남기고, 원래 이슈에 `agent:blocked` 라벨을 붙입니다. 브랜치는 건드리지 않은 상태 그대로 둡니다.

## 3. 보고

처리한 PR마다 "해결·push됨 / 사람 판단 필요 / 충돌 없었음" 중 하나와 한 줄 요약을 보고합니다.

## 하지 않는 것
- PR merge, force push, rebase 후 push (hook이 차단합니다)
- 사람이 만든 PR(`agent/`가 아닌 브랜치) 수정
- 충돌 해결을 핑계로 한 추가 개선
