# 소반 (Soban) — Tasks

상태: ✅ 완료 · 🔄 진행 · ⏳ 대기 · 🧪 실기기 검증 필요

## M0 · 프로젝트 셋업
| ID | 작업 | 상태 |
|---|---|---|
| T-001 | visionOS 전용 타깃 (xros/xrsimulator, family 7), 번들 `com.coulson.Soban`, 표시 이름 소반 | ✅ |
| T-002 | Info.plist: 마이크·로컬 네트워크·손 추적 설명, Bonjour 서비스, SceneManifest | ✅ |
| T-003 | 빌드 경고 0 (MC deprecated 경고는 `MultipeerTransport.swift` 에만 격리) | ✅ |
| T-004 | LICENSE(Apache-2.0), NOTICE, .gitignore, README, Docs | ✅ |
| T-005 | `git init -b main` (커밋/푸시는 GitHub Desktop 에서) | ✅ |

## M1 · 페르소나 캡처
| ID | 작업 | 상태 |
|---|---|---|
| T-101 | `PersonaManifest`/`FaceRig`/`PersonaPackage` 모델 | ✅ |
| T-102 | `PersonaBuilder`: 썸네일 → 인물 마스크 → 얼굴 랜드마크 → 크롭 → 색 샘플 → PNG | ✅ |
| T-103 | `PersonaStore` 저장/로드/활성/삭제/캐시 | ✅ |
| T-104 | `PlaceholderPersona` 샘플 5종 (시뮬레이터·데모 손님) | ✅ |
| T-105 | 스튜디오 UI 4단계 + 라이브러리 + 진행률/오류 | ✅ |
| T-106 | 실제 사진으로 리그 정확도 확인 (눈·입 박스가 얼굴에 맞는지) | 🧪 |
| T-107 | 여러 사진(정면/좌/우) 합성 또는 Spatial3DImage 입체화 옵션 | ⏳ v2 |
| T-108 | 미리보기 볼륨이 시트를 가리는 문제: z −5cm + 피커/시트 중 숨김 | ✅ |
| T-109 | 미리보기 입 모양이 마이크 레벨을 못 받던 버그(`levelSource` 클로저) | ✅ |
| T-110 | 이름 즉시 반영 + '이름 적용' 버튼(초안/현재 페르소나) | ✅ |
| T-111 | `CaptureAvailability` 런타임 판별 + visionOS 안내 시트(`CaptureOptionsSheet`) | ✅ |
| T-112 | `PersonaReceiver` '기기에서 받기' (soban-capture 광고 → 저장·활성화) | ✅ |
| T-113 | 깊이 맵 기반 마스크 보정(`DepthRefiner`) + `depth.png`/`side-*.png` 저장 | ✅ |
| T-114 | 실기기: 사진 보관함 시트가 더 이상 가려지지 않는지, 입 모양 반응 확인 | 🧪 |

## M2 · 살아 움직이기
| ID | 작업 | 상태 |
|---|---|---|
| T-201 | `PersonaAvatar` 레이어(카드·그림자·입·눈꺼풀·손·글로우) | ✅ |
| T-202 | 이름표·반응 말풍선 `ViewAttachmentComponent` | ✅ |
| T-203 | `HeadHandTracker`: 디바이스 앵커 → yaw/pitch/roll/offset, 손목 상대 좌표, 캘리브레이션 | ✅ |
| T-204 | `VoiceEngine` 캡처 탭(신규 `installAudioTap`) + RMS + 16k 다운샘플 | ✅ |
| T-205 | 스튜디오 미리보기(`PersonaPreviewView`) 마이크/시뮬레이션 | ✅ |
| T-206 | 실기기: 고개 방향 부호, 손 좌우 매핑, 입 임계값 튜닝 | 🧪 |
| T-207 | 음소 기반 입 모양(SpeechAnalyzer) | ⏳ v2 |
| T-208 | `HeadHandTracker` 세션/프로바이더 재생성(stop 후 재사용 불가), poll/calibrate 재귀 수정 | ✅ |
| T-209 | 내 모습 보기(거울) 아바타 — 좌우 반전 포즈, 토글 | ✅ |

