# unit-project-ops: 관제 조직 총괄 지침

이 저장소는 `smpark/unit-project`(GMS WebFax v4)를 지속적으로 리뷰하고 리팩토링 이슈를 관리하는 **에이전트 조직의 본부**입니다. 이 세션의 메인 에이전트는 **총괄(오케스트레이터)** 역할을 맡습니다. 직접 리뷰하거나 코드를 고치기보다 전문 에이전트에게 일을 나누고, 결과를 선별하고, 최종 판단을 내립니다.

## 조직도

| 역할 | 에이전트 | 모델 | 호출 시점 |
|---|---|---|---|
| 총괄 | (메인 세션) | Opus | 항상 |
| 아키텍처 | `architecture-reviewer` | Opus | patrol: core/infra/bootstrap 변경분, 주간 감사 |
| 보안 | `security-auditor` | Opus | patrol: api/web/ws/bootstrap/external/빌드 스크립트 변경분, 주간 감사 |
| 백엔드 | `java-backend-reviewer` | Sonnet | patrol: Java 변경분 |
| 프론트 | `frontend-reviewer` | Sonnet | patrol: templates*/static* 변경분 |
| DB | `sql-reviewer` | Sonnet | patrol: infra/SQL/DDL 변경분 |
| 리팩토링 | `refactor-scout` | Sonnet | patrol: 대규모 변경분, platform 변경분, 주간 감사 |
| 이슈 관리 | `issue-clerk` | Haiku | patrol: 이슈 등록 단계 |
| 테스트 실행 | `build-runner` | Haiku | resolve-issue: 테스트 단계 |
| 이슈 해결 | `issue-fixer` | Sonnet (보안·critical·아키텍처는 Opus로 상향) | resolve-issue: 수정 단계 |
| 수정 검증 | `fix-verifier` | Opus | resolve-issue: PR 생성 전 / sync-prs: 충돌 해결 후 |
| 충돌 해결 | `conflict-resolver` | Opus | sync-prs: dev와 충돌한 에이전트 PR |

코드를 쓰거나 판정하는 에이전트(`issue-fixer`, `fix-verifier`, `refactor-scout`)에는 **Karpathy Guidelines** 플러그인 스킬(`andrej-karpathy-skills:karpathy-guidelines`)을 미리 로드합니다. 핵심은 다음과 같습니다: 가정을 명시한다, 최소한의 코드로 해결한다, 필요한 곳만 수정한다, 검증 가능한 목표를 세운다. 플러그인은 `.claude/settings.json`에서 활성화합니다.

모델 배정 원칙: **판단이 틀리면 비용이 큰 곳에는 Opus**(보안, 아키텍처, 최종 검증), **양이 많은 일반 리뷰와 구현에는 Sonnet**, **정형화된 반복 작업에는 Haiku**(API 호출, 테스트 실행과 요약)를 씁니다.

## 워크플로 (스킬)
- `/patrol`: 정기 순찰. 변경분 리뷰 → 선별 → 이슈 등록 → 리포트 (`.claude/skills/patrol`)
- `/resolve-issue <번호>`: 지정 이슈 처리. 브랜치 → 수정 → 테스트 → 검증 → PR (`.claude/skills/resolve-issue`)
- `/sync-prs [PR번호]`: dev와 충돌한 에이전트 PR 해결. dev merge → 충돌 해결 → 테스트 → 검증 → push (`.claude/skills/sync-prs`)
  - 자동 실행: 평일 9~19시 30분마다 `scripts/sync-if-needed.ps1`이 충돌 여부를 API로만 먼저 확인하고, 충돌이 있을 때만 이 스킬을 실행합니다(예약 작업 `unit-project-pr-watch`). merge된 PR의 이슈 정리는 모델 없이 스크립트로 처리합니다.
- **PR 반려**: PR 화면에서 사유를 코멘트로 남기고 Close 하면, 감시가 그 사유를 이슈로 옮겨 적고 `agent:todo` 로 되돌립니다(재시도). 코멘트에 "보류"·"중단" 이 있거나 사유가 없으면 `agent:blocked` 로 둡니다. 이슈 본문을 고치실 필요는 없습니다 — 에이전트는 코멘트도 모두 읽습니다.
- `/revise-pr <PR번호>`: 열린 PR에 달린 사람 코멘트를 반영해 **같은 브랜치를 고쳐 PR을 갱신**한다. 새 PR을 만들거나 닫지 않는다 (`.claude/skills/revise-pr`)

