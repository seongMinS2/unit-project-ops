---
name: plan-todo
description: unit-project에서 agent:todo 라벨이 붙은(사람이 에이전트에게 맡긴) 이슈를 모아, 수정 파일이 겹치는 이슈는 같은 레인에 순서대로, 겹치지 않는 이슈는 다른 레인에 배치하는 병렬 처리 계획을 JSON으로만 출력한다. scripts/run-todo.ps1이 호출하며, 인자로 이슈 번호를 주면 그 이슈들로 계획만 세운다. 라벨 변경이나 실제 처리는 하지 않는다.
---

# Plan Todo: 맡겨진 이슈의 병렬 처리 계획

이 스킬은 **계획만** 세웁니다. 라벨 교체와 실행은 `scripts/run-todo.ps1`이 합니다. 판단이 필요한 부분(어떤 이슈끼리 파일이 겹치는지)만 여기서 맡습니다.

## 1. 대상

- 인자로 번호가 오면 그 이슈들이 대상입니다.
- 인자가 없으면 `gitea` 스킬로 `issue-list -Labels agent:todo`를 실행해 열린 이슈를 가져옵니다.
- `agent:in-progress`, `agent:pr-open`이 함께 붙은 이슈는 이미 처리 중이므로 `skipped`로 보냅니다.
- `agent:blocked`와 `agent:todo`가 **함께** 붙어 있으면 사람이 답을 주고 다시 맡긴 것입니다. 건너뛰지 말고 **포함**하세요(착수할 때 `agent:blocked`는 자동으로 제거됩니다). 막혔던 질문에 대한 답이 코멘트에 있으니, 그 이슈를 맡는 세션은 코멘트를 끝까지 읽어야 합니다.

## 2. 이슈별 영향 범위 추정

각 이슈를 `issue-get`으로 읽고, 수정하게 될 **파일과 도메인 패키지**(`com.gmission.webfax.<도메인>`)를 추정합니다.
- 본문의 "위치"와 코드 경로를 우선 봅니다.
- 경로가 없는 기능 요청은 `workspace/unit-project`에서 관련 컨트롤러, 서비스, 템플릿을 Grep으로 찾아 추정합니다.
- 공용 영역(`bootstrap/`, `platform/`, `SecurityConfig`, `application*.yaml`, `build.gradle`)을 건드릴 이슈는 충돌 위험이 크니 표시해 둡니다.

## 3. 레인 배치

- 추정한 파일이 하나라도 겹치거나, 같은 도메인의 같은 계층(api/core/infra)을 크게 바꾸는 이슈끼리는 **같은 레인**에 넣습니다. 순서는 심각도가 높은 것부터이고, 같으면 번호순입니다.
- 공용 영역을 건드리는 이슈끼리도 같은 레인에 넣습니다.
- 레인은 **최대 5개**입니다. 레인이 더 필요하면 가장 짧은 레인 뒤에 이어 붙입니다. 실행기가 여유 메모리를 보고 필요하면 레인을 합치므로, 여기서는 "겹치지 않으면 나눈다"는 기준만 지키면 됩니다.
- 한 번 실행에 처리할 이슈는 최대 12개입니다. 나머지는 `deferred`로 보내 다음 실행에서 처리합니다.

## 4. 출력

마지막 응답은 아래 JSON **하나만** 출력합니다. 스크립트가 이 출력을 그대로 파싱합니다.
```json
{"lanes": [[36, 40], [35]],
 "reasons": {"36": "infax/api InfaxQueryController", "40": "infax/api 같은 컨트롤러라 #36 뒤", "35": "doctransfer + chat/ws + 프론트 알림"},
 "skipped": [{"issue": 12, "reason": "agent:pr-open"}],
 "deferred": []}
```
대상이 없으면 `{"lanes": [], "reasons": {}, "skipped": [], "deferred": []}`를 출력합니다.