## M3 · 두레반 공간
| ID | 작업 | 상태 |
|---|---|---|
| T-301 | `TableLayout` 6석 링 + 슬롯 회전 | ✅ |
| T-302 | `TableScene` 두레반·방석·찻잔·다관·다과·바닥 광원 | ✅ |
| T-303 | `TableRenderer` 아바타 동기화 + 빌보딩 | ✅ |
| T-304 | 이머시브(.mixed) 공간, 테이블 거리 슬라이더, 정면 다시 맞추기 | ✅ |
| T-305 | 실기기: 바닥 높이/거리 체감, 카드 크기 0.8 m 적정성 | 🧪 |
| T-306 | 교자상(직사각) 변형, 계절 테마 | ⏳ |
| T-307 | 이머시브 상태를 뷰 생명주기로 동기화, 열기 실패 사유 표시(상 접기→펼치기 버그) | ✅ |
| T-308 | 실기기: 상 접기 → 소반 펼치기 반복 3회, Digital Crown 으로 닫은 뒤 버튼 복구 확인 | 🧪 |

## M4 · 다중 사용자
| ID | 작업 | 상태 |
|---|---|---|
| T-401 | `SessionMessage` binary plist, `SessionTransport`/`PeerHandle` 추상화 | ✅ |
| T-402 | `MultipeerTransport` 호스트/브라우즈/초대/리소스 전송 | ✅ |
| T-403 | `GatheringSession` 좌석표(호스트 권위), hello/PNG 교환, 포즈 15Hz, 반응, 이탈 처리 | ✅ |
| T-404 | 음성 60ms 청크 송수신 + `AVAudioEnvironmentNode` 공간 재생 | ✅ |
| T-405 | 데모 손님 `BotBrain` 턴 교대·반응·손들기 | ✅ |
| T-406 | 실기기 2대: 발견·연결·PNG 수신·포즈·음성 지연 측정 | 🧪 |
| T-407 | `NetworkTransport` (Network.framework, TN3213) 로 교체 | ⏳ v2 |
| T-408 | 유료 팀 전환 시 GroupActivities 어댑터 | ⏳ v2 |
| T-409 | 같은 방에서 `SharedCoordinateSpaceProvider` 로 테이블 공유 | ⏳ v2 |
| T-410 | 데모 손님 한국어 TTS(`BotSpeech`) 공간 재생 + 엔벨로프 립싱크 + 자막 | ✅ |
| T-411 | 실기기: 데모 손님 목소리가 좌석 방향에서 들리는지, 입과 맞는지 | 🧪 |

## M6 · 소반 캡처 (iPhone · iPad · Mac)
| ID | 작업 | 상태 |
|---|---|---|
| T-601 | 타깃 멀티플랫폼화(iOS/macOS 26 배포, `#if os` 분리, 플레이스홀더 순수 CoreGraphics) | ✅ |
| T-602 | `CaptureGuide` 각도 안내 상태 기계(정면/한쪽/반대쪽/위, 0.7s 유지) | ✅ |
| T-603 | `CameraCaptureController`: 세션, 미리보기, 동기 Vision yaw/pitch, 깊이 사진(iOS) | ✅ |
| T-604 | `CompanionRootView`: 능력 배너, 가이드 오버레이, 썸네일, 생성, 전송, ShareLink | ✅ |
| T-605 | `PersonaSender` → Vision Pro 전송 + 수신 확인 | ✅ |
| T-606 | Mac 실카메라 검증(얼굴 링, yaw/pitch, 자동 촬영) | ✅ |
| T-607 | iPhone 실기기: TrueDepth 깊이 기록·보정 결과, LiDAR 후면 전환, 전송 | 🧪 |
| T-608 | 깊이로 얼굴 부조(relief) 메시 → 카드 대신 입체 머리 | ⏳ v2 |

