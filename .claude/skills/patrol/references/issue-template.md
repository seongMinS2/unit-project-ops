# 이슈 본문 템플릿

제목: `[{type}] {title}` (예: `[security] 문서 다운로드 API에 소유자 검증 누락`)

라벨: `agent:found`, `severity/{severity}`, `type/{type}`, `area/{area}`

```markdown
## 요약
{title}

## 위치
- 파일: `{file}` (L{line})
- 심볼: `{symbol}`
- 기준 커밋: `{sha 앞 8자리}`

## 근거
{evidence}

## 영향
{impact}

## 제안
{suggestion}

## 처리 방법
관제 세션에서 `/resolve-issue {번호}`를 실행하면 에이전트가 브랜치를 만들어 수정하고 PR을 올립니다.

---
발견: {reviewer 이름} · 신뢰도 {confidence} · patrol {YYYY-MM-DD}
<!-- fp:{rule}:{file}:{symbol} -->
```

## 재발견 코멘트 (이미 열린 이슈가 있을 때)

```markdown
patrol {YYYY-MM-DD}에서 다시 확인했습니다. 기준 커밋: `{sha}` (L{line})
```
같은 이슈에 재발견 코멘트는 **7일에 한 번까지만** 답니다. 매일 달면 알림 공해가 됩니다.

## 회귀 (같은 지문의 이슈가 닫혀 있을 때)

새 이슈를 만들고 본문 "요약" 아래에 `이전 이슈 #{번호}에서 수정된 문제가 다시 나타났습니다.`를 추가합니다.
