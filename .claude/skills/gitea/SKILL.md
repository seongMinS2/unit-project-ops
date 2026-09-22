---
name: gitea
description: 사내 Gitea(172.23.239.8:9000)의 smpark/unit-project 저장소에서 이슈 조회·등록·코멘트·라벨 변경, PR 생성, 라벨 동기화를 수행하는 API 래퍼. unit-project 이슈나 PR을 읽거나 쓰는 모든 작업(patrol, resolve-issue 포함)에서 curl이나 Invoke-RestMethod를 직접 호출하지 말고 반드시 이 스킬의 스크립트를 사용할 것. "이슈 목록 보여줘", "#12 이슈 내용", "라벨 붙여", "PR 만들어" 같은 요청에도 사용한다.
---

# Gitea API 래퍼

모든 Gitea 호출은 `scripts/gitea.ps1` 하나로 처리합니다. 스크립트를 쓰는 이유는 세 가지입니다.
- 토큰을 `$env:GITEA_TOKEN`에서만 읽으므로 명령줄이나 로그에 노출되지 않습니다.
- Windows PowerShell 5.1에서 한글 본문이 깨지지 않도록 UTF-8 인코딩을 처리합니다.
- 라벨 이름을 ID로 바꾸고 페이지를 넘기는 처리를 대신합니다.

## 호출 방법

저장소 루트에서 실행합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .claude/skills/gitea/scripts/gitea.ps1 <command> [options]
```

| 명령 | 용도 |
|---|---|
| `ping` | 토큰과 연결 확인. 모든 워크플로의 첫 단계 |
| `labels-sync [-Repo X]` | `config/labels.json` 라벨을 저장소에 생성 (이미 있으면 건너뜀) |
| `issue-list [-State open\|closed\|all] [-Labels a,b]` | 이슈 목록 (본문 제외) |
| `issue-get -Number N` | 이슈 본문과 코멘트 전체 |
| `issue-find-fp -Fingerprint F` | 지문으로 중복 이슈 검색 (열림·닫힘 모두) |
| `issue-create -Title T -BodyFile f.md -Labels a,b` | 이슈 등록 |
| `issue-comment -Number N -BodyFile f.md` | 코멘트 작성 |
| `label-add` / `label-remove -Number N -Labels a,b` | 라벨 추가·제거 |
| `pr-create -Head 브랜치 -Title T -BodyFile f.md [-Base dev]` | PR 생성 |
| `pr-list [-State open]` | PR 목록 (`mergeable` 포함) |
| `close-merged [-DryRun]` | `agent/issue-N` PR이 merge된 열린 이슈 N을 코멘트, 라벨 정리와 함께 닫음. 에이전트가 이슈를 닫는 유일한 경로 |
| `pr-get -Number N` | PR 상세: merge 가능 여부, head/base 브랜치, 본문. PR 코멘트는 `issue-comment -Number <PR번호>`로 답니다 (Gitea에서 PR은 이슈 번호를 공유) |

## 규칙

- **본문은 항상 파일로 전달합니다.** 스크래치 디렉터리에 `.md` 파일을 UTF-8로 쓴 뒤 `-BodyFile`로 넘기세요. 명령줄 인자로 한글 여러 줄을 넘기면 인코딩과 따옴표가 깨지기 쉽습니다.
- **PR merge, 임의의 이슈 close, 삭제 명령은 일부러 만들지 않았습니다.** 병합은 사람이 판단합니다. 이슈 종료는 사람이 PR을 merge한 경우에만 `close-merged`로 합니다. 필요해 보이면 사용자에게 요청하세요.
- 에이전트가 만든 이슈에는 항상 `agent:found` 라벨과 본문 끝의 `<!-- fp:... -->` 지문을 붙입니다. 이 둘이 있어야 `issue-find-fp`가 중복을 찾을 수 있습니다.
- `GITEA_TOKEN`이 없다는 오류가 나면 작업을 멈추고 사용자에게 토큰 등록을 안내하세요. 토큰을 대신 입력하거나 파일에 저장하지 마세요.
