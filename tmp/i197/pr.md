## 관련 이슈
Refs #197

## 변경 내용
노출여부(`navi_use_flag`)와 상단 버튼(`top_button_flag`)을 서로 독립된 설정으로 분리했습니다.

| 표시 | 조건 |
|---|---|
| 좌측 맨 위 버튼 (`primaries()`) | 상단 버튼 Y + 사용여부 + 권한. **노출여부와 무관** |
| 사이드바 그룹 목록 (`groups()`) | 노출여부가 N이 아니고 상단 버튼이 N인 중메뉴 |
| 상단 캡슐 탭 (`siblings()`) | 사이드바 그룹 목록과 같은 항목. 현재 화면이 목록에 없으면 빈 목록이라 탭 줄이 없음 |

- `MenuProvider`
  - `visibleMenus()`에서 노출여부 필터를 빼고, 사이드바·탭이 같이 쓰는 `buildGroups()`로 옮겼습니다. 요청당 1회 조회 캐시는 유지합니다.
  - #188에서 넣은 "상단 버튼 중메뉴도 탭에 포함" 분기(`includeTopButtons`)를 제거했습니다.
  - 노출여부가 NULL이면 예전처럼 노출로 봅니다(`isNaviVisible`: `Flag.N != naviUseFlag`).
- DDL
  - 신규 `ddl/menu/fax-send-hide-from-navi.sql`: 경로 기준이고 멱등입니다. 팩스보내기를 노출여부 N, 상단 버튼 Y로 맞춥니다. 문서작성은 건드리지 않습니다.
  - seed `category.sql`: MN10(팩스보내기)의 노출여부를 N으로 바꿨습니다.
- 카테고리관리 모달(`category.html`): 노출여부 ⓘ를 새로 넣고("사이드바와 상단 탭 표시 전용"), 상단 버튼 ⓘ에 "노출여부와 무관"을 적었습니다.
- 템플릿 주석(`layout/fragments.html`, `layout/base.html`)과 문서(`docs/thymeleaf/README.md`, `category-menu.md`, `tabler-migration.md`, `active-work.md`)를 새 규칙에 맞췄습니다.
- 변경 없이 확인만 한 것
  - 접힌 레일 그룹 아이콘 클릭(#154)은 `groups()`의 첫 항목으로 가므로 팩스보내기로 가지 않습니다.
  - 권한 판정(`role_category_action`, URL 접근)은 `navi_use_flag`를 보지 않습니다.

## 테스트
- 실행: `gradlew test` → 2000개 중 1989 통과, 10 스킵, **1 실패**
  - 실패한 `ScreenApiDocTest`는 **이 PR과 무관한 dev의 기존 실패**입니다. #184 머지(a437c72)가 `ScreenApiRegistry`에 `/chat-rooms/{chatRoomId}/members/me/pin`을 넣고 `screen-api-mapping.md`를 다시 만들지 않아 생겼습니다. 이 PR은 두 파일을 건드리지 않습니다. dev에서 `./gradlew test -Dscreen.doc.update=true`로 따로 처리해야 합니다.
- 추가하거나 바꾼 테스트
  - `MenuProviderTest`
    - 네 조합(노출여부 Y/N × 상단 버튼 Y/N)마다 버튼·사이드바·탭 세 곳을 모두 검사합니다: `naviY_topN_…`, `naviY_topY_…`, `naviN_topN_…`, `naviN_topY_onlyPrimaryButton`
    - `siblings_topButtonItemExcludedFromTabs`, `primaries_naviHidden…`, `naviUseFlagNull_treatedAsVisible`
  - `FaxSendHideFromNaviSqlTest`(신규): H2 MySQL 모드에서 DDL 멱등성을 검사합니다.

## 검증
fix-verifier: APPROVE (시도 2회차). 1회차 반려 사유는 옛 규칙이 남은 템플릿 주석 3곳과 노출여부 NULL 의미 변경이었고, 둘 다 반영했습니다.

## 리뷰어 확인 요청
- **DDL 미적용**: 아직 어떤 DB에도 적용하지 않았습니다. 순서는 `alter-category-top-button-flag.sql` → `fax-send-restore-top-button.sql` → `fax-send-hide-from-navi.sql`이고, 재기동은 필요 없습니다.
- `fax-send-hide-from-navi.sql`은 `navi_use_flag <> 'N'` 조건이라 팩스보내기 행이 **NULL이면 바꾸지 않습니다**. 코드는 NULL을 노출로 보므로 그 DB에서는 팩스보내기가 사이드바에 남습니다. 적용 뒤 사후 확인 쿼리로 `'N'`인지 확인해 주세요.
- 노출여부가 N인 그룹 아래에 상단 버튼 Y 중메뉴가 있으면 이제 맨 위 버튼으로 나옵니다. 이슈 규칙대로입니다. seed의 뷰어 MN99 하위는 모두 N이라 영향이 없습니다. 실제 DB에 그런 행이 있는지 확인해 주세요.
  `SELECT c.category_id, c.parent_category_id FROM category c JOIN category p ON p.category_id = c.parent_category_id WHERE c.top_button_flag = 'Y' AND p.navi_use_flag = 'N';`
- 팩스보내기에 일반 사용자 권한(`role_category_action`)이 있는지 권한관리에서 확인해 주세요. 권한이 없으면 버튼과 화면 모두 보이지 않습니다.
- 실행 화면은 확인하지 못했습니다(브라우저 없음). 다음을 봐 주세요.
  - 맨 위 [팩스보내기] 버튼만 보이는지
  - 사이드바·탭에 팩스보내기가 없는지
  - 팩스보내기 화면에 탭 줄이 없는지
  - 팩스함 탭이 사이드바 목록과 같은지
- 카테고리관리 ⓘ 문구가 화면 톤에 맞는지 봐 주세요.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
