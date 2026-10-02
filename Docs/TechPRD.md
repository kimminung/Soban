# 소반 (Soban) — Tech PRD

> visionOS 27 · Apple Vision Pro · Swift 6 toolchain (Swift 5 언어 모드, 기본 MainActor 격리)
> 작성일 2026-10-02 · 상태: v0.3 (가우시안 스플랫 입체화 · 입 신호 분기 · 다중 리소스 전송 추가)

## 1. 한 줄 요약

사용자의 **사진 한 장**으로 투명 배경의 2.5D "종이 인형" 페르소나를 만들고, Vision Pro 의 **머리 자세·손 위치·목소리**로 그 페르소나를 살아 움직이게 한 뒤, 여러 명이 **한국식 좌식 두레반**에 둘러앉아 각자의 페르소나를 방석 위에 띄워 놓고 이야기하는 visionOS 앱.

## 2. 배경과 제약 (왜 이렇게 설계했나)

| 제약 | 사실 | 설계 결정 |
|---|---|---|
| 카메라 | visionOS 는 서드파티 앱에 패스스루 카메라를 열어 주지 않는다 (Enterprise 라이선스 + `com.apple.developer.arkit.main-camera-access.allow` 필요). 시스템 Persona 도 API 로 접근 불가. | "모습 수집" = **사진 보관함에서 가져오기** → Vision 으로 인물 분리/얼굴 랜드마크. 모든 처리는 온디바이스. |
| 얼굴 추적 | visionOS 에는 서드파티용 얼굴/표정 추적 API 가 없다. | 입 모양은 **마이크 RMS** 로, 깜빡임은 타이머로, 고개는 **디바이스 앵커**로 근사한다. |
| SharePlay | 개인(무료) 개발자 팀 `5Z8G42AVKD` 는 Group Activities 자격을 받을 수 없다 (이전 프로젝트에서 기기 빌드 실패로 확인). | **MultipeerConnectivity** 로컬 네트워크 풀 메시. 전송 계층은 `SessionTransport` 프로토콜 뒤에 둔다. |
| MC 상태 | visionOS 27 SDK 에서 MultipeerConnectivity 전체가 deprecated ("Use Network Framework instead"). 동작은 한다. | v1 은 MC, v2 는 TN3213 에 따라 Network.framework(`NWListener`/`NWBrowser`/`NWConnection`) 로 교체. MC 타입은 `MultipeerTransport.swift` 밖으로 새지 않는다. |
| 시뮬레이터 | 손 추적 없음, 디바이스 앵커 느림/없음, AURemoteIO 초기화 RPC 타임아웃으로 abort 가능(실제로 발생). `Spatial3DImage.generate()` 불가. | 오디오 엔진은 **지연 시작** + 시뮬레이터에서는 기본 OFF(`SOBAN_SIM_AUDIO=1` 로 강제, 마이크 권한도 요청하지 않음). 데모 손님(BotBrain)으로 네트워크/추적 없이 전체 루프 검증. |
| ARKit 수명 | `ARKitSession`/`DataProvider` 는 `stop()` 후 재사용 불가(`.stopped` 고정). | `HeadHandTracker.start()` 마다 세션·프로바이더를 새로 만든다. 상 접기→펼치기 재현 버그의 원인. |
| 창 안 3D | 2D 창의 `RealityView` 콘텐츠는 유리면 앞으로 튀어나오면 시트·피커를 가린다. | 미리보기 루트를 z = −5 cm 로, 피커/시트 표시 중에는 `isEnabled = false`. |
| SwiftUI `.task` | 클로저는 시작 시점의 `self`(구조체 값)를 캡처한다. | 마이크 레벨은 `levelSource: () -> Float` 클로저로 매 프레임 읽는다(클래스 `StudioModel` 참조). |
| 다중 플랫폼 | 같은 타깃을 iOS/iPadOS/macOS 로도 빌드. macOS 에는 깊이 전달 API(`isDepthDataDeliveryEnabled`, `photo.depthData`, `photo.metadata`)가 없다. | visionOS 전용 파일은 `#if os(visionOS)`, 캡처는 `#if os(iOS) \|\| os(macOS)`, 깊이는 `#if os(iOS)`. 공용 모델/빌더/전송은 순수 CoreGraphics·Foundation. |

## 3. 목표 / 비목표

**목표 (v1)**
1. 사진 → 페르소나 패키지(`manifest.json` + `body.png` [+ `depth.png`, `side-*.png`]) 생성, 저장, 선택, 삭제, 이름 변경.
2. 페르소나가 고개(yaw/pitch/roll)·위치·입·눈·손으로 살아 움직인다.
3. 두레반(원탁) 6석. 나는 항상 가까운 자리, 나머지는 반시계 방향. **내 모습 보기(거울)** 로 3인칭 확인.
4. 같은 Wi‑Fi 의 Vision Pro 끼리 호스트/참여, 좌석표 동기화, 페르소나 교환, 포즈 15Hz, 음성 60ms 청크 공간 재생, 반응 이모지.
5. 혼자서도 북적이는 **데모 손님** 모드 — 한국어 TTS 로 말하고 입이 동기화된다.
6. **소반 캡처**: iPhone/iPad(깊이 카메라) · Mac(일반 카메라)에서 각도 안내 촬영 → 페르소나 생성 → Vision Pro 로 전송.

**비목표 (v1)**
- 사실적 3D 메시 아바타, 표정 블렌드셰이프, 입술 동기(viseme).
- 인터넷(원격) 접속, 서버, 계정.
- 녹화/공유, 텍스트 채팅.

## 4. 사용자 흐름

```
홈 ─▶ 페르소나 스튜디오 ─▶ [사진 보관함 | 샘플로 체험] ─▶ 분석(5단계 진행률) ─▶ 다듬기(이름·입 강도·카드 높이)
   ─▶ 움직여 보기(마이크 / 말하기 시뮬레이션) ─▶ 저장 ─▶ 홈
홈 ─▶ 모임 ─▶ [데모 손님과 | 모임 열기 | 모임 참여 ─▶ 근처 소반 목록 ─▶ 앉기]
   ─▶ 소반 펼치기(이머시브 .mixed) ─▶ 자리 그리드 · 반응 · 마이크 · 테이블 거리 · 정면 다시 맞추기
```

## 5. 시스템 구성

### 5.1 모듈