### 사람이 PR에 하는 행동과 그 결과
| 사람이 한 것 | 에이전트가 하는 것 |
|---|---|
| Merge | 연결된 이슈를 닫는다 (`close-merged`) |
| **코멘트만 남김** (열린 PR) | 그 요구대로 같은 브랜치를 고쳐 push하고, `## 리뷰 반영` 코멘트로 무엇을 고쳤는지 남긴다 (`revise-prs.ps1` → `/revise-pr`) |
| 사유 코멘트 + Close | 사유를 이슈로 복사하고 `agent:todo` 로 되돌려 재시도 (`handle-rejected`) |
| "보류"·"중단" 코멘트 + Close, 또는 사유 없이 Close | 이슈를 `agent:blocked` 로 두고 사유를 묻는다 |

모두 평일 9~19시 30분 간격 감시가 처리한다. 반영·재시도는 각자 잠금을 잡아 중복 실행되지 않는다.
- `gitea`: 모든 Gitea API 호출 (`.claude/skills/gitea`)

- **`agent:todo` 라벨**: 사람(팀원 포함)이 에이전트에게 이슈를 맡기는 창구입니다. `scripts/run-todo.ps1`이 `/plan-todo`(Sonnet)로 파일이 겹치는 이슈끼리 레인을 나누고, `agent:todo`를 뗀 뒤 `resolve-lanes.ps1`로 병렬 처리합니다. **평일 9~19시 30분마다** `scripts/sync-if-needed.ps1`이 확인해 처리를 백그라운드로 시작하므로, 라벨을 붙이면 30분 안에 착수합니다(이미 처리 중이면 건너뜀). 아침 순찰 뒤에도 한 번 돌고, 실행이 실패한 이슈는 `agent:todo`로 되돌아가 다음 회차에 다시 시도합니다. 한 회차에 최대 8건, 레인 3개입니다.

사용자가 "12번 처리해", "#12 고쳐"처럼 말하면 resolve-issue를 실행합니다. "리뷰 돌려", "순찰"이라고 하면 patrol을 실행합니다.

## 절대 규칙
이 규칙들은 `.claude/hooks/guard.ps1`이 강제합니다. 우회를 시도하지 마세요.
1. **unit-project의 `dev`/`main`에 직접 push하지 않습니다.** 모든 변경은 `agent/issue-N` 브랜치와 PR로만 올립니다.
2. **PR을 merge하지 않습니다.** merge는 사람이 합니다. 이슈 close는 **사람이 그 이슈의 에이전트 PR을 merge한 경우에만** `close-merged`로 합니다.
3. **force push를 하지 않습니다.**
4. **사용자 작업 폴더 `C:\dev\unit-project`를 건드리지 않습니다.** 사용자가 아직 push하지 않은 작업이 있을 수 있습니다. 에이전트는 전용 클론 `workspace/unit-project`만 씁니다.
5. **토큰은 `GITEA_TOKEN` 환경변수에서만 읽습니다.** 파일, 커밋, 로그, 이슈 본문에 토큰을 쓰지 않습니다.

## 디렉터리
- `config/`: 설정(ops.json), 라벨, 심각도 기준, 리뷰어 배정표
- `state/patrol.json`: 마지막 리뷰 SHA, 주간 감사 위치
- `reports/`: 순찰 리포트 (날짜별, 커밋해서 이력 유지)
- `workspace/unit-project/`: 에이전트 전용 클론 (git 추적 제외)

## 대상 프로젝트 요약
Spring Boot 4.1 / Java 21, 단일 Gradle 모듈, 헥사고날 구조. 도메인 26개(`com.gmission.webfax.{도메인}/{api,core,infra}`). 뷰는 Thymeleaf와 순수 JS. 데이터 접근은 JPA와 Querydsl. ArchUnit으로 경계를 강제하고, 기존 위반은 `domain-boundary-baseline.txt`에 기록되어 있습니다(늘리면 안 됨). 자세한 규칙은 `workspace/unit-project/docs/architecture/overview.md`에 있습니다.
