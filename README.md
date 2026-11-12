# LoadWatch

이 맥의 부하를 메뉴바에 상주하며 원인별(빌드·시뮬·에뮬·세션 등)로 보여 주는 앱.
새 세션을 더 띄워도 되는지 한눈에 판단하는 게 목적이다.

## 설치·갱신

```
./build.sh
```

`~/Applications/LoadWatch.app` 설치, 로그인 시 자동 실행(LaunchAgent `com.garen.loadwatch`),
`~/.local/bin/loadwatch` 연결까지 한다. 메뉴에서 종료하면 다시 뜨지 않고, 죽었을 때만 다시 뜬다.

## 보는 법

- 메뉴바: 최근 3분 CPU 그래프 · CPU% · 지금 돌고 있는 것(빌드·색인·시뮬·에뮬·세션 수).
  평소엔 흑백이고, 빠듯·과부하가 되면 그래프와 숫자만 주황·빨강으로 바뀐다.
  메모리 압박이 생기면 메모리 칩 아이콘이 붙는다.
- 드롭다운: 등급과 이유, 10분 원인별 그래프, 원인별 추이·CPU·메모리, 최근 변화(빌드 시작·끝 등).
- 알림: 등급이 바뀔 때, 빌드·시뮬 같은 작업이 시작하고 끝날 때.

## 등급

| 등급 | 조건(하나라도) |
|---|---|
| 과부하 · 새 세션 금지 | CPU 30초 평균 80% 이상, 메모리 압박 위험, 발열 위험 |
| 빠듯 · 새 세션 보류 | CPU 30초 평균 55% 이상, 메모리 압박 경고, 메모리 92% 이상 사용, 발열 높음 |
| 여유 · 새 세션 가능 | 그 밖 |

내려올 때는 5%p 낮아져야 내려온다(경계에서 깜빡임 방지).

## CLI

```
loadwatch status   # 한 줄 판정 + 원인. 종료 코드 0 여유 · 1 빠듯 · 2 과부하 · 3 앱 꺼짐
loadwatch json     # 상태 파일 그대로
loadwatch debug    # 5초 동안 프로세스별 CPU·그룹(분류 규칙 점검용)
```

상태 파일 `~/Library/Application Support/LoadWatch/state.json`, 변화 기록 `~/Library/Logs/LoadWatch/events.log`.

## 자체 부하를 줄인 방식

- 5초 간격, 타이머 여유 1초(다른 깨움과 묶임). 측정은 utility 큐(낮은 우선순위)에서 돌고
  메인 스레드는 그리기·클릭만 한다. 앱 전체를 Background 로 낮췄더니 메뉴 클릭이 굼떠서 되돌렸다.
- 프로세스 목록은 libproc 로 직접 읽는다. `ps` 는 한 번에 CPU 30~70ms 라 쓰지 않고,
  root 프로세스(Spotlight·WindowServer) 몫을 모를 때만 60초에 한 번 백그라운드로 돌린다.
- 메뉴바 아이콘(SF Symbol)은 색·모양별로 한 번만 비트맵으로 굽는다(매번 벡터를 풀면 이게 비용 대부분).
- 메뉴가 열려 있을 땐 다시 짓지 않고 숫자·그래프만 제자리에서 고친다.
- 실측(11-05): 앱 본체 + ps 합쳐 코어 1개 기준 약 0.5%, 10코어 전체의 0.05%.
- 경로·분류는 (pid, 시작 시각)마다 한 번만 계산해 캐시한다.
- 짧게 떴다 끝나는 컴파일러 같은 프로세스는 부모가 거둔 자식 시간(rusage)으로 잡고,
  이미 센 몫은 빼서 이중 집계를 막는다.

## 작업 슬롯(slot)

세션마다 빌드·시뮬을 마음대로 띄우면 CPU 100%·스왑 가득으로 맥 전체가 멈춘다(11-11 load 280).
그래서 무거운 작업은 **슬롯을 받아야 시작**하고, 슬롯이 없거나 부하가 높으면 **먼저 온 순서대로 기다린다**.

- 본체: `slot/slot.py` (`~/.local/bin/slot` 링크). 상태는 `~/Library/Application Support/LoadWatch/slots/`, 기록은 `~/Library/Logs/LoadWatch/slots.log`.
- 자동 적용: `~/.claude/settings.json` 의 PreToolUse 훅이 모든 세션의 Bash 명령을 보고, 무거운 명령이면 앞에 `slot acquire …` 를 붙인다.
  iOS 시뮬레이터 MCP 의 build 도구도 훅으로 슬롯을 받는다. 우회는 명령에 `SLOT_BYPASS=1` 을 넣는다.
- 슬롯은 셸이 끝날 때까지 쥔다(flock, 쥔 프로세스가 죽으면 자동으로 풀림). `expo run:ios` 처럼 빌드 뒤 서버를 계속 띄우는 명령은 네이티브 빌드가 끝나면 푼다. 최대 90분.
- 슬롯을 받은 빌드는 nice 10(UI 우선)으로 돌고, Go 는 `-p=4` 로 패키지 동시 컴파일을 묶는다.

| 클래스 | 대상 | 동시 |
|---|---|---|
| 빌드 | go build/test/vet/install, golangci-lint, xcodebuild, gradlew, eas build --local, expo run·prebuild, pod install, fastlane, `pnpm build`·`npm run ios` 류 | 2 |
| QA | xcodebuild test, connectedAndroidTest, maestro·detox test, `*e2e*` 스크립트 | 1 |
| 검사 | tsc, jest, vitest, eslint, `pnpm test`·`typecheck`·`lint` 류 | 3 |
| 시뮬 | simctl boot, open -a Simulator, emulator -avd (허가만, 켜진 시뮬+에뮬 합계 기준) | 2 |

허가 기준(LoadWatch 상태, 꺼져 있으면 load average):

- CPU 30초 80% 이상 또는 메모리 압박 위험: 빌드·QA·시뮬 모두 대기(검사는 85%).
- CPU 55% 이상 또는 메모리 압박 경고: 빌드·QA 는 한 번에 하나만.
- 그 밖: 클래스별 동시 수까지.
- 45분 기다려도 못 받으면 종료 코드 75 와 함께 「원격 맥·CI 로 돌리거나 사용자에게 알리라」는 안내를 남긴다.

```
slot status            # 쥔 것·기다리는 것
slot pause / resume    # 새 작업 허가 멈춤/재개(돌고 있는 건 그대로)
slot kill              # 슬롯 작업과 대기 모두 취소
slot kill --all-builds # 슬롯 밖에서 돈 Claude 세션 빌드·고아 컴파일러까지(CI 러너 제외)
slot classify <명령>   # 이 명령이 어느 슬롯을 받는지 점검
```

메뉴바: 기다리는 작업이 있으면 「⏳ 대기 N」, 멈춤이면 「멈춤」 배지. 드롭다운의 「작업 슬롯」에서 현황을 보고 멈춤·취소를 누른다.
