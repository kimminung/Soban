# 블렌더 작업 요청 — ARKit 52 셰이프키 (8차)

소반 8차부터 얼굴 표정의 **내부 표준이 ARKit 52 블렌드셰이프 이름**입니다. 지금 USDZ(1차 에셋)는 레거시 13개
(`Blink_L, Blink_R, EyeWide, Squint, BrowUp, JawOpen, A, I, U, E, O, Smile, Press`)라서 앱이 `ShapeNameAdapter`로
조합해서 넣고 있습니다. 아래대로 다시 내보내 주시면 **코드 수정 없이** 자동으로 직통 경로를 탑니다
(앱은 메시 셰이프키 이름에 `jawOpen`·`eyeBlinkLeft`·`mouthSmileLeft` 중 하나라도 있으면 ARKit 에셋으로 판단).

## 대상 파일 (9개 모두)

- `DemoAvatar_Ethan / Olivia / Lucas / Emma` — Head 메시와 눈꺼풀·입 메시
- `SplatFace_Eyes_Male / Female` — `*_Eyelids` 메시 (눈알은 그대로)
- `SplatFace_Mouth_Male / Female` — 입술·치아·입안 한 메시
- `SplatPlaceholder_Bust` — 셰이프키 없음, 그대로

## 이름 변환 표 (기존 → ARKit)

| 기존 | ARKit 52 | 방법 |
|---|---|---|
| Blink_L | eyeBlinkLeft | 리네임. **Left = 피사체 기준 왼쪽** (거울 아님) |
| Blink_R | eyeBlinkRight | 리네임 |
| EyeWide | eyeWideLeft, eyeWideRight | 버텍스 그룹 마스크로 좌/우 분할 |
| Squint | eyeSquintLeft, eyeSquintRight (+ cheekSquintLeft/Right 볼까지 올라가면) | 좌/우 분할 |
| BrowUp | browInnerUp, browOuterUpLeft, browOuterUpRight | 안쪽/바깥 분할 |
| JawOpen | jawOpen | 리네임 |
| Smile | mouthSmileLeft, mouthSmileRight | 좌/우 분할 |
| Press | mouthPressLeft, mouthPressRight, mouthClose | 좌/우 분할 + 입 다물기(mouthClose 는 턱은 그대로 입술만 닫힘) |
| A / I / U / E / O | (삭제해도 됨) | 앱이 ARKit 조합으로 합성: A = jawOpen 0.6 + mouthLowerDownL/R 0.3, I = jawOpen 0.15 + mouthStretchL/R 0.5 + mouthSmileL/R 0.2, U = mouthPucker 0.8 + mouthFunnel 0.3 + jawOpen 0.1, E = jawOpen 0.3 + mouthStretchL/R 0.4, O = jawOpen 0.35 + mouthFunnel 0.7 + mouthPucker 0.3. 남겨 두셔도 무시됩니다 |

## 새로 만들어야 하는 셰이프 (립싱크 최소 세트, 굵게)

**mouthClose, mouthFunnel, mouthPucker, mouthStretchLeft, mouthStretchRight, mouthLowerDownLeft, mouthLowerDownRight,
mouthPressLeft, mouthPressRight, mouthSmileLeft, mouthSmileRight, jawOpen**

추가하면 좋은 것: mouthUpperUpLeft/Right, mouthRollLower/Upper, mouthFrownLeft/Right, mouthLeft/Right, jawLeft/Right/Forward,
browDownLeft/Right, cheekPuff, noseSneerLeft/Right, tongueOut, eyeLookUp/Down/In/Out × Left/Right (8개, 눈알 메시가 아니라
눈꺼풀이 따라 움직이는 양만).

전체 52개 이름(대소문자 그대로):
```
eyeBlinkLeft eyeLookDownLeft eyeLookInLeft eyeLookOutLeft eyeLookUpLeft eyeSquintLeft eyeWideLeft
eyeBlinkRight eyeLookDownRight eyeLookInRight eyeLookOutRight eyeLookUpRight eyeSquintRight eyeWideRight
jawForward jawLeft jawRight jawOpen
mouthClose mouthFunnel mouthPucker mouthLeft mouthRight mouthSmileLeft mouthSmileRight mouthFrownLeft mouthFrownRight
mouthDimpleLeft mouthDimpleRight mouthStretchLeft mouthStretchRight mouthRollLower mouthRollUpper mouthShrugLower mouthShrugUpper
mouthPressLeft mouthPressRight mouthLowerDownLeft mouthLowerDownRight mouthUpperUpLeft mouthUpperUpRight
browDownLeft browDownRight browInnerUp browOuterUpLeft browOuterUpRight
cheekPuff cheekSquintLeft cheekSquintRight noseSneerLeft noseSneerRight tongueOut
```

## 블렌더 쪽 방법

1. **Faceit**(유료 애드온): 랜드마크 배치 → ARKit 52 자동 생성 → 기존 셰이프와 비교해 정리.
2. **Blender MCP + Claude**: "기존 셰이프키를 좌우 버텍스 그룹 마스크로 분할하고 ARKit 이름으로 리네임, 누락 셰이프는 기존 조합
   또는 스컬프트로 생성" — 좌/우 마스크는 X=0 기준 가중치 페이드 2 cm.
3. 무료 대안: Mio3 UV + Mesh Data Transfer 로 ARKit 셰이프키가 있는 참조 헤드에서 UV 기준 전사.

## 내보내기 주의

- USD 내보내기는 **Blender 4.1 이상**에서만 셰이프키/스켈레톤을 지원합니다.
- **Apply Modifiers 를 끄세요.** 켜면 셰이프키가 빠집니다.
- 단위 m, Y-up, 얼굴 +Z, 흉상 좌표계(눈 y≈0.44, 간격 0.064, 입 y≈0.357, 정수리 0.566)는 1차와 같게.
- 눈알 엔티티 이름 `*_Eye_L / *_Eye_R`, 눈꺼풀 `*_Eyelids` 는 그대로 (앱이 이름으로 찾습니다).
- 셰이프키 값 범위 0…1, 중립 0.

## 확인 방법

앱 DEBUG 실행 인자 `SOBAN_DUMP_KIT=1`(환경변수)로 켜면 `tmp/soban-kit-dump.txt` 에 계층·머티리얼이, 스튜디오 5단계 아래에는
"셰이프키: ARKit 52 직통" / "레거시 13 → 어댑터" 가 표시됩니다 (8차).
