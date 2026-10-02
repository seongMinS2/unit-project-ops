## 관련 이슈
Refs #206

## 변경 내용
공통 규칙은 `gfax-tabler.css` 한 곳에 모았습니다.
- **머리글 가운데**: `.table thead th { text-align:center }`를 전역으로 적용했습니다. 기존 `text-end`(Bootstrap `!important`) 머리글은 그대로 오른쪽 정렬입니다.
- **본문 열 정렬 유틸리티**: `.table td.cell-center`, `.table td.cell-text`를 추가했습니다. 본문 셀에만 걸리고 머리글은 항상 가운데입니다.
- **양끝 여백과 패딩**: 첫 열 왼쪽과 마지막 열 오른쪽에 `.875rem` 여백을 줬습니다. `table-sm` 셀 패딩은 `.375rem .625rem`입니다.
- **팝업 목록 배경 틴트 제거**: `.modal .gfax-inset`의 바탕을 `--tblr-bg-surface`로 바꾸고 얇은 테두리로만 구분했습니다. 모달 안에만 적용되므로 페이지 본문(팩스보내기 받는사람 표 등)은 그대로입니다.
- **팝업 행 강조**: 바탕이 같아져 행이 묻히지 않도록 `.modal .gfax-inset` 안에서 hover는 `--gfax-hover`, 담긴 행(`is-picked`)은 `--gfax-tint`를 씁니다. #201처럼 `--tblr-table-bg-state` 변수를 바꾸는 방식입니다.
- **참여자 선택 건수 문구**: "총 N건 · 프로젝트명"을 페이저 아래 한 줄로 내리고(`.pager-row-narrow`) 길면 말줄임표로 자릅니다.
- **관리 열**: 코드와 기준값 표 4곳(`#paneCodeGroup`, `#m-code-list`, `#paneBaseGroup`, `#m-base-value-list`)만 `.cell-tools`를 가운데로 모았습니다.

### 적용 대상 전수 목록
**열별 정렬 적용** (짧은 값은 가운데, 긴 글은 왼쪽)

| 대상 | 파일 |
|---|---|
| 코드 목록 모달 | `components/modals/code-set-list.html`, `system-code.js` |
| 코드그룹 목록(페이지 좌측 패널) | `app/system/system-code.html`, `system-code.js` |
| 기준값 목록 모달 | `components/modals/base-value-list.html`, `system-basic.js` |
| 기준값 그룹 목록(페이지 좌측 패널) | `app/system/system-basic.html`, `system-basic.js` |
| 참여자 선택(owner-picker) | `components/modals/owner-picker.html`, `owner-picker.js` |
| 받는사람 추가(주소록) | `sendFax.js`(abRow) |
| 서식 불러오기 `#loadTemplateModal` | `document-editor.js`(tplRowHtml). #201의 행 높이, 5행 고정, 선택 띠는 유지됩니다 |
| 포트 배정 모달 `port-info` | `admin-ports.js`(renderPortAssigns) |
| 우편번호 배정 모달 `postcode-info` | `admin-postcodes.js`(renderPostcodeAssigns) |

**해당 없음**: 표가 아닌 단일 레코드 폼이나 그리드입니다. code-group, base-group, excel-column, excel-screen, scheduler-cron, address-book-form, 엑셀 열 선택(`.excel-columns` 체크박스 그리드), 읽음 확인(`chat-read-status`, list-group)이 여기에 해당합니다.

**배경 틴트**: 참여자 선택과 받는사람 추가에만 실제 틴트가 있었고, 이번에 없앴습니다. 코드·기준값·서식 불러오기·엑셀·읽음 확인 목록은 원래 틴트가 없었습니다.