## M7 · 가우시안 스플랫 · 입 신호 (3차)
| ID | 작업 | 상태 |
|---|---|---|
| T-701 | `SplatCloud` 모델, "SBSP" 바이너리, 3DGS PLY 내보내기 | ✅ |
| T-702 | `SplatBuilder`: 격자 샘플링, 깊이 z / 머리 타원체·몸통 부조 z, 측면 융합(코 오프셋 θ, 마스크) | ✅ |
| T-703 | `SplatMesh`: 쿼드 + 8×8 타일 아틀라스 RealityKit 렌더(공용) | ✅ |
| T-704 | `PersonaAvatar` 공용화 + 스플랫 몸통, 부조 z 위 오버레이 | ✅ |
| T-705 | 컴패니언: 자동 스플랫 생성, 카드/입체 토글·턴테이블, PLY 공유, 스플랫 포함/사진만 전송 | ✅ |
| T-706 | 전송 프로토콜: depth/side/splats 리소스 + `personaTransferComplete`, `IncomingPackage` 조립 | ✅ |
| T-707 | Vision Pro: 수신 → 초안, 스플랫 없으면 생성, 저장 즉시 활성, 저장된 페르소나 '입체 만들기' | ✅ |
| T-708 | 모임: `splats-<id>.bin` 피어 전송, 원격/거울 아바타 스플랫 렌더 | ✅ |
| T-709 | 입 신호: `MicLevelMeter`, `FaceMouthTracker`(iOS), 카메라 입술 모드(Mac/iOS), `VoiceLevelBar`, 권한 상태·허용 버튼 | ✅ |
| T-710 | 시뮬레이터 검증: `sample splats demo` 로 스플랫 손님·거울·스튜디오 입체 토글 렌더 | ✅ |
| T-711 | 실기기: 사진 보관함 초안 '입체 만들기' 결과, 상에서 고개 돌릴 때 시차 | 🧪 |
| T-712 | iPhone 실기기: TrueDepth 깊이 스플랫 품질, jawOpen 입 모양, 스플랫 포함 전송 → Vision Pro 초안 | 🧪 |
| T-713 | Mac: 카메라 입술 추적 입 모양, 사진만 전송 → Vision Pro 에서 스플랫 생성 | 🧪 |
| T-714 | 스플랫 색/불투명도 소규모 최적화(Metal 컴퓨트) | ⏳ v2 |
| T-715 | `.sobanpersona` 패키지 파일(바이너리 plist) 인코딩/디코딩, 문서 타입·UTI 등록, `onOpenURL` | ✅ |
| T-716 | 3DGS PLY 파서(binary/ascii, f_dc/rgb, opacity, scale, 정규화) → 카드 렌더 → 리그 재검출, 뒤집기 토글 | ✅ |
| T-717 | 스튜디오 '파일에서 불러오기', 컴패니언 `.sobanpersona` 공유, 시뮬레이터 PLY 라운드트립 검증 | ✅ |
| T-718 | `VoiceEngine` 입력 구성 순서 수정(시작 전 inputNode), `requestMicrophoneAccess()`, 진단 문구 | ✅ |
| T-719 | 실기기: 마이크 토글 → 레벨미터 반응, 허용 요청 버튼 → 시스템 프롬프트/수음 시작 | 🧪 |
| T-720 | 실기기: AirDrop 으로 받은 .sobanpersona/.ply 가 공유 시트에서 '소반' 으로 열리는지 | 🧪 |

## M8 · 블렌더 USDZ 에셋 (5차)
| ID | 작업 | 상태 |
|---|---|---|
| T-801 | USDZ 9종을 `Soban/FaceAssets/` 에, `.blend` 원본을 `Docs/blender/` 에 추가(동기화 폴더 → 자동 번들) | ✅ |
| T-802 | `FaceRig.swift`(컴포넌트/시스템/한글 비셈) 통합, `SobanFaceAssets` 멀티플랫폼화 + `FaceAssetLoader` 캐시 | ✅ |
| T-803 | `TableAvatar` 프로토콜, `DemoBustAvatar`, `PlaceholderBustAvatar`, `AvatarDecor` | ✅ |
| T-804 | 데모 손님 → USDZ 흉상 4명(이름·성별 음높이·포인트 색), TTS 자막 → `speak(text:duration:)` 비셈 큐 | ✅ |
| T-805 | 스플랫 페르소나 USDZ 얼굴 키트 부착(리그 정렬·피부 틴트·남/여/끄기 피커, Studio·Companion) | ✅ |
| T-806 | 키트 정렬 버그 수정(에셋 실제 눈알/입 중심 기준) — 시뮬레이터 확인 | ✅ |
| T-807 | `INFOPLIST_FILE` 경로 복구(프로젝트 이동 후 빌드 깨짐) | ✅ |
| T-808 | 실기기: 흉상 깜빡임·시선·립싱크, 실제 사진 스플랫 위 키트 정렬, 성능(4.8 MB×4 로드) | 🧪 |
| T-809 | 데모 손님 자리 카드 썸네일을 USDZ 흉상 스냅샷으로 교체(현재 2D 카드 그대로) | ⏳ |