| 파일 | 역할 |
|---|---|
| `Persona/PersonaModels.swift` | `NRect`/`NPoint`/`RGB`, `FaceRig`, `PersonaManifest`, `PersonaPackage`, `PersonaPose`, `Reaction` (전부 `nonisolated struct/enum`) |
| `Persona/PersonaBuilder.swift` | Vision 파이프라인 (`@concurrent`), `RGBARaster` CPU 샘플러, PNG 인코딩 |
| `Persona/PlaceholderPersona.swift` | CoreGraphics 로 그리는 샘플/손님 페르소나 5종 스타일 |
| `Persona/PersonaStore.swift` | `Documents/Personas/<uuid>/` 저장·로드·캐시, 활성 페르소나 |
| `Persona/PersonaAvatar.swift` | RealityKit 레이어 아바타 + `TextureFactory` + 이름표/반응 Attachment |
| `Sensing/HeadHandTracker.swift` | ARKitSession(World + Hand) → `PersonaPose` |
| `Sensing/VoiceEngine.swift` | 마이크 탭(16kHz Int16), 공간 재생(`AVAudioEnvironmentNode`), `CaptureSink` |
| `Room/TableLayout.swift` | 6석 링 기하, 슬롯 회전 |
| `Room/TableScene.swift` | 두레반·방석·찻잔·다관·다과 프로시저럴 메시 |
| `Room/TableRenderer.swift` | 참가자 → 아바타 동기화, 빌보딩 |
| `Room/TableImmersiveView.swift` | ImmersiveSpace 의 RealityView |
| `Session/SessionMessages.swift` | `SessionMessage` (binary plist) |
| `Session/MultipeerTransport.swift` | `SessionTransport` 프로토콜, `PeerHandle`, MC 구현 |
| `Session/DemoGuests.swift` | `BotBrain` |
| `Session/GatheringSession.swift` | 상태 머신, 좌석표, 30Hz 틱, 메시지 처리, 데모 손님 턴/TTS, 거울 |
| `Session/BotSpeech.swift` | `AVSpeechSynthesizer.write` → PCM 버퍼 + 50ms 엔벨로프 (visionOS) |
| `Capture/CaptureAvailability.swift` | 플랫폼별 카메라 능력 판별 (`CaptureCapability`), 기기 이름 |
| `Capture/CaptureGuide.swift` | 정면/한쪽/반대쪽/위 각도 안내 상태 기계 (플랫폼 독립) |
| `Capture/CameraCaptureController.swift` | AVCaptureSession, 프레임 미리보기, 동기 Vision yaw/pitch, 깊이 사진 (iOS·macOS) |
| `Capture/PersonaTransfer.swift` | `PersonaReceiver`(Vision Pro, 광고/저장) · `PersonaSender`(캡처 기기, 탐색/전송) |
| `Companion/CompanionRootView.swift` | 소반 캡처 UI (iOS·macOS) |
| `App/*` | `AppModel`(이머시브 열기/닫기 헬퍼), `LaunchOptions`, Home/Studio/Gathering/Preview 뷰, `StudioModel`, `CaptureOptionsSheet` |

### 5.2 페르소나 캡처 파이프라인 (`PersonaBuilder.build`)

1. `CGImageSourceCreateThumbnailAtIndex` 로 EXIF 회전 적용 + 긴 변 1024px.
2. `GeneratePersonInstanceMaskRequest` → `InstanceMaskObservation.generateMaskedImage(for: allInstances, imageFrom:)`. 인물이 없으면 `GenerateForegroundInstanceMaskRequest` 로 폴백, 그래도 없으면 `noPerson` 오류.
3. `DetectFaceLandmarksRequest` → 가장 큰 얼굴. `leftEye`/`rightEye`(패딩 35%), `outerLips`(패딩 12%, 세로 최소 = 가로×0.45), `nose` 중심.
4. `RGBARaster` 로 알파 바운딩 박스(threshold 24) + 4% 여백 크롭. 뺨 평균색 → 피부, 입술 안쪽 → 입술(기본값과 35% 혼합), 얼굴 아래 18% 지점 → 의상(accent).
5. PNG 인코딩. 결과 `PersonaPackage`.

정규화 좌표는 **크롭된 body.png 기준, 좌상단 원점** 이므로 네트워크 수신 측도 추가 정보 없이 리그를 복원할 수 있다.

**깊이 보정(`DepthRefiner`, 캡처 경로)**: 깊이 맵(미터, NaN 허용)에서 얼굴 박스 중앙값 `d_face` 를 구하고, `d > d_face + 0.45 m` 인 픽셀의 알파를 0.12 m 폭으로 부드럽게 0 까지 깎는다. Vision 마스크의 배경 번짐(벽, 의자)을 제거한다. 깊이는 가까울수록 밝은 8비트 `depth.png` 로 저장(`hasDepth = true`)되어 v2 입체화에 쓴다.

### 5.2b 소반 캡처 (iPhone · iPad · Mac)

| 단계 | 구현 |
|---|---|
| 능력 판별 | `CaptureAvailability.detect()`: visionOS → `.unavailable` (서드파티 카메라 접근 없음), iOS 전면 TrueDepth → `.depthFront`, 후면 LiDAR → `.depthRear`, 그 외 → `.cameraOnly`, macOS → `.cameraOnly` |
| 세션 | `AVCaptureSession(.photo)`, 전면 카메라 기본. `AVCaptureVideoDataOutput`(BGRA, 480px 미리보기, 전면은 거울 반전), `AVCapturePhotoOutput`(iOS: `isDepthDataDeliveryEnabled`) |
| 각도 | 6프레임마다 레거시 `VNDetectFaceRectanglesRequest`(동기, 델리게이트 스레드) → yaw/pitch(도). `CaptureGuide` 가 정면 → 한쪽(부호 기억) → 반대쪽(반대 부호) → 위 순으로 0.7초 유지 시 자동 촬영. "이 단계 건너뛰기" 가능 |
| 사진 | `cgImageRepresentation()` + EXIF 방향(iOS) → 업라이트. 깊이는 `AVDepthData.converting(toDepthDataType: DepthFloat32)` 를 같은 방향으로 회전해 `DepthMap` 으로. 저장 사진은 거울 반전하지 않는다(남이 보는 모습) |
| 생성 | `PersonaBuilder.build(capture:)` — 정면(+깊이)으로 카드, 측면/위는 `side-*.png` |
| 전송 | Vision Pro 가 `soban-capture` 를 광고(`PersonaReceiver`), 캡처 기기가 탐색·초대(`PersonaSender`) → `.personaTransfer(manifest, senderName)` + 리소스 `persona-/depth-/side-<key>/splats-<id>` + `.personaTransferComplete(id, 목록)` → Vision Pro 가 `IncomingPackage` 로 조립 → **스튜디오 초안**(스플랫 없으면 Vision Pro 가 생성) → `.personaReceived(id)` 응답. '내 페르소나로 저장' 즉시 활성 |
| 대안 | `ShareLink` 로 PNG 공유(AirDrop → Vision Pro 사진 보관함 → 스튜디오 '사진 보관함' 으로 가져오기) |

### 5.2c 가우시안 스플랫 (`SplatCloud` / `SplatBuilder` / `SplatMesh`, 공용)

