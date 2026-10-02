# 소반 (Soban)

> 내 모습으로 만든 페르소나를 허공에 띄우고, 한국식 좌식 두레반에 둘러앉아 이야기하는 Apple Vision Pro 앱.

![Vision Pro 실기기 — iPhone 에서 받은 가우시안 스플랫 페르소나 초안](Docs/screenshots/device/visionpro-received-from-iphone.png)

**소반**은 작은 좌식 상을 뜻합니다. 이 앱은 사진 한 장으로 투명 배경의 2.5D 페르소나를 만들고, Vision Pro 의 머리 자세·손 위치·목소리로 그 페르소나를 살아 움직이게 한 뒤, 같은 Wi‑Fi 의 Vision Pro 들과 두레반 여섯 자리에 둘러앉게 합니다. 모든 처리는 기기 안에서 끝나고 서버는 없습니다.

## 데모 영상

| [![소반앱 - 좌식테이블에 둘러앉아 소통 (Demo)](https://img.youtube.com/vi/YkVojNS1Je8/hqdefault.jpg)](https://youtu.be/YkVojNS1Je8) | [![소반앱 - 좌식테이블에 둘러앉아 소통 (Demo) 2](https://img.youtube.com/vi/M_rHSixSkKw/hqdefault.jpg)](https://youtu.be/M_rHSixSkKw) | [![소반앱 - 좌식테이블에 둘러앉아 소통 (Demo) 3](https://img.youtube.com/vi/BjRCnjIqMcg/hqdefault.jpg)](https://youtu.be/BjRCnjIqMcg) |
|---|---|---|
| [Demo 1 — 좌식테이블에 둘러앉아 소통](https://youtu.be/YkVojNS1Je8) | [Demo 2](https://youtu.be/M_rHSixSkKw) | [Demo 3](https://youtu.be/BjRCnjIqMcg) |

Apple Vision Pro 실기기에서 녹화한 영상입니다. 썸네일을 누르면 YouTube 로 이동합니다.

## 기능

- **페르소나 스튜디오** — 사진 보관함에서 고른 사진을 Vision 으로 인물만 분리하고 눈·입·코 랜드마크를 찾아 "종이 인형" 카드를 만듭니다. 이름, 입 벌림 강도, 카드 높이를 다듬고 마이크로 바로 움직여 볼 수 있습니다.
- **살아 움직이는 페르소나** — 머리 yaw/pitch/roll 과 이동, 손목 위치(반투명 손), 목소리 크기에 따른 입 벌림, 주기적 눈 깜빡임, 호흡, 말할 때 밝아지는 바닥 글로우, 이름표와 반응 말풍선.
- **두레반 공간** — 혼합(mixed) 이머시브 공간에 옻칠 원탁, 방석 6개, 찻잔, 다관, 다과를 놓습니다. 나는 항상 가까운 자리, 다른 사람들은 반시계 방향으로 앉습니다.
- **모임** — 모임 열기/참여(로컬 네트워크 P2P), 호스트가 좌석표를 관리, 페르소나 교환, 15Hz 포즈, 60ms 음성 청크를 좌석 위치에서 공간 재생, 반응 이모지(👋 👍 ❤️ 😂 🍵 👏).
- **데모 손님** — 혼자서도 상이 북적이도록 번갈아 이야기하고 손을 드는 손님 5명. 한국어 TTS 로 실제로 말하고(좌석 위치에서 공간 재생), 그 음량 엔벨로프로 입이 움직입니다.
- **내 모습 보기(거울)** — 대화 중 내 페르소나가 어떻게 보이는지 3인칭으로 확인할 수 있도록 내 자리 오른쪽 위에 거울처럼 띄웁니다.
- **가우시안 스플랫 입체화** — 촬영한 깊이 맵(TrueDepth·LiDAR), 깊이가 없으면 얼굴 리그에 맞춘 머리 타원체 부조로 3D 점을 만들고 각 점을 가우시안 스플랫으로 초기화합니다. 측면 사진은 코 위치로 회전각을 추정해 머리 옆면 색을 채웁니다. 같은 코드가 iPhone/iPad/Mac 과 Vision Pro 에서 돌아 **컴패니언에서 만들어 보내거나, 사진만 보내 Vision Pro 가 만들** 수 있습니다. 받은 결과는 초안으로 떠 있다가 **'내 페르소나로 저장' 즉시 활성화**됩니다. 표준 **3DGS PLY** 로 내보낼 수 있습니다. (학습 최적화는 하지 않는 깊이/부조 초기화형 스플랫입니다.)
- **파일로 주고받기** — 컴패니언은 **3DGS PLY** 와 **`.sobanpersona` 패키지**(카드·깊이·측면·스플랫 한 묶음)를 공유합니다. Vision Pro 에서는 스튜디오의 **파일에서 불러오기** 또는 AirDrop 공유 시트에서 '소반' 을 고르면 바로 초안으로 열립니다. PLY 만 받아도 스플랫에서 카드 이미지를 렌더링하고 얼굴 리그를 다시 검출합니다(위아래 뒤집기 토글 포함).
- **입 모양 신호** — Vision Pro 는 내부 카메라/LiDAR 접근이 없어 마이크 음량을 쓰고(레벨미터·권한 상태·허용 버튼), iPhone/iPad 는 **TrueDepth ARKit 얼굴 추적(jawOpen)**, Mac 은 **카메라 입술 랜드마크**, 그다음 마이크 순으로 자동 분기합니다.
- **소반 캡처 (iPhone · iPad · Mac)** — 같은 코드베이스가 iOS/iPadOS/macOS 로도 빌드됩니다. Vision Pro 는 서드파티 카메라 접근이 막혀 있으므로, Vision Pro 를 잠시 벗고 iPhone/iPad(TrueDepth·LiDAR 깊이 카메라) 또는 Mac(일반 카메라)에서 **정면 → 한쪽 → 반대쪽 → 위** 각도 안내에 따라 자동 촬영하고, 만든 페르소나를 같은 Wi‑Fi 의 Vision Pro 로 보냅니다(또는 AirDrop).

## 화면

### 실기기 (Apple Vision Pro · iPhone)

| Vision Pro — 스튜디오, 실제 사진 페르소나 (카드) | Vision Pro — 같은 페르소나를 가우시안 스플랫 입체로 |
|---|---|
| ![Vision Pro 스튜디오 카드](Docs/screenshots/device/visionpro-studio-card.png) | ![Vision Pro 스튜디오 스플랫](Docs/screenshots/device/visionpro-studio-splat.png) |

| Vision Pro — '기기에서 받기' 대기 중 | Vision Pro — iPhone 에서 받은 스플랫 초안 (깊이 · 측면 3장 · 스플랫 18,634개) |
|---|---|
| ![기기에서 받기](Docs/screenshots/device/visionpro-studio-receiving.png) | ![iPhone 에서 받은 초안](Docs/screenshots/device/visionpro-received-from-iphone.png) |

| iPhone 소반 캡처 — TrueDepth 깊이, 입체(스플랫) 미리보기 | iPhone — TrueDepth 얼굴 추적으로 입 모양, PLY · .sobanpersona 공유 | iPhone — Vision Pro 로 보내기 |
|---|---|---|
| ![iPhone 스플랫 미리보기](Docs/screenshots/device/iphone-capture-splat-preview.png) | ![iPhone 입 모양 얼굴 추적](Docs/screenshots/device/iphone-capture-mouth-facetracking.png) | ![iPhone 전송](Docs/screenshots/device/iphone-capture-send.png) |

위 화면은 Apple Vision Pro 와 iPhone 실기기 캡처입니다. iPhone 에서 TrueDepth 로 찍어 만든 가우시안 스플랫 페르소나가 로컬 네트워크로 Vision Pro 에 초안으로 도착한 흐름을 보여 줍니다.

### 시뮬레이터 · Mac

| 홈 | 페르소나 스튜디오 |
|---|---|
| ![홈](Docs/screenshots/home.png) | ![스튜디오](Docs/screenshots/studio.png) |

| 모임 | 두레반 (이머시브) — 오른쪽 위가 "내 모습 보기" 거울 |
|---|---|
| ![모임](Docs/screenshots/gathering.png) | ![두레반](Docs/screenshots/table-demo-guests.png) |

| 스튜디오 — 가우시안 스플랫 입체 | 두레반 — 스플랫 손님들 |
|---|---|
| ![스플랫 스튜디오](Docs/screenshots/studio-splat.png) | ![스플랫 손님](Docs/screenshots/table-splat-guests.png) |

| 스튜디오 — PLY 파일 불러오기 (라운드트립) |
|---|
| ![PLY 불러오기](Docs/screenshots/studio-import-ply.png) |

| 소반 캡처 (Mac, 실제 카메라) |
|---|
| ![소반 캡처](Docs/screenshots/companion-mac-capture.png) |

이 절의 visionOS 화면은 visionOS 27 시뮬레이터에서 `sample demo guests=4` 플래그로 캡처했습니다(시뮬레이터에는 손 추적·마이크가 없어 데모 손님이 대신 움직입니다). 소반 캡처 화면은 Mac 의 FaceTime 카메라로 실제 촬영 중인 모습입니다.

## 다이어그램

### 아키텍처 레이어

UI(창·이머시브 공간) → 상태/도메인(`AppModel`·`PersonaStore`·`GatheringSession`·`TableRenderer`) → 엔진(Vision·RealityKit·ARKit·AVFAudio) → 전송(`SessionTransport`) 4계층 구조.

![아키텍처 레이어](Docs/diagrams/architecture-layers.svg)

### 페르소나 캡처 파이프라인

사진 한 장이 `GeneratePersonInstanceMaskRequest` → `DetectFaceLandmarksRequest` → 크롭·색 샘플을 거쳐 살아 움직이는 카드가 되는 과정과, `PersonaManifest`/`PersonaAvatar` 레이어 구조.

![페르소나 캡처 파이프라인](Docs/diagrams/persona-pipeline.svg)

### 모임 세션 흐름

호스트/손님이 MultipeerConnectivity 풀 메시로 좌석표·페르소나·포즈·음성·반응을 주고받는 순서(시퀀스 다이어그램).

![모임 세션 흐름](Docs/diagrams/session-flow.svg)

### 두레반 좌석 배치

6석 원탁을 위에서 본 배치(`TableLayout`, 1 m = 160 px)와 옆에서 본 높이·카드 피벗 기준.

![두레반 좌석 배치](Docs/diagrams/table-layout.svg)

### 라이브 포즈 루프

`GatheringSession.tick()` 30Hz 루프에서 머리/손/마이크 신호가 `PersonaPose` 로 묶여 네트워크를 거쳐 `PersonaAvatar.update` 까지 가는 경로, 데모 손님(`BotBrain`)의 자체 루프.

![라이브 포즈 루프](Docs/diagrams/live-pose-loop.svg)

### 모습 수집 분기 (Vision Pro / iPhone·iPad / Mac)

`CaptureAvailability.detect()` 가 플랫폼별로 Vision Pro(카메라 접근 불가) · iPhone/iPad(TrueDepth·LiDAR 깊이) · Mac(일반 카메라)으로 갈라지는 경로와 각도 안내·전송 흐름.

![모습 수집 분기](Docs/diagrams/capture-branches.svg)

### 가우시안 스플랫 파이프라인 · 입 신호 우선순위

`SplatBuilder` 가 깊이/부조로 3D 점을 만들고 측면 사진으로 색을 채워 `SplatMesh` 로 렌더링하는 과정, 그리고 플랫폼별 입 모양 신호 우선순위(얼굴 추적 → 입술 랜드마크 → 마이크).

![가우시안 스플랫 파이프라인](Docs/diagrams/splat-pipeline.svg)

## 어떻게 동작하나

```
사진 ─▶ GeneratePersonInstanceMaskRequest ─▶ DetectFaceLandmarksRequest ─▶ 크롭·색 샘플 ─▶ manifest.json + body.png
Vision Pro 머리(WorldTrackingProvider) · 손(HandTrackingProvider) · 마이크 RMS ─▶ PersonaPose ─▶ 15Hz 브로드캐스트
PersonaPose ─▶ PersonaAvatar(RealityKit 레이어: 카드·입·눈꺼풀·손·글로우) ─▶ 두레반 슬롯에 빌보딩
```

자세한 설계와 제약(카메라 접근 불가, 개인 팀의 SharePlay 제약, visionOS 27 의 MultipeerConnectivity deprecated 등)은 [Docs/TechPRD.md](Docs/TechPRD.md), 작업 목록은 [Docs/Tasks.md](Docs/Tasks.md) 를 보세요.

## 요구 사항

- Xcode 27, visionOS 27 SDK (iOS/macOS 배포 타깃 26.0)
- Apple Vision Pro (visionOS 27) — 머리/손 추적, 마이크, 로컬 네트워크는 실기기에서만 동작
- 소반 캡처: iPhone/iPad(iOS 26+, 깊이 카메라 권장) 또는 Mac(macOS 26+)
- 다중 사용자 테스트는 같은 Wi‑Fi 의 Vision Pro 2대 이상

## 빌드와 실행

1. `Untitled Project.xcodeproj` 를 열고 타깃 `MyApp`(표시 이름 소반)을 선택합니다.
2. 서명 팀을 본인 팀으로 바꿉니다. 특별한 엔타이틀먼트는 필요 없습니다.
3. Vision Pro 를 선택하고 Run. 첫 실행에서 마이크·손 추적·로컬 네트워크 권한을 허용합니다.
4. (선택) 같은 타깃을 iPhone/iPad/Mac 에 Run 하면 "소반 캡처" 가 뜹니다. Vision Pro 의 페르소나 탭 → **기기에서 받기** 를 켠 뒤, 캡처 기기에서 촬영 → 페르소나 만들기 → Vision Pro 이름 선택 → 보내기.

시뮬레이터 자동 실행(DEBUG 전용 인자):

```bash
xcodebuild -project "Untitled Project.xcodeproj" -scheme MyApp \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build
xcrun simctl launch booted com.coulson.Soban sample demo guests=5 hidewindow distance=2.1
```

| 인자 | 뜻 |
|---|---|
| `sample` | 저장된 페르소나가 없으면 샘플 페르소나 생성 |
| `demo` | 시작 즉시 이머시브 공간 + 데모 손님 |
| `guests=N` | 데모 손님 수 (최대 5) |
| `tab=home\|studio\|gathering` | 시작 탭 |
| `hidewindow` | 이머시브가 열리면 창 닫기(스크린샷용) |
| `distance=1.6` | 테이블 거리(m) |
| `splats` | 샘플 페르소나와 데모 손님을 가우시안 스플랫 입체로 |
| `exportply=/path.ply` | 활성 페르소나 스플랫을 3DGS PLY 로 기록 |
| `import=/path` | `.sobanpersona` / `.ply` 를 불러와 초안으로 (파서 검증용) |

시뮬레이터에서는 오디오 엔진이 기본으로 꺼집니다(AURemoteIO 초기화 타임아웃 회피). 켜려면 환경 변수 `SOBAN_SIM_AUDIO=1`.

## 프로젝트 구조

```
MyApp/
  MyApp.swift (visionOS: SobanApp / 그 외: SobanCompanionApp) · ContentView.swift
  App/        AppModel · LaunchOptions · HomeView · StudioView · GatheringView · PersonaPreviewView   [visionOS]
  Persona/    PersonaModels · PersonaBuilder(+DepthRefiner) · PersonaStore · PlaceholderPersona        [공용]
              SplatCloud · SplatBuilder · SplatMesh · PersonaAvatar                                     [공용]
  Sensing/    MouthSource(MicLevelMeter)                                                                [공용]
              FaceMouthTracker                                                                          [iOS]
              HeadHandTracker · VoiceEngine                                                             [visionOS]
  Room/       TableLayout(공용) · TableScene · TableRenderer · TableImmersiveView                        [visionOS]
  Session/    SessionMessages · MultipeerTransport(SessionTransport/PeerHandle) · DemoGuests            [공용]
              GatheringSession · BotSpeech(TTS)                                                         [visionOS]
  Capture/    CaptureAvailability · CaptureGuide · PersonaTransfer(Receiver 공용 / Sender iOS·macOS)
              CameraCaptureController                                                                   [iOS·macOS]
  Companion/  CompanionRootView                                                                         [iOS·macOS]
Docs/         TechPRD.md · Tasks.md · diagrams/*.svg · screenshots/*.png
```

## 실기기 피드백 반영 (2026-10-02 2차)

| 보고된 문제 | 조치 |
|---|---|
| 스튜디오 미리보기 볼륨이 사진 보관함 시트를 가림 | 3D 콘텐츠를 유리면 뒤 5cm 로 옮기고, 피커/시트가 떠 있는 동안 숨김 |
| 마이크 레벨미터는 움직이는데 입이 안 움직임 | `.task` 가 시작 시점 값만 캡처하던 버그 → 매 프레임 호출되는 `levelSource` 클로저로 교체 |
| 이름을 바꿔도 미리보기 이름표에 반영할 버튼이 없음 | 입력 즉시 이름표 반영 + **이름 적용** 버튼(초안/현재 페르소나 저장) |
| 데모 손님 목소리가 없음 | `AVSpeechSynthesizer.write` 한국어 TTS → 좌석 위치 공간 재생 + 엔벨로프 입 동기화, 자리 카드에 자막 |
| 대화 중 내 모습을 3인칭으로 볼 수 없음 | **내 모습 보기(거울)** 토글 — 내 자리 오른쪽 위에 좌우 반전된 내 아바타 |
| Vision Pro 를 벗고 촬영하는 기능 | visionOS 는 카메라 접근 불가 → 런타임 판별 후 안내, iPhone/iPad(깊이)·Mac(일반) **소반 캡처** 분기 + 전송 |
| 상 접기 후 다시 펼쳐지지 않음 | ARKit 세션/프로바이더는 stop 후 재사용 불가 → 매번 재생성, 이머시브 상태를 뷰 생명주기로 동기화, 실패 사유 표시 |

## 3차 개선 (2026-10-02)

| 요청 | 조치 |
|---|---|
| 컴패니언에서 다각도 촬영 → 가우시안 스플랫 → Vision Pro 로 전송/감상 | `SplatBuilder`(깊이/부조 초기화 + 측면 융합), `SplatMesh`(RealityKit 쿼드 아틀라스), 입체 미리보기 턴테이블, 3DGS PLY 내보내기, 스플랫 포함/사진만 전송 |
| Vision Pro 가 스플랫을 받거나 사진만 받아 직접 만들어 초안으로, 저장 즉시 사용 | `PersonaReceiver` 가 리소스 묶음을 조립 → 스튜디오 **초안**(스플랫 없으면 Vision Pro 가 생성) → '내 페르소나로 저장 (바로 사용)' |
| 입 모양: 레벨미터, 내부 센서 가능하면 사용·불가하면 마이크, 컴패니언에도 포함 | `VoiceLevelBar`(피크 홀드) + 권한 상태/허용 버튼, visionOS 는 센서 불가 안내 후 마이크, iPhone/iPad TrueDepth `jawOpen`, Mac 입술 랜드마크, 마이크 폴백 |

## 4차 수정 (2026-10-02)

| 보고 | 조치 |
|---|---|
| Vision Pro 에 PLY 를 받아도 불러올 버튼이 없음 | `fileImporter` **파일에서 불러오기**, `.sobanpersona`/PLY 문서 타입 등록 + `onOpenURL`(AirDrop → '소반' 으로 열기), PLY 파서 → 카드 렌더 → 얼굴 리그 재검출, 위아래 뒤집기, 컴패니언에 `.sobanpersona` 공유 추가 |
| 마이크 토글 후 레벨미터 무반응, '마이크 허용 요청' 무기능, "사용 가능한 마이크 입력이 없습니다" | 출력 전용으로 먼저 시작된 `AVAudioEngine` 에서 나중에 `inputNode` 를 만지면 포맷이 0 이 되는 문제 → 엔진 시작 **전에** 입력 노드 구성, 필요 시 재시작. 버튼은 실제 권한 요청 → 입력 포함 재시작 → 탭 설치. 입력 포맷/라우트 진단 문구 표시 |

## 로드맵

- 스플랫 미분 최적화(학습) — 현재는 초기화만 (Metal 컴퓨트 기반 소규모 최적화 검토)
- Network.framework 전송 계층(TN3213)으로 MultipeerConnectivity 교체
- 음소 기반 입 모양, 사진 입체화(Spatial3DImage), 교자상 변형
- 같은 방에서 `SharedCoordinateSpaceProvider` 로 한 테이블 공유
- 유료 팀 전환 시 GroupActivities(FaceTime) 어댑터

## 라이선스

[Apache License 2.0](LICENSE). Apple 프레임워크는 Apple SDK 라이선스를 따릅니다([NOTICE](NOTICE)).

---

### English summary

**Soban** (소반, "small low table") is a visionOS 27 app for Apple Vision Pro. Pick one photo of yourself; Vision separates the person from the background and finds eye/mouth landmarks to build a transparent 2.5D "paper doll" persona. The persona comes alive from the headset's device anchor (head yaw/pitch/roll), hand-tracking wrists, and microphone level (mouth opening), plus blinking and breathing. Up to six people sit around a Korean floor table in a mixed immersive space; peers on the same Wi‑Fi connect through a full-mesh MultipeerConnectivity session (SharePlay is unavailable to personal developer teams), exchange persona packages, stream 15 Hz pose packets and 60 ms voice chunks that are spatialized at each seat, and send emoji reactions. Demo guests speak with Korean TTS and lip-sync to it; a mirror toggle shows your own persona in third person. Because visionOS gives third-party apps no camera access, the same target also builds as **Soban Capture** for iPhone/iPad (TrueDepth/LiDAR depth) and Mac (plain camera): guided front/side/up captures, depth-refined cutout, and transfer to the Vision Pro over the local network or AirDrop. Captures are turned into **Gaussian splats** (depth- or face-rig-relief-initialized, side views color the head's sides, no differentiable training), rendered with a RealityKit quad atlas on every platform, exportable as standard 3DGS PLY, and received on Vision Pro as a draft that becomes the active persona on save. Mouth motion falls back from TrueDepth face tracking (iPhone/iPad) → camera lip landmarks (Mac) → microphone level (Vision Pro has no inward camera access). Licensed under Apache-2.0.