## M9 · 키트 일체감 · 흉상 템플릿 · 컴패니언 미리보기 (6차)
| ID | 작업 | 상태 |
|---|---|---|
| T-901 | 눈 키트: 눈알(흰자·홍채·동공) 숨기고 눈꺼풀만, 눈 간격/눈 높이 스케일, z 0.45 압축, 눈꺼풀 앞면 = 표면 +1.5 mm (`keepOnlyEyelids`) | ✅ |
| T-902 | 입 키트: 입 폭 스케일, z 0.35 압축, 입술 앞면 = 표면 +1 mm, 머티리얼 색 기반 입술 틴트(`tintLips`), 눈꺼풀 피부 틴트도 색 기반 | ✅ |
| T-903 | 키트를 카드(샘플로 체험)에도 부착 — 샘플 캐릭터 깜빡임/비셈 동작 | ✅ |
| T-904 | `BustTemplate`: `SplatPlaceholder_Bust.usdz` → 정면 z-버퍼 템플릿, 행 평활 가장자리, `SplatBuilder.build(template:)` 우선순위 깊이→템플릿→부조 | ✅ |
| T-905 | `FaceRig` 확장(눈썹·윤곽·머리카락색, 옵셔널) + `PersonaBuilder.makeRig`/`PlaceholderPersona` 채움 | ✅ |
| T-906 | 머리카락 분류 → 볼륨 돔 + 2겹 셸, 경사 보정(옆면 줄무늬 완화) | ✅ |
| T-907 | 컴패니언 미리보기: iOS/macOS 전용 `PerspectiveCamera`, 아바타 실제 크기, `sample` DEBUG 인자 | ✅ |
| T-908 | 시뮬레이터 검증: 눈알 제거·깜빡임 프레임·입술 틴트·Mac 미리보기·두레반 | ✅ |
| T-909 | 실기기: 실제 사진 스플랫에서 눈꺼풀/입술 크기·밀착감, 어깨 템플릿 맞춤, 머리카락 볼륨 자연스러움 | 🧪 |
| T-910 | 옆면(큰 yaw) 줄무늬 완전 제거 — 표면 방향 정렬 스플랫(타원 쿼드) 또는 측면 보간 샘플 추가 | ⏳ |

## M10 · 템플릿 변형 · 외형 힌트 · 흉상 샘플 · 상태 유지 (7차)
| ID | 작업 | 상태 |
|---|---|---|
| T-1001 | `ThinPlateSpline` + `TemplateFit`: 랜드마크 TPS, 행별 실루엣 폭 맞춤, 얼굴 타원 블렌딩, `template.chinY/noseY` 측정 | ✅ |
| T-1002 | `SplatBuilder.build(template:hints:)` 가 `fit.map` 으로 깊이를 읽음, 부조 96×128 | ✅ |
| T-1003 | `AppearanceHints`/`AppearanceAnalyzer`: FoundationModels 사진 첨부 `@Generable`(OS 27) + 8초 타임아웃 + 휴리스틱 폴백, 매니페스트 저장, Studio/Companion 표시 | ✅ |
| T-1004 | 샘플 = 블렌더 흉상 랜덤(`manifest.demoAvatar`), 미리보기·거울·상·원격 참가자 `DemoBustAvatar`, 스플랫 단계 건너뜀, 데모 손님 중복 회피 | ✅ |
| T-1005 | `AppModel.studio` + `CompanionModel`(App 소유) + Combine 디바운스 저장/복원 | ✅ |
| T-1006 | 첫 실행 스플랫 레이스 수정(`activeSplats` 를 splatCount 로도 갱신) | ✅ |
| T-1007 | 검증: 시뮬 흉상 샘플·TPS 턴테이블, Mac Apple Intelligence 힌트·재실행 복원, 4개 빌드 | ✅ |
| T-1008 | 실기기: 실제 사진에서 TPS 윤곽 맞춤·어깨 폭·앞머리 힌트 자연스러움, Vision Pro 에서 Apple Intelligence 힌트 응답 | 🧪 |
| T-1009 | 흉상 샘플의 자리 카드/목록 썸네일을 USDZ 스냅샷으로(현재 비슷한 색의 만화 카드) | ⏳ |