| 항목 | 구현 |
|---|---|
| 정의 | **깊이/부조 초기화형 3D 가우시안 스플랫**. 3DGS 논문의 미분 가능 최적화(학습)는 하지 않는다 — Apple 에 공개 API 가 없고 온디바이스 학습은 범위 밖. 문서·UI 에 그대로 명시 |
| 점 샘플링 | 카드의 불투명 픽셀을 격자 간격(stride = √(opaque/30k))으로 샘플. 상한 36k |
| z (깊이) | `depth.png`(8bit) → `depthNear/FarMeters` 로 미터 복원 → 얼굴 박스 중앙값 기준 상대 깊이, [−0.22, +0.14] m |
| z (부조) | 얼굴 박스로 머리 타원체(a = 0.62·faceW, b = 0.72·faceH, rz = 0.95a) + 몸통 반원기둥(0.55rz) + 어깨 감쇠. 법선 함께 |
| 측면 융합 | 측면 사진마다 `DetectFaceLandmarksRequest` → 코 중심 오프셋 → θ = ratio×0.75 rad(부호는 이미지에서 직접, Vision yaw 규약 비의존). `GeneratePersonInstanceMaskRequest` 로 마스크. 법선을 θ 회전해 측면 가시성 > 정면 가시성 + 0.15 인 스플랫만 측면 색으로 블렌드 |
| 스플랫 속성 | 색 RGB(un-premultiply), 알파(가장자리 감쇠), 반지름 = 픽셀 간격×0.9, 뒤→앞 z 정렬, 부조 그리드 48×64(오버레이 z) |
| 직렬화 | `splats.bin` "SBSP" v1, 스플랫당 20B. 3DGS PLY 내보내기(f_dc = (c−0.5)/0.2821, opacity = logit, scale = log) |
| 렌더 | RealityKit 커스텀 셰이더 부재 → 스플랫당 쿼드 + 8×8 타일 아틀라스(색×가우시안 알파, ≤1536²) + `UnlitMaterial` 알파 블렌딩, `faceCulling = .none`. `PersonaAvatar` 가 카드 대신 스플랫 메시를 몸통으로 쓰고 yaw 게인을 0.9 로 올린다 |
| 생성 위치 | 컴패니언(촬영 직후 자동) 또는 Vision Pro(사진만 받았을 때·사진 보관함 초안·저장된 페르소나 '입체 만들기'). 모임에서는 `splats-<id>.bin` 도 피어에게 전송 |

### 5.2d 파일 가져오기/내보내기 (`PersonaPackageFile` / `PersonaImporter`)

- `.sobanpersona`(UTI `com.coulson.soban.persona`, public.data): 바이너리 plist `{format, version, manifest(JSON), body, depth?, sides?, splats?}`. Info.plist 에 `UTExportedTypeDeclarations` + `CFBundleDocumentTypes`(Owner), PLY 는 `public.polygon-file-format`(Alternate). `LSSupportsOpeningDocumentsInPlace` 는 macOS 가 NO 를 거부하므로 설정하지 않는다(복사로 열림).
- 열기 경로: 스튜디오 `fileImporter`(보안 범위 URL) 또는 `onOpenURL` → `AppModel.pendingImportURL` → 초안.
- PLY: 헤더 파싱(binary LE/ascii, 속성 타입별 크기), `f_dc_*`(SH0 역변환) 또는 `red/green/blue`, `opacity`(logit→sigmoid), `scale_*`(log→exp 평균). 36k 초과 시 균등 추출. 키가 0.3~1.5 m 밖이면 0.8 m 로 정규화, 중심 원점. 카드 = 스플랫 직교 투영 소프트 디스크 렌더(800px) → `PersonaBuilder.detectRig` 로 눈·입 재검출(그림체 얼굴은 실패할 수 있어 UI 에 안내). "위아래 뒤집기" 는 원본 클라우드에서 재생성.

### 5.2e 블렌더 USDZ 에셋 (`FaceRig/`, `FaceAssets/`, `BustAvatars.swift`)

| 항목 | 구현 |
|---|---|
| 에셋 | Blender MCP 로 제작, `Docs/blender/Soban_FaceAssets.blend`(1차) → **`Soban_FaceAssets_ARKit52.blend`(2026-10-03, ARKit 52 셰이프키: 입 16·눈꺼풀 14·눈썹 5·Head jawOpen, Left=+X, 레거시 키 삭제, Blender 5.2 USD 내보내기)**. `DemoAvatar_{Ethan,Olivia,Lucas,Emma}.usdz`(각 4.8 MB), `SplatFace_Eyes_{Male,Female}`(눈알 2 + 눈꺼풀), `SplatFace_Mouth_{Male,Female}`(입술·치아·입안), `SplatPlaceholder_Bust`. 흉상 공간: y=0 가슴 절단면, 눈 y≈0.44(x=±0.032), 입 y≈0.357, 정수리 y≈0.566, 얼굴 +Z |
| 블렌드셰이프 | 눈꺼풀 `Blink_L/R, EyeWide, Squint`, 눈썹 `BrowUp`, 입/턱 `JawOpen, A, I, U, E, O, Smile, Press`. `FaceRigSystem` 이 `BlendShapeWeightsComponent` 로 매 프레임 적용 — 깜빡임(빠르게 감고 천천히 뜸, 15% 더블 블링크), 음량→턱/모음 순환, 텍스트→`HangulViseme`(중성 모음 → A/E/O/U/I, 받침 ㅁㅂㅍ → Press), 시선 미세 움직임(`_Eye_L/_Eye_R` 엔티티 회전) |
| 로딩 | `FaceAssetLoader` 가 `Entity(named:)` 로 프로토타입을 한 번만 읽고 `clone(recursive:)`. 동기화 폴더라 `Soban/FaceAssets/*.usdz` 가 자동으로 모든 플랫폼 번들에 들어간다 |
| 데모 손님 | `DemoBustAvatar`: 흉상 ×1.25, 목 높이(0.33·s) 피벗으로 yaw/pitch/roll·이동, `FaceRigComponent.audioLevel = max(level, mouth)`, TTS 시작 시 `speak(text:duration:)` → 음절당 길이 = duration/음절수. 손·글로우·이름표·반응은 `AvatarDecor` 공용. 손님은 흉상 4종까지(`GatheringSession.maxDemoGuests`), 이름 에단/올리비아/루카스/엠마, 성별별 TTS 음높이 |
| 얼굴 키트 | `PersonaAvatar.attachFaceKitIfNeeded()`: 리그 + `manifest.faceKit != "none"` 일 때(카드·스플랫 모두) 눈/입 USDZ 를 따로 로드. **6차 규칙** — `SobanFaceAssets.keepOnlyEyelids` 가 눈알 모델(`*_Eye_L/_Eye_R` 하위, 흰자·홍채·동공)을 `isEnabled = false` 로 숨기고 눈꺼풀(`*_Eyelids`, 이름에 lid/lash)만 남긴다. 눈 스케일: x = 리그 눈 간격 / 에셋 눈알 간격, y = 리그 눈 높이×1.6 / 에셋 눈꺼풀 높이(x 의 0.7–1.6배로 제한), z = 0.45·x. 위치는 **눈꺼풀 앞면**이 부조 표면 +1.5 mm 에 오도록(`lidBounds.max.z`). 입: x = 리그 입 폭 / 에셋 입 폭, z = 0.35·x, 입술 앞면 = 표면 +1 mm. 틴트는 이름이 아니라 **머티리얼 색**으로 고른다(`tintRGB`): 눈꺼풀은 밝은(피부) 머티리얼만, 입은 붉고 명도 0.45–0.8 인 입술 머티리얼만(측정값: 입술 (0.76,0.50,0.47), 잇몸 (0.53,0.35,0.33), 입 안 (0.18,0.05,0.06), 치아 (0.93,0.91,0.86)). 시선(`autoGaze`)은 눈알을 숨겼으므로 끈다. 2D 입/눈꺼풀 스프라이트는 끈다. `SOBAN_DUMP_KIT=1`(DEBUG) 로 계층·머티리얼 색을 `tmp/soban-kit-dump.txt` 에 덤프 |
| 플레이스홀더 | `PlaceholderBustAvatar`: 페르소나 미도착 참가자 자리에 반투명(0.38–0.46 호흡) 흉상 |
| 등록 | `SobanApp.init` / `SobanCompanionApp.init` 에서 `FaceRigComponent.registerComponent()`, `FaceRigSystem.registerSystem()` |

