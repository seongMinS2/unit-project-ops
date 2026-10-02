## dev 반영 및 충돌 해결 (자동)
- 원인: #189(#179 대화방 안읽음 실시간 반영)가 먼저 merge되며 `src/test/resources/openapi/user.json` 충돌, dev 커밋 da16103(문서 업데이트)과 `docs/active-work.md` 충돌
- 해결:
  - `user.json`: dev 버전에 이 PR의 Menu 스키마 `topButtonFlag` 필드만 넣었습니다. `topButtonFlag`만 빼면 dev와 바이트 단위로 같습니다. #179의 chat 스키마는 그대로 남아 있습니다.
  - `docs/active-work.md`: 변경 이력에 dev가 추가한 두 행과 이 PR의 #188 행을 모두 시간순으로 남겼습니다.
  - (충돌 없이 합쳐졌지만 의미상 수정) `docs/document/process.md:68`: da16103은 맨 위 버튼 조건을 #183 규칙(ROOT 직속, `fax-send-to-root.sql`)으로 적었습니다. 이 PR은 그 스크립트를 삭제하므로 해당 줄을 #188 규칙(`top_button_flag=Y`, `alter-category-top-button-flag.sql` → `fax-send-restore-top-button.sql`)으로 고쳤습니다. 385행의 변경 이력(#183 당시 기록)은 과거 사실이라 그대로 두었습니다.
- dev가 이미 달성해 뺀 변경: 없음
- 전체 테스트: 1961개 중 1951개 통과, 10개 스킵, 실패 0. integrationTest(OpenApiSnapshot, CategoryPersistence) 7개 통과. fix-verifier: APPROVE

### 리뷰어 확인 요청 (추가)
- `process.md:68`은 팩스보내기 버튼 조건을 "팩스함 중메뉴이면서 플래그가 Y"로 적었습니다. 실제 코드는 위치와 상관없이 플래그가 Y이면 버튼으로 만듭니다. 이 표현을 그대로 둘지 봐 주세요.
- `process.md:385` 이력 행에 "#188로 대체" 같은 표시를 달지 정해 주세요.