## M11 · ARKit 52 표준 · 네이티브 스플랫 · 표정 신호 (8차)
| ID | 작업 | 상태 |
|---|---|---|
| T-1101 | `ArkitBlendShapes.swift`: 52 이름·`ArkitWeights`·비셈 프리셋·`ShapeNameAdapter`(레거시 13 ↔ ARKit 52) | ✅ |
| T-1102 | `FaceRigSystem`: ARKit 공간 합성 → 어댑터, `externalWeights`, RMS 엔벨로프, 초성 폐쇄·코아티큘레이션·선행 | ✅ |
| T-1103 | `SplatMesh.makeNative`: RealityKit 27 `GaussianSplatComponent`(LowLevelBuffer 인터리브), 시뮬레이터/구 OS 쿼드 폴백, `quadsplats` 인자 | ✅ |
| T-1104 | `SplatJawDeformer`: jawOpen 턱 영역 위치 버퍼 재기록(키트와 같은 신호) | ✅ |
| T-1105 | 입 안쪽 스플랫 컬링(페더) — 치아·입 안 메시 노출 | ✅ |
| T-1106 | iPhone ARKit 52 전체 / Mac·iPhone 카메라 랜드마크 미니 세트 → `expressionSource` → `TableAvatar.setExpression` | ✅ |
| T-1107 | `Docs/blender/ARKit52-요청.md` + UI 에 셰이프키 체계·렌더러 표시 | ✅ |
| T-1108 | 검증: 시뮬 두레반 비셈/깜빡임, macOS 네이티브 스플랫 렌더, 4개 빌드 | ✅ |
| T-1109 | 실기기: Vision Pro 네이티브 스플랫 품질(SH0 색·σ 크기·정렬)·턱 변형 자연스러움·스플랫 상한, iPhone TrueDepth 52 → 키트 직결 | 🧪 |
| T-1110 | 블렌더 ARKit 52 재내보내기(10-03, Blender 5.2) 반영: 8개 USDZ 교체, 어댑터 직통 확인, 프리셋 보정(A+upperUp .3, E jaw .4), 시선→eyeLook* | ✅ |
| T-1111 | SpeechAnalyzer(ko_KR 단어 타이밍) + 자모 비셈 타임라인, visionOS 가용성 확인 | ⏳ |
| T-1112 | audio→ARKit-52 온디바이스 모델(wav2arkit ONNX/Core ML) 실험, 한국어 품질 평가 | ⏳ |

## M12 · 실기기 피드백 (9차, 2026-10-03)
| ID | 작업 | 상태 |
|---|---|---|
| T-1201 | 홈 카드가 썸네일 PNG 라 스튜디오와 다른 모습 → `PersonaPreviewView`(배율 0.26, 흉상·스플랫·키트) 로 통일, 스플랫은 스튜디오 캐시/저장소에서 | ✅ |
| T-1202 | 스튜디오 마이크 레벨미터 0: `level` 을 세션 틱(상 펼쳤을 때만)이 갱신하던 구조 → `VoiceEngine` 자체 30Hz 레벨 태스크 | ✅ |
| T-1203 | 입 모양 예시 → 한국어 TTS(`BotSpeech`)로 문장 재생 + 엔벨로프 레벨 + 비셈 큐(`speechRequest` → `PersonaPreviewView.speech`) | ✅ |
| T-1204 | 상에서 마이크 불능/스위치 무반응: 엔진은 권한 있으면 항상 입력 포함 시작, `AVAudioEngineConfigurationChange`·인터럽션 복구, 실제 `engine.isRunning` 검사, 모임 화면에 레벨미터·상태·허용 버튼 | ✅ |
| T-1205 | 실기기: 스튜디오 레벨미터, TTS 예시, 상에서 내 입 모양·음성 전송, 토글 on/off 반복 | 🧪 |