### 5.2f 흉상 템플릿 입체화 · 머리카락 볼륨 (`BustTemplate`, `SplatBuilder` 6차)

| 항목 | 구현 |
|---|---|
| 템플릿 | `BustTemplateLoader.load()`(메인 액터, 1회 캐시)가 `SplatPlaceholder_Bust.usdz` 의 `MeshResource.contents.models[].parts[]` 에서 `positions`/`triangleIndices` 를 읽어 흉상 루트 공간 삼각형으로 모으고, `@concurrent rasterize` 가 정면(+Z) 직교 z-버퍼 192×256 으로 굽는다(뒷면 삼각형 제외, 1회 구멍 메우기). 행별 실루엣 반폭·가장자리 z 를 7행 박스 평활로 저장(`edge(atY:)` 행 보간) — 행 양자화 띠 방지 |
| 매핑 | 리그 눈 중심 ↔ 흉상 (0, 0.44), k = 0.064 / 리그 눈 간격(흉상 단위/m). `templateZ = (template.z(bustXY) − 뺨 기준 z) / k`, 뺨 기준 = (±0.045, 0.40) 평균 → 뺨 z≈0, 코끝만 살짝 +. 실루엣 밖(넓은 어깨·머리끝·정수리 위)은 `edge.z − 밖으로 나간 거리×0.8`. 우선순위: TrueDepth 깊이 → 템플릿 → 해석적 부조 |
| 법선 | 템플릿 z 의 1 cm 유한차분. 측면 융합·경사 보정에 사용 |
| 머리카락 | `isHair`: 목선 위 & (눈썹 윗선+5% 위 **또는** 윤곽 폭 92% 밖) & 색이 피부보다 머리카락색에 가깝거나 피부와 0.22 이상 다름. 돔 `hairDepth(=얼굴폭×0.14) × √(1−ex²) × 수직계수(0.25–1)` 를 z 에 더하고(깊이 맵 없을 때), 분류된 점을 한 겹 더 복제(지터 ±1셀, 앞으로 0.25–0.7·hairDepth, 명도 0.88–1.1, α×0.7, 크기×0.85) — `maxCount` 36k 안에서 |
| 경사 보정 | 스플랫 크기 × min(3.2, 1/max(0.3, n.z)) — 옆을 보는 표면에서 격자 샘플이 z 로 늘어나 생기는 줄무늬 틈을 메움 |
| 리그 확장 | `FaceRig.leftBrow/rightBrow`(Vision `leftEyebrow/rightEyebrow`), `contour`(`faceContour` 정규화 다각형), `hair`(이마 위 평균색). 모두 옵셔널(구 패키지 디코딩 호환). `PlaceholderPersona` 샘플도 같은 값을 채운다 |
| 호출 | `SplatBuilder.build(from:template:progress:)`. Studio(초안/활성)·AppModel 런치 플래그·Companion 모두 `await BustTemplateLoader.load()` 결과를 넘긴다 → 세 플랫폼 결과가 같다 |
| 왜 VLM 이 아닌가 | FoundationModels 는 이미지 입력을 받아도 픽셀 좌표를 안정적으로 내지 못한다. Vision 76점 랜드마크·인물 분리가 같은 온디바이스 ML 로 밀리초에 좌표를 준다. 의미 수준 판단(헤어스타일 등)이 필요해지면 VLM 을 보조로 붙일 수 있다(§9) |

### 5.2g 템플릿 → 사진 변형 (`TemplateFit`, `ThinPlateSpline`) · 외형 힌트 (`AppearanceHints`) — 7차

| 항목 | 구현 |
|---|---|
| TPS | `ThinPlateSpline(source:target:lambda:)`: 커널 r² log r², (n+3)² 시스템을 부분 피벗 가우스 소거로 풀고 λ=0.002 정규화. `map(p)` = 아핀 + Σ wᵢ U(‖p−sᵢ‖). 사진 좌표(카드 m) → 흉상 좌표 |
| 대응점 | 눈 중심 2(±0.032, 0.44) · 눈썹 중심 2(±0.032, 0.462) · 코끝(0, `template.noseY`: x=0 에서 0.37–0.43 사이 z 최대 행) · 입 중심(0, 0.357) + 양끝(±0.025) · 얼굴 윤곽 ~12점(높이 비율 t = (눈y−y)/(눈y−턱y) → 흉상 by = 0.44 − t·(0.44 − `template.chinY`), bx = ±실루엣 반폭×(0.9+0.08t)). `chinY` 는 목(최소 반폭) 위에서 반폭이 1.25배 되는 첫 행 |
| 행 맞춤 | `TemplateFit.rowFit`: 카드 160행마다 불투명 픽셀 범위 → (중심, 반폭). bx = u·흉상반폭·ratio, ratio = clamp(사진반폭·k / 흉상반폭, 0.6…1.6). by 는 눈 간격 아핀 |
| 블렌딩 | 얼굴 박스 타원(1.1배) 정규화 거리 d: d≤1 TPS, d≥1.4 행 맞춤, 사이 smoothstep |
| 우선순위 | 깊이 맵 → `templateZ(fit.map)` → 실루엣 밖 가장자리 기울임 → 해석적 부조 |
| 외형 힌트 | `AppearanceAnalyzer.analyze(image:rig:)`: `SystemLanguageModel.default.availability == .available` 이고 OS 27 이면 `LanguageModelSession.respond(generating: AppearanceReport.self) { 텍스트; Attachment(cgImage 512px) }`(8초 타임아웃, 실패 시 nil) → 아니면 `heuristic` (턱 아래 양옆 머리카락색 → long, 턱 옆 → medium; 이마 중앙 머리카락색 → 앞머리; 머리 위 폭/얼굴 폭 → 볼륨; 하단 폭/얼굴 폭 1.6 → 어깨). `hairDepthScale` 0.7/1/1.4, `hairReachBelowNeck` 0.04/0.14/0.38(카드 높이 비율), 앞머리면 이마 중앙 60% 폭은 눈썹선 아래 10% 까지 머리카락 허용. `PersonaManifest.appearance` 에 저장 |
| 왜 좌표는 안 맡기나 | 언어 모델은 픽셀 좌표를 안정적으로 내지 못한다(실측: 만화 샘플에 "어깨 안 보임" 같은 오판도 있음). 좌표·윤곽은 Vision 76점, 모델은 분류 힌트만 |

