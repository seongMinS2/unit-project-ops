---
name: patrol
description: unit-project 정기 순찰. 마지막으로 리뷰한 커밋 이후 dev 변경분을 전문 리뷰어 서브에이전트(아키텍처, 보안, 백엔드, 프론트, SQL, 리팩토링)에게 나눠 맡기고, 결과의 중복을 걸러 Gitea 이슈로 등록한 뒤 순찰 리포트를 남긴다. "순찰", "patrol", "리뷰 돌려", "새 커밋 점검", "이슈 찾아서 등록", 예약 작업의 정기 실행, 모듈 전체 감사 요청에 사용한다. 이슈 하나를 고치라는 요청은 이 스킬이 아니라 resolve-issue를 쓴다.
---

# Patrol: 정기 순찰

목표는 **사람이 믿고 볼 수 있는 이슈만** 등록하는 것입니다. 이슈가 너무 많거나 오탐이 섞이면 사람들이 이슈 목록을 무시하게 되고, 그러면 관제 조직 전체가 쓸모없어집니다. 그래서 이 워크플로는 많이 찾는 것보다 **걸러내는 것**에 더 신경을 씁니다.

설정값은 `config/ops.json`, 상태는 `state/patrol.json`에 있습니다.

## 1. 사전 점검

1. `gitea` 스킬의 `ping`을 실행합니다. 실패하면 원인(토큰 누락, 서버 접속 불가)을 리포트에 적고 종료합니다.
2. 작업 공간을 최신 상태로 맞춥니다.
   ```powershell
   git -C workspace/unit-project fetch origin --prune
   git -C workspace/unit-project checkout --detach origin/dev
   ```
   작업 공간이 없으면 `scripts/bootstrap.ps1`을 먼저 실행하라고 안내하고 종료합니다.
   **사용자 작업 폴더 `C:\dev\unit-project`는 읽지도 수정하지도 않습니다.** 아직 push하지 않은 사용자의 작업이 있을 수 있습니다.

## 2. 리뷰 범위 결정

- `state/patrol.json`의 `lastReviewedSha`부터 `origin/dev`까지가 이번 범위입니다.
- 값이 없는 첫 실행이면 최근 `firstPatrolCommitDepth`(20)개 커밋을 범위로 잡습니다.
- 새 커밋이 없고 주간 감사 대상도 아니면 "변경 없음"으로 리포트를 남기고 종료합니다.
- `git diff --name-only <from>..origin/dev`로 변경 파일을 구한 뒤 `config/review-scope.md`의 배정표에 따라 리뷰어별 파일 목록을 만듭니다.
- 주간 전체 감사 조건(`review-scope.md` 하단)에 해당하면 rotation에서 다음 도메인을 골라 감사 작업을 추가합니다.

## 3. 리뷰어 병렬 호출

배정된 리뷰어를 **한 메시지에서 동시에** Agent 도구로 호출합니다. 각 리뷰어에게 다음을 넘깁니다.
- 작업 공간 경로(`workspace/unit-project`)와 리뷰할 파일 목록
- diff를 보는 명령: `git -C workspace/unit-project diff <from>..origin/dev -- <files>`
- `config/severity-rubric.md`와 `.claude/skills/patrol/references/finding-schema.md`를 읽고 그 형식으로만 답하라는 지시
- 변경분 리뷰라면 **변경된 줄과 그 영향 범위만** 보라는 지시. 이미 있던 코드의 문제까지 찾기 시작하면 매 회차 결과가 폭증합니다. 기존 코드 감사는 주간 전체 감사가 맡습니다.

리뷰어 역할은 `.claude/agents/`에 정의되어 있고, 모델도 각 파일에 지정되어 있습니다.

## 4. 선별 (오케스트레이터가 직접)

리뷰어 결과를 모은 뒤 등록 전에 걸러냅니다.
1. JSON 형식이 깨진 응답은 해당 리뷰어에게 한 번만 다시 요청합니다.
2. `confidence: medium`이면서 `severity: low`인 항목은 버립니다.
3. 같은 파일·심볼에 대한 다른 리뷰어의 중복 지적은 심각도가 높은 쪽으로 합칩니다.
4. critical/high 항목은 근거 코드를 직접 열어 한 번 더 확인합니다. 오탐으로 판단되면 버리고, 그 이유를 리포트의 "기각" 절에 남깁니다.
5. 심각도 순으로 정렬해 상위 `maxNewIssuesPerPatrol`(10)개만 등록 대상으로 삼습니다. 나머지는 리포트의 "보류" 절에 남겨 다음 회차에서 다시 검토합니다.

## 5. 이슈 등록

선별된 목록을 `issue-clerk` 에이전트에 넘깁니다. issue-clerk는 지문으로 중복을 확인하고 `references/issue-template.md` 형식으로 이슈를 등록하거나 코멘트를 답니다. 결과로 `{created:[...], commented:[...], skipped:[...]}`를 받습니다.

## 6. 기록

1. `reports/YYYY-MM-DD.md`에 리포트를 씁니다. 같은 날 두 번째 실행이면 `-2`를 붙입니다.
   ```markdown
   # Patrol YYYY-MM-DD
   - 범위: `abc1234..def5678` (커밋 N개, 파일 M개) / 주간 감사: {도메인 또는 없음}
   - 투입: architecture-reviewer, security-auditor, ...
   ## 신규 이슈
   | # | 심각도 | 제목 |
   ## 재확인(코멘트)
   ## 보류 (상한 초과)
   ## 기각 (오탐 판단과 이유)
   ```
2. `state/patrol.json`을 갱신합니다: `lastReviewedSha`, `lastRunAt`, 주간 감사를 했다면 `lastDeepAudit`와 `deepAuditIndex`.
3. ops 저장소에 커밋하고 push합니다. ops 저장소 `main`으로의 push는 허용됩니다. 금지 대상은 unit-project의 dev/main입니다.
   ```powershell
   git add reports state
   git commit -m "patrol YYYY-MM-DD: 신규 N건, 재확인 M건"
   git push origin main
   ```

## 7. 사용자 보고

마지막 응답에는 신규 이슈 번호와 제목(심각도순), 재확인 건수, 리포트 파일 경로만 짧게 적습니다. 예약 작업으로 실행된 경우에도 같은 형식을 씁니다.
