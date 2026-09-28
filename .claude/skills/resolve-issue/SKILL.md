---
name: resolve-issue
description: unit-project의 Gitea 이슈를 번호로 지정받아 처리한다. 이슈를 분석하고, 전용 작업 공간에 agent/issue-N 브랜치를 만들어 issue-fixer가 수정하고, build-runner가 테스트하고, fix-verifier가 검증을 통과시킨 뒤 dev 대상 PR을 만들고 이슈에 결과를 남긴다. "#12 처리해", "이슈 12번 고쳐", "resolve 12", "12, 15번 이슈 작업해줘"처럼 특정 이슈의 수정·구현을 요청할 때 반드시 사용한다. merge는 하지 않는다.
---

# Resolve Issue: 지정 이슈 처리

사람이 이슈 번호를 지정했을 때만 동작합니다. 결과물은 **사람이 리뷰하고 merge할 PR**입니다. 에이전트가 직접 merge하지 않는 이유는, 헥사고날 경계나 업무 규칙처럼 테스트로 다 잡히지 않는 판단은 사람이 마지막에 봐야 하기 때문입니다.

이슈마다 **전용 git worktree** `workspace/wt/issue-N`에서 작업합니다. 이 폴더를 이 문서에서 `$WT`라고 부릅니다. 이슈마다 폴더와 브랜치가 따로 있으므로, 서로 다른 세션이 다른 이슈를 동시에 처리해도 섞이지 않습니다. 기본 클론 `workspace/unit-project`는 patrol 전용이니 거기서는 브랜치를 바꾸거나 수정하지 마세요.

한 세션에서 여러 번호를 받으면 순서대로 하나씩 처리합니다. 병렬 처리는 `scripts/resolve-lanes.ps1`이 세션을 여러 개 띄워서 담당합니다.

## 1. 착수 전 확인

1. `gitea` 스킬로 `issue-get -Number N`을 실행합니다. **코멘트를 끝까지 읽으세요.** "PR #K 반려됨"이 있으면 이전 시도가 사람에게 거절된 이슈입니다. 그 반려 사유가 이번 작업의 가장 중요한 입력입니다. 같은 접근을 반복하지 말고, 사유가 무엇을 부정했는지(구현 방식인지, 요구사항 해석인지, 전제 자체인지) 먼저 정리한 뒤 다르게 접근하세요. 사유를 읽고도 같은 방식이 맞다고 판단되면, 구현하지 말고 그 근거를 적어 blocked로 돌리세요.
2. 아래 중 하나라도 해당하면 **착수하지 않고** 이유를 사용자에게 보고합니다.
   - 이슈가 닫혀 있음
   - 이미 `agent:in-progress` 또는 `agent:pr-open` 라벨이 붙어 있음 (중복 작업 방지)
   - 원격에 `agent/issue-N` 브랜치가 이미 있음
   - 요구사항이 모호해서 두 가지 이상으로 해석됨. 이 경우 해석 후보를 이슈 코멘트로 남기고 `agent:blocked` 라벨을 붙입니다.
3. `label-add agent:in-progress`를 실행하고 "에이전트가 작업을 시작했습니다." 코멘트를 남깁니다.

## 2. worktree 준비

```powershell
git -C workspace/unit-project fetch origin --prune
git -C workspace/unit-project worktree prune
git -C workspace/unit-project worktree add -B agent/issue-N C:/dev/unit-project-ops/workspace/wt/issue-N origin/dev
```
worktree 경로는 **반드시 위의 절대 경로**를 씁니다. 상대 경로를 쓰면 `-C` 폴더 기준으로 해석되어 기본 클론 안에 worktree가 생깁니다. `$WT` = `C:/dev/unit-project-ops/workspace/wt/issue-N`입니다.

`$WT` 폴더가 이미 있으면(이전 시도가 중단된 경우) 로컬 커밋이 없는지 확인한 뒤 `git -C workspace/unit-project worktree remove --force <$WT>`로 지우고 다시 만듭니다. fetch가 다른 세션과 겹쳐 lock 오류가 나면 몇 초 뒤 다시 시도하세요.