### 5.2h ARKit 52 표정 표준 · 네이티브 스플랫 · 턱 변형 — 8차

| 항목 | 구현 |
|---|---|
| `ArkitShape` / `ArkitWeights` | ARKit `BlendShapeLocation` 과 같은 52개 rawValue. `ArkitWeights` 는 `[Float]` 52개 값 타입(Codable·Hashable) — 컴포넌트·네트워크 그대로 사용. `ArkitWeights(named:)` 로 ARFaceAnchor/MediaPipe 사전에서 생성 |
| 비셈 프리셋 | A = jawOpen .6 + mouthLowerDownL/R .3 · I = jawOpen .15 + mouthStretchL/R .5 + mouthSmileL/R .2 · U = mouthPucker .8 + mouthFunnel .3 + jawOpen .1 · E = jawOpen .3 + mouthStretchL/R .4 · O = jawOpen .35 + mouthFunnel .7 + mouthPucker .3 · press = mouthPressL/R .8 + mouthClose .6 |
| `ShapeNameAdapter` | 메시 셰이프키 이름에 `jawOpen`/`eyeBlinkLeft`/`mouthSmileLeft` 가 있으면 ARKit 에셋 → `arkit.named` 직통. 아니면 레거시 13개로 축약(좌우 분리 셰이프는 max): Blink_L/R, EyeWide, Squint, BrowUp, Smile, Press. 비셈 합성 경로는 레거시 A/I/U/E/O/Press 셰이프를 직접 쓰고 JawOpen 은 ARKit 의 40%만; 외부 ARKit 신호만 있을 때는 U=pucker, O=funnel·(1−pucker), I=stretch·(1−jaw), A=lowerDown·jaw 로 근사 |
| `FaceRigSystem` 8차 | ① `externalWeights` 있으면 합성 생략(깜빡임은 `externalIncludesBlink` 일 때만 끔) ② RMS → `open` 은 엔벨로프: 큐 비셈 amount = sin(πt)·max(.5, .5+open)·.95 ③ 코아티큘레이션: 첫 50 ms 직전 비셈과 크로스페이드, 마지막 40 ms 다음 비셈 50% 선행 ④ `HangulViseme` 초성 ㅁ(6)·ㅂ(7)·ㅃ(8)·ㅍ(17) → `.press` 70 ms 선행 ⑤ 스무딩 후 어댑터 → `BlendShapeWeightsComponent`. `lastNamingDescription` 으로 UI 에 "ARKit 52 직통 / 레거시 → 어댑터" 표시 |
| 외부 신호 소스 | `FaceMouthTracker.weights`(iOS ARKit 52 전체) · `CameraCaptureController.faceWeights`(Vision 76점: jawOpen=입술 높이, eyeBlink=눈 높이/폭 .32→.14, mouthSmile=입꼬리 들림, mouthPucker=입폭/얼굴폭 <.34, mouthStretch >.46, browInnerUp=눈썹–눈 간격) → `PersonaPreviewView.expressionSource` → `TableAvatar.setExpression(_:includesBlink:)` → `rig.externalWeights` |
| 네이티브 스플랫 (`SplatMesh.makeNative`) | `LowLevelBuffer(descriptor: .init(capacity:sizeMultiple:16))` 에 스플랫당 14 float 인터리브: pos3 · scale3(σ=0.7·scale, z 0.3배 원반) · rot4(1,0,0,0) · opacity(a/255) · SH0 3((rgb−0.5)/0.2821). `BufferDescriptor(buffer:format:stride:offset:)` 5개 → `BufferResource(count:…sphericalHarmonics:(sh,.zero))` → `GaussianSplatResource`(activation identity) → `GaussianSplatComponent`. 실패(상한·GPU)·시뮬레이터(`#if !targetEnvironment(simulator)`, SDK 에 심볼 없음)·`quadsplats` → 쿼드 아틀라스 |
| `SplatJawDeformer` | 리그에서 윗입술(입 중심+입높이·0.2) ~ 턱(얼굴 박스 아래) 사이, 폭 95% 안, z>−8 cm 인 스플랫을 골라 가중치 smoothstep(t)·(1−측면²). jawOpen v → 축 (입x, 눈y−(눈y−입y)·.25, −0.06) 둘레로 −v·0.22 rad 회전, `buffer.withUnsafeMutableBytes` 로 위치만 재기록(변화 0.008 이상일 때). 키트 `rig.audioLevel`/`externalWeights.jawOpen` 과 같은 값 |
| 입 안 컬링 | `SplatBuilder`: faceKit 사용 시 입 중심 타원(반폭 = 입폭/1.24·.42, 반높이 = 입높이·.22) 안 d<0.6 제거, 0.6–1 알파 페더 |

### 5.3 아바타 렌더링 (`PersonaAvatar`)

- 카드 크기: 높이 `cardHeightMeters`(기본 0.8 m) × 이미지 비율.
- 피벗 = 얼굴 중심(`faceBox.mid`). 카드 자식들을 `-pivot` 만큼 옮기고 카드 엔티티를 `+pivot` 에 두어 회전축을 얼굴에 맞춘다.
- 재질: `UnlitMaterial` + `.transparent(opacity: 1)`, 텍스처는 `TextureResource(image:options:)`.
- 레이어 z 오프셋: 그림자 −10 mm, 몸통 0, 입 +4 mm, 눈꺼풀 +5 mm.
- 이름표/반응: `ViewAttachmentComponent(rootView:)` (visionOS 26+). 상태는 `@Observable AvatarLabelState`.
- 루트는 `TableRenderer` 가 매 틱 뷰어(내 머리) 방향으로 yaw 빌보딩.

### 5.4 센싱 (`HeadHandTracker`)

- `ARKitSession.run([WorldTrackingProvider, HandTrackingProvider])` — 이머시브 공간이 열려 있을 때만 데이터가 온다. 시뮬레이터에서 `run` 이 오래 걸릴 수 있어 `immersiveOpened()` 는 await 하지 않고 별도 Task 로 시작한다.
- 머리: `queryDeviceAnchor(atTimestamp: CACurrentMediaTime())`. forward = −column2 → `yaw = atan2(−f.x, −f.z)`, `pitch = asin(f.y)`, `roll = asin(right.y)`. 첫 유효 자세에서 자동 캘리브레이션, "정면 다시 맞추기" 버튼으로 재설정.
- 손: `anchorUpdates` 에서 `wrist` 조인트 → 머리 역변환으로 머리 기준 좌표. 손목 y > +8 cm → `handRaised`.
- 권한: `NSHandsTrackingUsageDescription`. 월드 센싱은 필요 없음(디바이스 앵커는 권한 불요).

### 5.5 음성 (`VoiceEngine`)

