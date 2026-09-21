# 변경 파일 → 리뷰어 배정 규칙

patrol은 변경된 파일 경로를 보고 필요한 리뷰어만 호출합니다. 해당 파일이 하나도 없는 리뷰어는 이번 회차에서 생략합니다. 모든 리뷰어를 매번 돌리면 비용만 늘고 발견 품질은 오르지 않습니다.

| 경로 패턴 | 리뷰어 |
|---|---|
| `src/main/java/**/api/**`, `**/web/**`, `**/ws/**` | java-backend-reviewer, security-auditor |
| `src/main/java/**/core/**` | java-backend-reviewer, architecture-reviewer |
| `src/main/java/**/infra/**` | java-backend-reviewer, sql-reviewer, architecture-reviewer |
| `src/main/java/**/bootstrap/**` (config, aspect, SecurityConfig 등) | security-auditor, architecture-reviewer |
| `src/main/java/**/external/**` | java-backend-reviewer, security-auditor |
| `src/main/java/**/platform/**` | java-backend-reviewer, refactor-scout |
| `src/main/resources/templates*/**` (Thymeleaf) | frontend-reviewer |
| `src/main/resources/static*/**` (JS/CSS) | frontend-reviewer |
| `**/*.sql`, `src/main/resources/ddl/**` | sql-reviewer |
| `build.gradle`, `Jenkinsfile`, `*.bat`, `server.json` | security-auditor (의존성·비밀값·배포 스크립트) |
| `src/test/**` | 리뷰 생략. 단, ArchUnit baseline 파일이 **늘어났다면** architecture-reviewer에 알림 |
| `docs/**`, `*.md` | 리뷰 생략 |

변경 파일이 40개를 넘으면 refactor-scout도 함께 호출합니다. 큰 변경일수록 중복과 과설계가 끼어들 가능성이 높기 때문입니다.

## 주간 전체 감사

매주 월요일 첫 patrol(또는 `state/patrol.json`의 `lastDeepAudit`가 7일 이상 지난 경우)에는 변경분과 별도로 `config/ops.json`의 `deepAuditRotation`에서 다음 도메인 하나를 골라 전체 감사를 합니다. 투입 인원은 architecture-reviewer, security-auditor, refactor-scout입니다.
