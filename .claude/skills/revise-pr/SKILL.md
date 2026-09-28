---
name: revise-pr
description: 열린 에이전트 PR에 사람이 남긴 수정 요청 코멘트를 반영해 같은 브랜치를 고치고 push해서 PR을 갱신한다. 새 PR을 만들지 않고 PR을 닫지도 않는다. "PR #75 코멘트 반영해줘", "리뷰 반영", "revise-pr", 감시가 열린 PR의 새 사람 코멘트를 발견했을 때 사용한다. 접근 자체가 틀려서 처음부터 다시 해야 하는 경우는 이 스킬이 아니라, 사람이 PR을 닫으면 resolve-issue 가 재시도한다.
---

# Revise PR: 리뷰 코멘트 반영

사람이 PR을 닫지 않고 코멘트만 남겼다면 "방향은 맞으니 이 부분만 고쳐라"라는 뜻입니다. 그래서 **같은 브랜치를 고쳐 PR을 갱신**합니다. 새 PR을 만들면 리뷰 맥락이 끊기고, 닫고 다시 만들면 이미 검토된 부분까지 다시 봐야 합니다.

인자로 PR 번호를 받습니다. 여러 개면 하나씩 순서대로 처리합니다.

## 1. 확인

1. `gitea` 스킬의 `pr-get -Number N`으로 상태를 봅니다. 닫혔거나 merge되었으면 아무것도 하지 않고 그 사실만 보고합니다.
2. `issue-comment` 대상과 같은 번호로 `issue-get -Number N`을 실행하면 **PR의 코멘트 전체**를 받습니다(Gitea에서 PR은 이슈 번호를 공유합니다).
3. **반영할 코멘트를 고릅니다.** 에이전트가 남긴 코멘트(`## PR #`, `## dev 반영 및 충돌 해결`, `## 리뷰 반영`, `에이전트 처리`로 시작)는 제외하고, **마지막 `## 리뷰 반영` 코멘트 이후에 사람이 단 코멘트**만 대상입니다. 그 이전 것은 이미 반영했습니다.
4. 대상이 없으면 "반영할 새 코멘트 없음"으로 끝냅니다.
5. `$WT = C:/dev/unit-project-ops/workspace/wt/pr-N` 폴더가 이미 있으면 다른 세션이 처리 중이므로 건너뜁니다.

## 2. 준비

```powershell
git -C workspace/unit-project fetch origin --prune
git -C workspace/unit-project worktree add -B <PR의 head 브랜치> C:/dev/unit-project-ops/workspace/wt/pr-N origin/<head 브랜치>
```
`origin/dev`가 앞서 있으면 `git -C $WT merge --no-edit origin/dev`로 먼저 맞춥니다. 충돌이 나면 이 스킬을 멈추고 `/sync-prs`가 처리하도록 보고합니다.

## 3. 수정 (issue-fixer)

`issue-fixer`에게 다음을 넘깁니다: `$WT`, 브랜치, 원래 이슈 본문, PR 본문, **반영할 코멘트 원문**.

지시할 것:
- 코멘트가 요구한 것만 고칩니다. 지나가다 보이는 다른 개선은 하지 않습니다.
- 코멘트가 모호하면 추측하지 말고 그대로 보고합니다. 오케스트레이터가 PR에 되묻습니다.
- 코멘트가 **사실관계를 정정**한 것이면(예: "이 API는 세션 사용자가 없다") 그 전제 위에서 다시 판단합니다. 기존 구현을 억지로 유지하지 마세요.

`severity/critical`, `type/security`, `type/architecture` 이슈의 PR이면 `model: "opus"`로 올립니다.

## 4. 테스트와 검증

- `build-runner`로 관련 테스트와 전체 `test`를 돌립니다.
- `fix-verifier`에게 **코멘트 요구사항**과 `git -C $WT diff origin/dev...HEAD`를 넘겨, 요구가 반영되었는지와 원래 이슈 해결이 깨지지 않았는지 확인시킵니다.
- REJECT면 사유를 issue-fixer에 돌려 최대 2회 반복합니다.

## 5. 반영

1. 커밋: 한국어 한 줄 요약 + 본문에 `Refs #<이슈번호>`와 `리뷰 반영: PR #N`.
2. `git -C $WT push origin <head 브랜치>` — **일반 push만** 합니다. force push와 브랜치 변경은 금지입니다.
3. PR에 코멘트를 남깁니다. 이 코멘트가 "여기까지 반영했다"는 표시가 되므로 **형식을 지켜야 합니다.**
   ```markdown
   ## 리뷰 반영 (자동)
   반영한 코멘트: <작성자> (<시각>)
   - <요구> → <어떻게 고쳤는지>
   - 테스트: 전체 N개 통과 · fix-verifier: APPROVE
   - 커밋: <sha>
   (되묻는 것이 있으면) 확인 필요: <질문>
   ```
4. `git -C workspace/unit-project worktree remove <$WT>`로 정리합니다.

## 6. 반영할 수 없을 때

코멘트가 모호하거나, 요구가 서로 모순되거나, 업무 판단이 필요하면 **고치지 말고** PR에 `## 리뷰 반영 (자동)` 형식으로 질문만 남깁니다(무엇을 못 했는지, 무엇을 알려주면 되는지). 추측해서 고치면 리뷰어가 검증할 수 없는 변경이 쌓입니다.

## 하지 않는 것
- PR merge, PR 닫기, force push, 새 PR 생성
- 사람이 만든 PR(`agent/`가 아닌 브랜치) 수정
