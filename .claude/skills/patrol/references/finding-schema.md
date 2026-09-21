# 리뷰어 발견 사항 형식 (공통 계약)

모든 리뷰어 에이전트는 최종 응답을 아래 JSON 배열 **하나로만** 반환합니다. 발견이 없으면 `[]`을 반환합니다. patrol 오케스트레이터와 issue-clerk가 이 형식을 기계적으로 처리하므로 필드 이름을 바꾸거나 설명을 덧붙이면 안 됩니다.

```json
[
  {
    "rule": "authz-missing",
    "type": "security",
    "severity": "critical",
    "area": "backend",
    "file": "src/main/java/com/gmission/webfax/document/api/DocumentController.java",
    "line": 88,
    "symbol": "DocumentController#download",
    "title": "문서 다운로드 API에 소유자 검증 누락",
    "evidence": "문제 코드를 3~10줄 인용하고, 왜 문제인지 한두 문장으로 설명",
    "impact": "다른 사용자의 문서 ID를 넣으면 파일을 받을 수 있음",
    "suggestion": "DocumentQuery에 memberId 조건을 추가하거나 @PreAuthorize로 소유자 확인",
    "confidence": "high"
  }
]
```

| 필드 | 값 |
|---|---|
| `rule` | kebab-case 규칙 ID. 같은 종류의 문제는 항상 같은 ID를 쓸 것 (예: `authz-missing`, `tx-missing`, `domain-boundary`, `xss-unescaped`, `sort-injection`, `exception-swallowed`, `n-plus-one`, `duplicate-logic`, `dead-code`) |
| `type` | `bug` \| `security` \| `architecture` \| `refactor` \| `performance` |
| `severity` | `critical` \| `high` \| `medium` \| `low` (`config/severity-rubric.md` 기준) |
| `area` | `backend` \| `frontend` \| `db` \| `infra` |
| `file` | 저장소 루트 기준 상대 경로, `/` 구분자 |
| `symbol` | `클래스#메서드`, JS는 `파일명#함수명`, SQL은 `파일명#쿼리ID`. 줄 번호가 바뀌어도 지문이 유지되도록 하는 핵심 필드 |
| `confidence` | `high` \| `medium`. 확신이 `low`인 추측은 보고하지 말 것 |

**지문(fingerprint)** 은 `{rule}:{file}:{symbol}`입니다. issue-clerk가 이 값으로 중복을 판단합니다.