- `AVAudioSession` `.playAndRecord` / `.voiceChat`.
- 캡처: `installAudioTap(onBus:bufferSize:format:tapProvider:)` (visionOS 27 신규, `AVReadOnlyAudioPCMBuffer` Sendable). 오디오 스레드에서 RMS + 선형 보간 다운샘플 → 16 kHz Int16 → 960 프레임(60 ms) 청크를 `CaptureSink`(락) 에 쌓고, 메인 틱이 `drainCapture()` 로 가져간다. `Task` 생성 없음.
- 재생: 참가자별 `AVAudioPlayerNode`(mono 16k) → `AVAudioEnvironmentNode`(HRTFHQ) → mainMixer. `connectNode(_:to:format:)`, `playAudio(at:)` 등 27 비-deprecated API 사용. 소스 위치 = 슬롯의 페르소나 위치, 리스너 = 내 머리.
- 수신 청크 RMS 는 해당 참가자의 `level` 로도 쓰여 입 모양이 음성과 일치한다.

### 5.4b 입 모양 신호 (`MouthSourceKind`)

| 플랫폼 | 1순위 | 2순위 | 3순위 |
|---|---|---|---|
| Vision Pro | — (내부 카메라/LiDAR 접근 불가, UI 에 명시) | — | 마이크 RMS (`VoiceEngine`) |
| iPhone · iPad | `FaceMouthTracker`: ARKit `ARFaceTrackingConfiguration` `jawOpen`×1.6 + `mouthFunnel`×0.4 | `CameraCaptureController.mouthTrackingMode`: `VNDetectFaceLandmarksRequest` innerLips 높이/얼굴 높이 → (ratio−0.02)/0.07 | `MicLevelMeter` |
| Mac | — | 카메라 입술 랜드마크 | `MicLevelMeter` |

- 얼굴 추적은 전면 카메라를 독점하므로 캡처 세션을 멈춘 뒤 켠다. `MicLevelMeter` 는 레벨만 재는 공용 클래스(iOS 27+/visionOS 27+/macOS 27+ 는 `installAudioTap`, 그 아래는 `installTap`).
- 스튜디오/캡처의 미리보기는 `VoiceLevelBar`(24 세그먼트 + 피크 홀드)와 권한 상태(`AVAudioApplication.shared.recordPermission`), "마이크 허용 요청" 버튼을 보여 준다.

**마이크 입력 구성 순서(실기기 버그)**: 엔진이 출력 전용으로 먼저 시작된 뒤 `inputNode` 에 처음 접근하면 하드웨어 포맷이 0 Hz/0 ch 로 나온다("사용 가능한 마이크 입력이 없습니다"). `startEngine(withInput:)` 이 권한이 있을 때 **시작 전에** `inputNode.outputFormat` 을 읽어 I/O 유닛에 입력을 포함시키고, 이미 돌고 있으면 `restartEngine(withInput: true)` 로 재시작한다. `requestMicrophoneAccess()` 는 시스템 권한 프롬프트 → 입력 포함 재시작 → 탭 설치까지 수행하며, `inputStatusText` 로 포맷/라우트를 보여 준다.

### 5.5b 데모 손님 목소리 (`BotSpeech`)

- `AVSpeechSynthesisVoice(language: "ko-KR")` + 손님별 `pitchMultiplier`(0.82–1.22). `AVSpeechSynthesizer.write(_:toBufferCallback:)` 로 PCM 버퍼를 모은다(길이 0 버퍼 = 끝, 12초 타임아웃). Float32 모노가 아니면 `AVAudioConverter` 로 변환(환경 노드는 모노만 공간화).
- 50 ms 창 RMS 엔벨로프를 만들어 `BotBrain.beginTurn(envelope:)` 에 넘긴다. 틱에서 `envelope[(now − turnStart)/hop]` 이 입 벌림이 되어 **들리는 소리와 입이 맞는다**.
- 버퍼는 `VoiceEngine.enqueue(_:buffers:position:)` 로 해당 좌석 위치의 플레이어에 한 번에 스케줄. 플레이어 포맷이 다르면 재연결.
- 자리 카드에 방금 한 말을 자막으로 보여 준다(`Participant.caption`). 시뮬레이터(오디오 OFF)에서는 TTS 를 건너뛰고 합성 엔벨로프를 쓴다.

### 5.5c 내 모습 보기 (거울)

`TableRenderer.sync(_:selfParticipant:…)` 가 내 페르소나를 `TableLayout.mirrorPosition` (내 자리에서 오른쪽 35°, 반지름 0.8 m, 높이 +0.45 m, 0.6 배) 에 그린다. 포즈는 yaw/roll/offset.x/손 x 를 반전해 거울처럼 움직이고, 이름표에 "· 거울" 이 붙는다. 토글 `showSelfMirror` (기본 켜짐).

### 5.6 세션 (`GatheringSession`)

- 모드: `idle → solo | hosting | browsing → joined`. `isHost = solo || hosting`.
- 좌석표: 호스트가 `roster([SeatAssignment], hostID)` 를 reliable 로 보낸다. 새 참가자는 빈 좌석 중 가장 낮은 번호.
- 연결 시 양쪽이 `hello(ParticipantInfo, PersonaManifest?)` + `sendResource(persona-<id>.png)` 를 보낸다. PNG 가 매니페스트보다 먼저 와도 `receivedPNG[personaID]` 에 보관했다가 결합한다.
- 틱(33 ms): 트래커 poll → 내 포즈/레벨 → (피어 있으면) 포즈 15 Hz + 음성 청크 전송 → 데모 손님 갱신 → 원격 감쇠/3 s 타임아웃 → 리스너 갱신 → `renderer.sync`.
- 호스트 이탈 시 모두 `idle`. 참가자 이탈 시 호스트가 roster 재전송.

### 5.7 메시지 포맷

`SessionMessage` 를 `PropertyListEncoder(.binary)` 로 인코딩. `Data` 가 그대로 들어가 JSON+base64 보다 ~30% 작다. 포즈 패킷 ≈ 60–120 바이트, 음성 청크 = 1920 바이트 + 헤더.

### 5.7b 이머시브 수명 주기

- `AppModel.openTable(_:)` / `closeTable(_:)` 가 유일한 진입점. `immersiveState` 는 `TableImmersiveView` 의 `onAppear/onDisappear` 로만 `.open/.closed` 가 되므로 Digital Crown 으로 닫아도 창의 "소반 펼치기" 가 살아난다. 열기 실패(`.userCancelled/.error`)는 `openError` 로 표시.
- `immersiveClosed()` 는 트래커 stop(분리 Task), 마이크 캡처 중지, 원격 오디오 소스 제거, 틱 중지. 다시 열면 `HeadHandTracker.start()` 가 새 `ARKitSession` 을 만든다.

### 5.8 Info.plist / 빌드 설정