### 예외 (사유)
- **목록 화면 약 40곳**(팩스함, 송수신내역, 서식함, 휴지통, 이관, 스팸, 통계 등): 머리글 가운데와 양끝 여백은 전역 규칙으로 자동 적용됩니다. **본문 열별 정렬은 이번에 넣지 않았습니다.** 템플릿과 화면별 JS 40곳 가까이를 화면 확인 없이 고치기에는 위험이 커서 후속 이슈로 나누기를 권합니다. 그래서 이 화면들은 당분간 **머리글은 가운데, 본문 짧은 값은 왼쪽**인 중간 상태입니다.
- **`.cell-tools` 관리 열**: 전역으로 가운데로 바꾸면 기존 `text-end` 머리글과 어긋나 코드·기준값 4곳으로만 한정했습니다. 전체 통일은 디자인 결정이 필요합니다.
- **sendFax 본문 받는사람 표**: 페이지 본문이라 열별 클래스를 붙이지 않았습니다.

## 테스트
- 실행: `gradlew test` → 1991건 중 1980건 통과, 10건 스킵, **1건 실패(`ScreenApiDocTest`)**
  - 이 실패는 깨끗한 origin/dev worktree에서도 똑같이 납니다(화면별 API 매핑 문서와 레지스트리 불일치). 이번 변경은 Java를 건드리지 않아 무관합니다. 별도 처리가 필요합니다.
- 관련 테스트: `com.gmission.webfax.bootstrap.web.*`(화면 렌더 스모크), `architecture.Theme*`(테마 가드) 통과
- 추가한 테스트: 없음. CSS, 템플릿, JS 정렬 변경이라 자동 테스트로 확인할 수 없습니다.

## 검증
fix-verifier: APPROVE (2회차)
- 1회차 REJECT 사유는 두 가지였고 모두 반영했습니다. (1) th의 `cell-text`가 특이도에서 이겨 긴 글 머리글이 왼쪽으로 정렬되던 문제. (2) port-info와 postcode-info 모달이 누락된 문제.

## 리뷰어 확인 요청
- **스크린샷 없음**: 에이전트 환경에 브라우저가 없어 수정 전후 스크린샷을 찍지 못했습니다. 아래 화면을 직접 봐 주세요.
  1. 시스템 > 코드관리: 코드그룹 패널과 코드 목록 모달의 머리글 가운데 정렬, 양끝 여백, 관리 아이콘 가운데
  2. 시스템 > 기준값관리: 위와 같은 항목
  3. 문서작성 > 서식 불러오기: 서식명과 설명은 왼쪽, 형식과 수정일은 가운데. #201 결과물(5행 높이, 선택 띠, 비활성 버튼)이 그대로인지
  4. 참여자 선택: 트리, 사용자 표, 선택 목록이 모달 바탕과 같은 색인지. 건수 문구가 페이저 아래 한 줄로 나오는지
  5. 팩스보내기 > 받는사람 추가: 정렬과 배경
  6. 위 화면을 다크 테마와 모바일 폭에서도 확인
- **다크 테마 행 강조**: `--gfax-tint`는 graphite-steel, cobalt-midnight처럼 바탕과 색이 가까운 테마에서 담긴 행이 약하게 보일 수 있습니다. 요청자 코멘트의 "#201 왼쪽 띠 방식"과 달리 배경색만 바꿨으니, 이것으로 충분한지 판단해 주세요.
- 담긴 행에 마우스를 올리면 hover 색이 담긴 행 색을 덮습니다. 빈 상태 행("데이터가 없습니다")에도 hover 색이 칠해집니다.
- 참여자 선택의 긴 프로젝트명은 말줄임표로 잘립니다. 전체 이름이 보여야 하면 title 속성을 넣어야 합니다.
- 전역 머리글 가운데 정렬과 양끝 여백 때문에 페이지 목록 화면도 모양이 바뀝니다. 요청자 코멘트의 "페이지 본문 목록은 지금 모양 유지"는 배경에 대한 말로 해석했습니다. 정렬까지 유지해야 한다는 뜻이면 규칙을 `.modal`로 한정하겠습니다.
- `system-code.css`와 `system-basic.css`에 쓰이지 않는 `.th-c`, `.td-c`, `.th-r`, `.td-r` 훅이 남아 있어 이번 유틸리티와 겹칩니다. 정리는 범위 밖이라 손대지 않았습니다.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