## M5 · 품질
| ID | 작업 | 상태 |
|---|---|---|
| T-501 | 시뮬레이터 자동 실행 플래그(`sample demo guests= tab= hidewindow distance=`) | ✅ |
| T-502 | 시뮬레이터 크래시 수정: AURemoteIO RPC 타임아웃 → 오디오 지연 시작/시뮬레이터 OFF | ✅ |
| T-503 | Swift Testing 타깃 (TableLayout 슬롯 회전, NRect 변환, SessionMessage 라운드트립, PersonaBuilder 샘플) | ⏳ |
| T-504 | 앱 아이콘, 접근성 라벨 점검 | ⏳ |
| T-505 | 실기기 성능: 틱 시간, 메모리, 배터리 | 🧪 |
| T-506 | 시뮬레이터 크래시 수정: poll/calibrate 무한 재귀(스택 오버플로) | ✅ |
| T-507 | iOS 시뮬레이터·macOS 빌드 통과, 경고 정리 | ✅ |

## 실기기 체크리스트 (3차 — 스플랫·입 신호)
1. Vision Pro 스튜디오 → 저장된 페르소나에서 '입체(스플랫) 만들기' → 카드/입체 토글, 턴테이블 시차.
2. iPhone 소반 캡처 → 촬영 → 자동 스플랫(깊이) → 입체 미리보기 → '움직여 보기' 켜고 입 벌리기(TrueDepth).
3. iPhone → Vision Pro '기기에서 받기' → '스플랫 포함 보내기' → 초안 입체 확인 → 저장 → 모임에서 입체로 보이는지.
4. Mac → '사진만 보내기' → Vision Pro 가 스플랫을 만들어 초안으로 띄우는지.
5. 스튜디오 4단계: 마이크 토글 → 레벨미터·권한 문구 → 입 벌림.

## 실기기 체크리스트 (2차 — 피드백 항목)
1. 스튜디오 → 사진 보관함: 시트가 미리보기에 가려지지 않는지.
2. 스튜디오 → '마이크로 입 움직이기' 켜고 말하기: 레벨미터와 함께 입이 벌어지는지.
3. 이름 입력 → 이름표 즉시 변경 → '이름 적용' → 저장된 페르소나 이름 변경 확인.
4. 모임 → 데모 손님과: 손님 목소리가 각 자리 방향에서 들리고 자막이 뜨는지.
5. 모임 → '내 모습 보기' 켜기: 오른쪽 위 거울 아바타가 내 고개/입/손을 따라오는지.
6. 상 접기 → 소반 펼치기 3회 반복, Digital Crown 으로 닫은 뒤에도 버튼이 살아나는지.
7. iPhone/Mac 에서 소반 캡처 → Vision Pro '기기에서 받기' → 전송 → 홈에서 새 페르소나 확인.

## 실기기 체크리스트 (첫 실행)
1. Xcode 에서 "김민웅님의 Apple Vision Pro" 선택 → Run (자동 서명, 엔타이틀먼트 없음).
2. 홈 → 페르소나 → 사진 보관함에서 상반신 정면 사진 선택 → 분석 → 저장.
3. 모임 → 소반 펼치기 → 손 추적 권한 허용 → 상태 문구 "머리 + 손 추적 중".
4. 마이크 허용 → 스튜디오 미리보기에서 말하며 입 벌림 확인.
5. 데모 손님과 → 두레반과 손님 5명이 방석 위에 뜨는지, 테이블 거리 슬라이더 조절.
6. (2대) 한쪽 모임 열기, 다른 쪽 모임 참여 → 로컬 네트워크 권한 허용 → 앉기 → 상대 페르소나 수신, 고개/손/음성.
