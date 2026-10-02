## 관련 이슈
Refs #201

## 변경 내용
서식 불러오기 모달(`#loadTemplateModal`)에만 한정한 변경입니다. 공용 `.pager-row`와 `.btn-primary:disabled`는 건드리지 않았습니다.
- **5행 고정 높이:** 행 높이 변수 `--tpl-row-h: 3.125rem`를 머리글과 본문 행에 함께 씁니다. `.table-responsive`의 `min-height`는 행 높이의 6배(머리글 1 + 본문 5)입니다. 표 안 스크롤은 만들지 않았습니다.
- **페이지 크기 10 → 5** (`document-editor.js`): 5행을 넘으면 페이저로 넘깁니다.
- **빈 상태·로딩·오류:** colspan 한 줄 행을 5행 높이로 두고 가운데 정렬합니다. 탭을 바꾸거나 오류가 나도 높이가 출렁이지 않습니다.
- **빈 상태 링크:** "등록된 서식이 없습니다." 아래에 탭별로 "개인 서식함으로 가기"(`/document/document-form`) 또는 "공용 서식함으로 가기"(`/help/project-form`)를 둡니다.
- **여백:** 목록↔페이저 1.25rem, 모달 하단 위아래 1.25rem. 페이저의 `mt-2`(Tabler `!important`)는 마크업에서 뺐습니다. 그대로 두면 CSS 규칙을 이깁니다.
- **선택 행:** `--tblr-table-bg-state: var(--gfax-row-selected)`를 쓰고, 첫 칸에 `box-shadow: inset .1875rem 0 0 var(--tblr-primary), inset 0 0 0 9999px var(--tblr-table-bg-state)`를 줍니다. `border-left`는 쓰지 않으므로 행을 골라도 열 폭이 바뀌지 않습니다.
- **비활성 [불러오기]:** `#btnTplLoad:disabled`만 `opacity:1`, 배경 `--gfax-tint`, 글자 `--gfax-muted`로 바꿨습니다. 10개 테마로 계산한 대비는 약 3.9~7.7:1입니다.
- 머리글 가운데 정렬과 좌우 여백은 별도 이슈 범위라 바꾸지 않았습니다.

## 테스트
- 실행: `gradlew test` → **1991개 중 1990 통과, 실패 1, 스킵 10**
  - 실패한 `ScreenApiDocTest`(화면별 API 매핑 문서 vs 레지스트리)는 이 변경 이전의 dev에서도 실패하던 기존 실패입니다. 이 PR은 css/js/html만 바꿉니다.
- `ScreenRenderSmokeTest`: 326/326 통과 (`/document/document-editor` 포함)
- 추가한 테스트: 없음. CSS와 JS 문자열만 바꾼 변경이고, 이 환경에는 브라우저와 node가 없어 시각 회귀를 자동화할 수 없었습니다.

## 검증
fix-verifier: APPROVE (이번 실행 2회차). 1회차 반려 사유는 페이저 `mt-2 !important`가 간격 규칙을 이긴 것과 낡은 주석이었고, 둘 다 고쳤습니다.

## 리뷰어 확인 요청
**화면 확인을 하지 못했습니다.** 아래를 라이트·다크·모바일(fullscreen-sm)에서 봐 주세요.
1. 서식이 0건, 1건, 5건일 때와 로딩·오류 상태에서 목록 영역 높이가 같은지, 탭 전환 시 출렁이지 않는지
2. 선택 행의 주색 왼쪽 띠와 배경 틴트가 함께 보이는지, 행을 바꿔 골라도 열 폭이 그대로인지
3. 다크 테마에서 비활성 [불러오기] 글자가 읽히는지. 버튼이 주색을 흐린 모양에서 중립 회색 모양으로 바뀌었는데 이 의도가 괜찮은지, 푸터 배경과 비슷해 버튼 윤곽이 흐리지 않은지
4. 목록↔페이저 간격이 넉넉해 보이는지
5. 빈 상태 링크로 이동할 때 저장하지 않은 내용이 있으면 기존 이탈 경고가 뜨는지
6. `tr:has()` 선택자를 씁니다. 사내 지원 브라우저가 지원하는지(Chrome 105+, Firefox 121+, Safari 15.4+)

※ 커밋 제목 맨 앞에 BOM 문자가 섞여 들어갔습니다. force push가 금지라 고치지 못했습니다. squash merge 시 제목을 다시 써 주세요.

🤖 Generated with [Claude Code](https://claude.com/claude-code)