| 키 | 값 |
|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.coulson.Soban` |
| `CFBundleDisplayName` | 소반 |
| `SUPPORTED_PLATFORMS` / `TARGETED_DEVICE_FAMILY` | `xros xrsimulator iphoneos iphonesimulator macosx` / `1,2,7` |
| 배포 타깃 | visionOS 27.0 · iOS 26.0 · macOS 26.0 |
| `NSCameraUsageDescription`, `NSPhotoLibraryAddUsageDescription` | 소반 캡처(iOS/macOS) |
| macOS 샌드박스 | 카메라·오디오 입력·네트워크(클라이언트/서버) 허용 |
| `UIApplicationSceneManifest_Generation` | YES |
| `NSMicrophoneUsageDescription`, `NSLocalNetworkUsageDescription`, `NSHandsTrackingUsageDescription` | 한국어 설명 |
| `NSBonjourServices` | `_soban-table._tcp/_udp`, `_soban-capture._tcp/_udp` |
| 서명 | 자동, 팀 5Z8G42AVKD, 엔타이틀먼트 없음 |

## 6. 성능 예산

| 항목 | 예산 | 비고 |
|---|---|---|
| 페르소나 빌드 | < 4 s (실기기) | 1024px, Vision 3 요청 + CPU 스캔 |
| 틱 | 30 Hz, < 3 ms/틱 | 아바타 ≤ 5, 엔티티 ≤ 60 |
| 네트워크 | 포즈 15 Hz × 5 피어 ≈ 9 KB/s, 음성 32 KB/s 송신 | LAN 전제 |
| 메모리 | 페르소나 PNG ≤ 2 MB × 6 | 캐시된 CGImage 포함 ≤ 40 MB |

## 7. 보안·프라이버시

- 사진·페르소나는 기기 Documents 에만 저장. 서버 없음.
- MC 세션은 `encryptionPreference: .required`.
- 네트워크로 나가는 것은 매니페스트·PNG·포즈·음성·반응뿐. 원본 사진은 나가지 않는다.
- 마이크는 사용자가 끌 수 있고(토글), 끄면 입 모양도 전송되지 않는다.

## 8. 검증 전략

- **시뮬레이터**: `simctl launch <udid> com.coulson.Soban sample demo guests=4 hidewindow distance=2.1` → 두레반 + 데모 손님 + 거울 아바타 렌더, 반응 이모지, 이름표, 자막 확인(2026-10-02 2차 완료, 스크린샷 `Docs/screenshots/`). 주의: Xcode 활성 대상이 실기기로 바뀌면 `BuildProject` 는 `Debug-xros` 를 만들므로 시뮬레이터 검증은 `xcodebuild -destination 'platform=visionOS Simulator,id=…' -derivedDataPath /tmp/soban-dd` 로 따로 빌드한다.
- **Mac 소반 캡처**: `xcodebuild -destination 'platform=macOS'` 후 실행 → FaceTime 카메라로 얼굴 링·yaw/pitch·각도 자동 촬영 확인(2026-10-02 완료, 사용자가 실제로 정면·측면 촬영).
- **iOS 소반 캡처**: iOS 시뮬레이터 빌드 통과. 실기기(iPhone 깊이 카메라) 촬영·전송은 미검증.
- **실기기 1대**: 스튜디오에서 실제 사진으로 페르소나 생성, 머리/손 추적 상태 문구, 마이크 레벨미터, 데모 손님과 공간 음향 없는 루프.
- **실기기 2대+**: 같은 Wi‑Fi, 한쪽 "모임 열기" → 다른 쪽 "모임 참여 → 앉기". 로컬 네트워크 권한 프롬프트 수락. 상대 페르소나 수신(PNG 1–2 MB), 고개/손/입/음성 확인.

## 8b. 실기기 1차 피드백과 조치 (2026-10-02)

| # | 보고 | 원인 | 조치 |
|---|---|---|---|
| 1 | 미리보기 볼륨이 사진 보관함 시트를 가림 | 2D 창 RealityView 콘텐츠가 유리면 앞으로 돌출 | z −5 cm, 피커/시트 중 숨김 |
| 2 | 마이크 입력은 보이는데 입이 안 움직임 | `.task(id:)` 가 시작 시 `level` 값만 캡처 | `levelSource` 클로저 + `StudioModel` |
| 3 | 이름 수정 반영 버튼 없음 | 라벨은 생성 시 1회만 설정 | 타이핑 즉시 반영 + 이름 적용 버튼 |
| 4 | 데모 손님 목소리 없음 | 봇에 오디오 없음 | TTS 공간 재생 + 엔벨로프 립싱크 + 자막 |
| 5 | 내 모습 3인칭 확인 불가 | 로컬은 렌더 제외 | 거울 아바타 토글 |
| 6 | Vision Pro 벗고 촬영 / iPhone·iPad·Mac 분기 | visionOS 카메라 접근 불가 | 능력 판별 + 소반 캡처(깊이/일반) + 전송 |
| 7 | 상 접기 후 재펼침 불가 | ARKit 세션 재사용 불가 + 상태 비동기화 | 세션 재생성, 뷰 생명주기 상태, 실패 사유 표시 |

## 8c. 3차 개선 (2026-10-02)

| # | 요청 | 조치 |
|---|---|---|
| 1 | 컴패니언: 다각도 촬영 → 가우시안 스플랫 → Vision Pro 전송/감상 | §5.2c. 촬영 직후 자동 생성, 카드/입체 토글 + 턴테이블 미리보기, 3DGS PLY `ShareLink`, "스플랫 포함 보내기"/"사진만 보내기" |
| 2 | Vision Pro: 스플랫 수신 또는 사진만 받아 직접 생성 → 초안 → 저장 즉시 사용 | 다중 리소스 조립, 초안 모델(`StudioModel.setDraft`), 스플랫 미존재 시 자동 생성, 저장 → `activeID` + `refreshLocalPersona()` |
| 3 | 입 모양: 레벨미터, 내부 센서 가능 시 사용·불가 시 마이크 + 권한, 컴패니언에도 | §5.4b. Vision Pro 는 불가 사유 표시 후 마이크, iPhone/iPad TrueDepth, Mac 입술 랜드마크, `VoiceLevelBar`, 권한 상태·허용 버튼 |

## 8d. 5차 — 블렌더 에셋 교체 (2026-10-02)

사용자가 Blender MCP 로 만든 USDZ 9종과 `FaceRig.swift`/`SobanFaceAssets.swift` 를 전달 → §5.2e 로 통합. 2D 만화 데모 손님 → USDZ 흉상 4명, 스플랫 페르소나의 2D 입/눈꺼풀 → USDZ 얼굴 키트, 미도착 자리 → 플레이스홀더 흉상. 프로젝트 이동(`Desktop/Soban`) 후 남아 있던 `INFOPLIST_FILE = MyApp/Info.plist` 도 `Soban/Info.plist` 로 고쳐 빌드를 복구했다. 시뮬레이터 검증: 흉상 4명 + 이름표 + 반응, 거울/스튜디오의 얼굴 키트 정렬.

## 8e. 6차 — 키트 일체감 · 흉상 템플릿 · 컴패니언 미리보기 (2026-10-02)

실기기 사진 4장: 실제 사진 스플랫 위에 USDZ 눈알(흰자·홍채)과 입술이 얼굴 앞으로 떠 있었고, iPhone 미리보기는 엔티티가 작고 여백이 컸다. 조치: §5.2e 얼굴 키트 규칙(눈꺼풀만·납작·앞면 기준 z·색 기반 틴트·카드에도 부착), §5.2f 흉상 템플릿 + 머리카락 볼륨 + 경사 보정, `PersonaPreviewView` 의 iOS/macOS 전용 `PerspectiveCamera`(FOV 36°, 카드 높이×1.12 가 보이는 거리, 아바타 실제 크기). 시뮬레이터 검증: 샘플 입체에서 눈알 사라짐·눈꺼풀 깜빡임 프레임 포착(연속 24장 시트)·입술 틴트, Mac 소반 캡처(`sample` DEBUG 인자) 미리보기가 프레임을 채움, 두레반 흉상 손님·거울 정상. 4개 빌드(visionOS 기기/시뮬, iOS 시뮬, macOS) 통과. 남은 확인: 실제 사진 스플랫에서 눈꺼풀 세로 스케일·입술 폭이 자연스러운지(실기기).

## 8f. 7차 — 템플릿 변형 · 외형 힌트 · 흉상 샘플 · 상태 유지 (2026-10-02)

사용자 질문("온디바이스 파운데이션 모델만으로는 사진을 늘이고 줄여 얼굴 모양 투명 엔티티에 맞추는 게 무리인가?")에 대한 답: 좌표/변형은 언어 모델의 일이 아니라 결정적 기하라서 §5.2g 로 구현했다. 변경: `TemplateFit`/`ThinPlateSpline`(새 파일), `SplatBuilder.build(from:template:hints:)`, `AppearanceHints`/`AppearanceAnalyzer`(FoundationModels + 휴리스틱), 부조 96×128, `PersonaManifest.demoAvatar/appearance`, `PlaceholderPersona.makeDemoBust/randomDemoBust`, `PreviewHolder`·`TableRenderer`(거울 포함)가 `DemoBustAvatar` 로 흉상 샘플 렌더, 데모 손님은 내 흉상과 겹치지 않게 선택, 스튜디오 2단계는 흉상이면 건너뜀. 상태 유지: `AppModel.studio`(StudioModel 을 앱이 소유) + `CompanionModel`(앱이 소유, `@Bindable` 로 뷰에 주입) — Combine `PassthroughSubject.debounce.sink` 로 UserDefaults/`.sobanpersona` 저장·복원. 첫 실행에서 백그라운드 스플랫 생성이 끝나도 스튜디오가 카드로 남던 레이스(`activeSplats` 가 id 로만 갱신) → `splatCount` 도 키에 포함. 검증: 시뮬레이터(흉상 샘플 스튜디오·거울·상, TPS 턴테이블), Mac(Apple Intelligence 힌트 실제 응답, 재실행 복원), 4개 빌드 통과. 프로젝트 가이드라인은 Combine 대신 async/await 를 권하지만 사용자가 명시적으로 Combine 적용을 요청해 저장 파이프라인에 한정해 썼다.

## 8g. 8차 — 조사 문서의 단기 로드맵 구현 (2026-10-02)

사용자가 전달한 조사 문서(LAM·RealityKit 27 스플랫·ARKit 52·립싱크·MediaPipe·SpeechAnalyzer)에서 **로컬에서 바로 되는 것**을 골랐다: §5.2h. 블렌더 USDZ 는 그대로 필수(ARKit 52 재내보내기는 `Docs/blender/ARKit52-요청.md` 로 요청). 검증: 시뮬레이터(쿼드 폴백) 두레반에서 흉상 4명 비셈 변화·깜빡임 정상, macOS 27 에서 네이티브 `GaussianSplatComponent` 렌더(아래 캡처), 4개 빌드 통과. 발견: xrsimulator/iphonesimulator 27.0 SDK 의 RealityFoundation 에는 `GaussianSplatResource` 가 없다(기기·macOS SDK 에만) → 시뮬레이터는 쿼드. 보류: MediaPipe(외부 의존), LAM/Audio2Face(CUDA), SpeechAnalyzer(visionOS 가용성 미확인), SharePlay 가중치 스트림(Vision Pro 표정 소스 없음).

## 8h. 9차 — 실기기 피드백 4건 (2026-10-03)

1. 홈 카드 ≠ 스튜디오: 홈은 `body.png` 썸네일, 스튜디오는 3D 미리보기였다 → 홈도 `PersonaPreviewView`(`previewScale` 0.26) 로 같은 흉상/스플랫/키트를 보여 준다.
2. 스튜디오 레벨미터 0: `VoiceEngine.level` 은 `GatheringSession.tick()`(상이 펼쳐졌을 때만 30Hz)에서만 갱신됐다 → 캡처 중에는 엔진이 자체 `levelTask` 로 갱신, 틱은 청크만 가져간다(`drainCapture`).
3. 입 모양 예시 TTS: `StudioView.runFakeTalk` 가 `BotSpeech.render` 로 문장을 렌더해 정면(0,1.2,−0.7)에서 재생하고 엔벨로프로 레벨, `StudioModel.speechRequest` → `PersonaPreviewView.speech` → `TableAvatar.speak` 로 비셈 큐. 오디오 없으면 사인파 + 비셈.
4. 상에서 마이크 불능·토글 무반응(추정 원인: 이머시브 진입 시 오디오 라우트/구성 변경으로 엔진이 조용히 멈추고 플래그만 남음; 또는 TTS 가 출력 전용으로 먼저 켠 엔진을 입력 포함으로 재시작하다 실패): 권한이 있으면 엔진을 **항상 입력 포함**으로 시작, `AVAudioEngineConfigurationChange`/인터럽션 종료 시 엔진·탭 재구성, `startCapture` 가 `engine.isRunning` 실제값으로 플래그를 바로잡음, 모임 설정에 레벨미터·`statusText`·"마이크 허용 요청 · 다시 연결" 버튼. 실기기 확인 필요(T-1205).

## 9. 알려진 한계와 다음 단계

1. 스플랫은 초기화만 하고 학습하지 않는다 → 측면 융합 경계가 거칠 수 있다. v2: Metal 컴퓨트로 소규모 색/불투명도 최적화, 또는 `ImagePresentationComponent.Spatial3DImage`(실기기 전용) 결과를 보조로.
2. 입 모양은 크기만 반영 → v2: `SpeechAnalyzer` 음소 기반 viseme.
3. MultipeerConnectivity deprecated → v2: `NetworkTransport` (Bonjour `_soban-table._tcp`, 호스트 스타 토폴로지 + 릴레이).
4. 좌표계 공유 없음(각자 자기 방에 테이블) → 같은 물리 공간에서 만날 때는 `SharedCoordinateSpaceProvider` 로 한 테이블을 공유하는 옵션.
5. 유료 팀 전환 시 `GroupActivities` 전송 어댑터 추가(원격 FaceTime 참여).