이후 모든 git 명령은 `git -C $WT ...`로, 모든 파일 경로는 `$WT` 기준으로 씁니다. 서브에이전트에게도 `$WT` 절대 경로를 작업 디렉터리로 넘깁니다.

## 3. 수정 (issue-fixer)

`issue-fixer` 에이전트를 호출합니다. 넘길 내용은 이슈 본문과 코멘트 전체, 작업 디렉터리(`$WT` 절대 경로), 브랜치 이름입니다.

다음 조건에서는 호출 시 `model: "opus"`로 올립니다. 이런 수정은 잘못되면 되돌리기 어렵거나 영향 범위가 넓기 때문입니다.
- `severity/critical` 또는 `type/security`
- `type/architecture`
- 수정이 3개 이상 도메인 패키지에 걸칠 것으로 보이는 경우

issue-fixer는 변경 요약, 수정 파일 목록, 추가한 테스트를 반환합니다. 커밋은 오케스트레이터가 합니다.

## 4. 테스트 (build-runner)

`build-runner`에게 `$WT`에서 테스트를 돌리게 합니다. 1차로 관련 테스트만, 2차로 전체 `test`를 실행합니다. 전체 테스트에는 ArchUnit 경계 테스트가 포함되어 있어 반드시 필요합니다. 실패하면 요약을 issue-fixer에게 돌려보내 다시 수정하게 합니다.

## 5. 검증 (fix-verifier)

`fix-verifier`에게 이슈 원문, `$WT` 경로, `git -C $WT diff origin/dev...HEAD`를 넘깁니다. 판정은 `APPROVE` 또는 `REJECT`(사유 목록 포함)로 받습니다.
- REJECT이면 사유를 issue-fixer에게 넘겨 다시 수정합니다. 4~5단계를 최대 `maxFixAttempts`(2)회 반복합니다.
- 그래도 통과하지 못하면 8단계(실패 처리)로 갑니다.

## 6. 커밋과 PR

1. 커밋 메시지는 저장소 관례대로 한국어 한 줄 요약을 쓰고, 본문에 `Refs #N`을 넣습니다. `Closes`는 쓰지 않습니다. 이슈는 사람이 merge 후 닫습니다.
   ```
   문서 다운로드 API 소유자 검증 추가

   Refs #N

   Co-Authored-By: Claude <noreply@anthropic.com>
   ```
2. `git -C $WT push -u origin agent/issue-N`로 push합니다. dev/main으로의 push는 hook이 차단합니다.
3. `pr-create`로 dev 대상 PR을 만듭니다. PR 본문은 다음과 같습니다.
   ```markdown
   ## 관련 이슈
   Refs #N
   ## 변경 내용
   (issue-fixer 요약)
   ## 테스트
   - 실행: `gradlew test` → 통과 (N개)
   - 추가한 테스트: ...
   ## 검증
   fix-verifier: APPROVE (시도 k회차)
   ## 리뷰어 확인 요청
   (verifier가 사람 확인이 필요하다고 표시한 지점)

   🤖 Generated with [Claude Code](https://claude.com/claude-code)
   ```

## 7. 마무리

`label-remove agent:in-progress`, `label-add agent:pr-open`을 실행하고, 이슈에 PR 링크 코멘트를 남긴 뒤 사용자에게 PR URL을 보고합니다.

push가 끝났으면 `git -C workspace/unit-project worktree remove <$WT>`로 worktree를 정리합니다. 브랜치는 원격에 남아 있으니 REJECT 피드백이 오면 다시 만들 수 있습니다.

## 8. 실패 처리

어느 단계에서든 진행할 수 없으면 다음을 수행합니다.
- 작업 브랜치는 로컬에만 두고 push하지 않습니다. `$WT`도 지우지 말고 남겨 둡니다. 사람이 살펴볼 수 있어야 합니다.
- `agent:in-progress` 라벨을 제거하고 `agent:blocked` 라벨을 붙입니다.
- 이슈 코멘트에 시도한 내용, 실패 지점, 마지막 테스트 또는 검증 결과 요약, 사람이 판단할 질문을 남깁니다.
- 사용자에게 같은 내용을 짧게 보고합니다.

실패를 성공처럼 보고하지 마세요. 테스트를 건너뛰었거나 일부만 통과했다면 PR 본문과 보고에 그대로 적습니다.
