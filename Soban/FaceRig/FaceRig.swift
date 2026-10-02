//
//  FaceRig.swift
//  Soban
//
//  블렌더에서 만든 USDZ의 블렌드셰이프(눈 깜빡임 / 입모양)를 코드로 구동하는 컴포넌트 + 시스템.
//  - 데모 아바타(DemoAvatar_*.usdz)와 스플랫 페이스 킷(SplatFace_Eyes_* / SplatFace_Mouth_*) 모두 같은 이름 규칙을 쓰므로
//    엔티티 루트에 FaceRigComponent 하나만 붙이면 하위의 모든 메시가 함께 반응합니다.
//
//  블렌드셰이프 이름 — 2026-10-03 ARKit 52 재내보내기(Soban_FaceAssets_ARKit52.blend) 이후:
//    눈꺼풀 : eyeBlink/eyeWide/eyeSquint/eyeLookUp·Down·In·Out × Left/Right (14)
//    눈썹   : browInnerUp, browOuterUpLeft/Right, browDownLeft/Right (5, 데모 아바타 Brows 메시)
//    입     : jawOpen, mouthClose, mouthFunnel, mouthPucker, mouthStretch·LowerDown·UpperUp·Smile·Press·Frown × L/R (16)
//    Head   : jawOpen (턱이 같이 내려감)
//  1차 레거시 이름(Blink_L, JawOpen, A/I/U/E/O, Smile, Press…)은 `ShapeNameAdapter` 가 계속 지원한다.
//
//  등록 (App init 등에서 1회)
//    FaceRigComponent.registerComponent()
//    FaceRigSystem.registerSystem()
//
//  소반 통합 메모: 블렌더 MCP 로 만든 에셋(Docs/blender/Soban_FaceAssets.blend)과 함께 들어온 파일.
//  SobanApp / SobanCompanionApp 의 init 에서 등록한다. 모든 플랫폼(visionOS·iOS·macOS)에서 컴파일된다.
//
//  8차: 내부 표준은 ARKit 52 (`ArkitBlendShapes.swift`). 시스템은 매 프레임 ARKit 공간의 목표를 만들고
//  `ShapeNameAdapter` 로 메시가 가진 이름(레거시 13개 또는 ARKit 52)으로 바꿔 넣는다.
//  - `externalWeights` 가 있으면(iPhone ARKit, Mac 카메라 랜드마크, 네트워크) 합성 대신 그 값을 쓴다.
//  - 립싱크 규칙: RMS 는 턱 에너지 엔벨로프로만, 모양은 비셈이 결정. ㅁ/ㅂ/ㅍ 초성 폐쇄(70 ms), 코아티큘레이션 50 ms 크로스페이드,
//    40 ms 선행(anticipation).
//

import RealityKit
import Foundation

// MARK: - Viseme

enum Viseme: String, CaseIterable, Sendable {
    case rest, A, I, U, E, O, press

    /// 각 비셈이 실제 블렌드셰이프에 주는 가중치
    var weights: [String: Float] {
        switch self {
        case .rest:  return [:]
        case .A:     return ["A": 1.0]
        case .I:     return ["I": 1.0]
        case .U:     return ["U": 1.0]
        case .E:     return ["E": 1.0]
        case .O:     return ["O": 1.0]
        case .press: return ["Press": 1.0]
        }
    }
}

// MARK: - Component

struct FaceRigComponent: Component {

    // 외부(코드)에서 넣는 값 ------------------------------------------------------------
    /// 0...1 마이크/스트림 음량(RMS 정규화값). 말할 때마다 매 프레임 혹은 오디오 탭마다 갱신하세요.
    var audioLevel: Float = 0
    /// 텍스트(자막/STT)가 있으면 한글 모음 기반 비셈 큐를 넣을 수 있습니다. (speak(text:) 참고)
    var visemeQueue: [(viseme: Viseme, duration: Float)] = []
    /// 표정 오버라이드 (0...1)
    var smile: Float = 0
    var browUp: Float = 0
    var autoBlink: Bool = true
    var autoGaze: Bool = true
    /// 8차: 외부 표정 신호(ARKit 52). nil 이면 음량/비셈으로 합성한다. 매 프레임 갱신하고, 끊기면 nil 로.
    var externalWeights: ArkitWeights?
    /// 외부 신호가 깜빡임을 포함하면 자동 깜빡임은 멈춘다 (iPhone ARKit). 카메라 랜드마크 미니 세트는 포함 안 함.
    var externalIncludesBlink: Bool = false

    // 튜닝 -----------------------------------------------------------------------------
    var speechGate: Float = 0.04          // 이 이하 음량은 무음으로 처리
    var jawGain: Float = 1.6
    var syllablesPerSecond: Float = 6.0   // 텍스트 없이 음량만 있을 때 모음 순환 속도
    var blinkInterval: ClosedRange<Float> = 2.2...5.5
    var blinkDuration: Float = 0.14

    // 내부 상태 -------------------------------------------------------------------------
    var current: [String: Float] = [:]
    var blinkTimer: Float = Float.random(in: 1...3)
    var blinkPhase: Float = -1            // <0 이면 깜빡이는 중 아님
    var doubleBlink = false
    var syllableTimer: Float = 0
    var autoViseme: Viseme = .A
    var queueTimer: Float = 0
    var gazeTimer: Float = 1
    var gazeTarget: SIMD2<Float> = .zero
    var gaze: SIMD2<Float> = .zero
    var isSetUp = false
    /// 메시들이 가진 셰이프키 이름 (어댑터용, 설정 시 1회 수집)
    var shapeNames: Set<String> = []
    /// 코아티큘레이션용: 직전 비셈과 그 가중치
    var previousViseme: Viseme = .rest
    var previousAmount: Float = 0
    var smoothedArkit = ArkitWeights()

    init() {}

    /// 한글 문장 → 비셈 큐. (TTS/STT 텍스트와 함께 쓰면 입모양이 더 그럴듯해집니다)
    mutating func speak(text: String, secondsPerSyllable: Float = 0.16) {
        visemeQueue.append(contentsOf: HangulViseme.visemes(for: text, secondsPerSyllable: secondsPerSyllable))
    }
}

// MARK: - System

struct FaceRigSystem: System {
    static let query = EntityQuery(where: .has(FaceRigComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var rig = entity.components[FaceRigComponent.self] else { continue }
            if !rig.isSetUp {
                FaceRigSystem.prepareBlendShapes(in: entity)
                rig.isSetUp = true
            }

            if rig.shapeNames.isEmpty { rig.shapeNames = FaceRigSystem.collectShapeNames(in: entity) }

            var arkit = ArkitWeights()            // ARKit 공간 목표
            var legacyVisemes: [String: Float] = [:] // 레거시 비셈 셰이프 직접 값 (합성 경로)

            // 0) 외부 표정 신호 ---------------------------------------------------------
            if let ext = rig.externalWeights {
                arkit = ext
            }
            // 0b) 시선 미세 움직임 → 눈알 회전(데모 아바타) + ARKit eyeLook* (ARKit 52 눈꺼풀이 살짝 따라감)
            if rig.autoGaze {
                rig.gazeTimer -= dt
                if rig.gazeTimer <= 0 {
                    rig.gazeTimer = Float.random(in: 0.8...2.8)
                    rig.gazeTarget = SIMD2(Float.random(in: -0.12...0.12), Float.random(in: -0.06...0.06))
                }
                rig.gaze += (rig.gazeTarget - rig.gaze) * min(1, dt * 18)
                if rig.externalWeights == nil {
                    let gx = rig.gaze.x / 0.12, gy = rig.gaze.y / 0.06
                    // +x = 피사체 왼쪽으로 봄 → 왼눈은 Out, 오른눈은 In
                    if gx > 0 { arkit[.eyeLookOutLeft] = gx; arkit[.eyeLookInRight] = gx } else { arkit[.eyeLookInLeft] = -gx; arkit[.eyeLookOutRight] = -gx }
                    if gy > 0 { arkit[.eyeLookUpLeft] = gy; arkit[.eyeLookUpRight] = gy } else { arkit[.eyeLookDownLeft] = -gy; arkit[.eyeLookDownRight] = -gy }
                }
            }

            // 1) 눈 깜빡임 -------------------------------------------------------------
            if rig.autoBlink && !(rig.externalWeights != nil && rig.externalIncludesBlink) {
                rig.blinkTimer -= dt
                if rig.blinkTimer <= 0 && rig.blinkPhase < 0 {
                    rig.blinkPhase = 0
                    rig.doubleBlink = Float.random(in: 0...1) < 0.15
                }
                if rig.blinkPhase >= 0 {
                    rig.blinkPhase += dt / rig.blinkDuration
                    // 빠르게 감고(40%) 천천히 뜨기(60%)
                    let p = rig.blinkPhase
                    let w: Float = p < 0.4 ? p / 0.4 : max(0, 1 - (p - 0.4) / 0.6)
                    arkit[.eyeBlinkLeft] = max(arkit[.eyeBlinkLeft], w)
                    arkit[.eyeBlinkRight] = max(arkit[.eyeBlinkRight], w)
                    if p >= 1 {
                        rig.blinkPhase = -1
                        rig.blinkTimer = rig.doubleBlink ? 0.12 : Float.random(in: rig.blinkInterval)
                        rig.doubleBlink = false
                    }
                }
            }

            // 2) 말하기 (외부 신호가 없을 때만 합성) ----------------------------------------
            // RMS 는 "에너지 엔벨로프"로만 쓴다: 턱이 얼마나 크게 움직이는지. 모양(비셈)은 텍스트/순환이 결정.
            let level = max(0, rig.audioLevel - rig.speechGate) / max(0.001, 1 - rig.speechGate)
            let open = min(1, level * rig.jawGain)

            if rig.externalWeights == nil {
                if !rig.visemeQueue.isEmpty {
                    rig.queueTimer += dt
                    let head = rig.visemeQueue[0]
                    let t = min(1, rig.queueTimer / max(0.01, head.duration))
                    // 음절 안에서 열렸다 닫힘 + 음량 엔벨로프 (TTS 엔벨로프가 있으면 그에 맞춰 크기 변화)
                    let env = sin(Float.pi * t)
                    let amount = env * max(0.5, min(1, 0.5 + open)) * 0.95
                    // 코아티큘레이션: 처음 50 ms 는 직전 비셈에서 크로스페이드, 마지막 40 ms 는 다음 비셈을 선행
                    let fadeIn = min(1, rig.queueTimer / 0.05)
                    var cur = ArkitVisemePreset.weights(for: head.viseme, amount: amount)
                    cur.scale(fadeIn)
                    if fadeIn < 1, rig.previousAmount > 0 {
                        cur.add(ArkitVisemePreset.weights(for: rig.previousViseme, amount: rig.previousAmount), scale: 1 - fadeIn)
                    }
                    let remaining = head.duration - rig.queueTimer
                    if remaining < 0.04, rig.visemeQueue.count > 1 {
                        let next = rig.visemeQueue[1]
                        let lead = (0.04 - remaining) / 0.04
                        cur.add(ArkitVisemePreset.weights(for: next.viseme, amount: 0.5 * amount), scale: lead)
                    }
                    arkit.add(cur)
                    for (k, v) in head.viseme.weights { legacyVisemes[k, default: 0] += v * amount }
                    if rig.queueTimer >= head.duration {
                        rig.previousViseme = head.viseme
                        rig.previousAmount = amount
                        rig.queueTimer = 0
                        rig.visemeQueue.removeFirst()
                    }
                } else if open > 0.01 {
                    // 음량만 있을 때: 음절 속도로 모음을 순환 (모양은 비셈, 크기는 엔벨로프)
                    rig.syllableTimer += dt
                    if rig.syllableTimer > 1 / rig.syllablesPerSecond {
                        rig.syllableTimer = 0
                        let pool: [Viseme] = [.A, .A, .E, .O, .I, .U, .A, .E]
                        var next = pool.randomElement()!
                        if next == rig.autoViseme { next = .A }
                        rig.previousViseme = rig.autoViseme
                        rig.previousAmount = open * 0.85
                        rig.autoViseme = next
                    }
                    let fadeIn = min(1, rig.syllableTimer / 0.05)
                    var cur = ArkitVisemePreset.weights(for: rig.autoViseme, amount: open * 0.85)
                    cur.scale(fadeIn)
                    if fadeIn < 1 { cur.add(ArkitVisemePreset.weights(for: rig.previousViseme, amount: rig.previousAmount), scale: 1 - fadeIn) }
                    arkit.add(cur)
                    arkit.add(.jawOpen, open * 0.25)
                    for (k, v) in rig.autoViseme.weights { legacyVisemes[k, default: 0] += v * open * 0.85 }
                } else {
                    rig.previousAmount = max(0, rig.previousAmount - dt * 6)
                }
            }

            // 3) 표정 ------------------------------------------------------------------
            if rig.smile > 0 { arkit.add(.mouthSmileLeft, rig.smile); arkit.add(.mouthSmileRight, rig.smile) }
            if rig.browUp > 0 { arkit.add(.browInnerUp, rig.browUp); arkit.add(.browOuterUpLeft, rig.browUp * 0.7); arkit.add(.browOuterUpRight, rig.browUp * 0.7) }

            // 4) 스무딩 (입은 빠르게, 깜빡임은 즉시) + 이름 어댑터 ----------------------------
            var target = ShapeNameAdapter.resolve(arkit, legacyVisemes: legacyVisemes, names: rig.shapeNames)
            target = target.mapValues { min(1, $0) }
            var next: [String: Float] = [:]
            let names = Set(rig.current.keys).union(target.keys)
            for name in names {
                let goal = target[name] ?? 0
                let cur = rig.current[name] ?? 0
                let isBlink = name.hasPrefix("Blink") || name.hasPrefix("eyeBlink")
                let speed: Float = isBlink ? 60 : (goal > cur ? 22 : 14)
                let v = cur + (goal - cur) * min(1, dt * speed)
                if v > 0.0005 || goal > 0 { next[name] = v }
            }
            rig.current = next
            FaceRigSystem.apply(next, to: entity)

            // 5) 시선: 눈알 엔티티 회전은 위(0단계)에서 계산한 gaze 로
            if rig.autoGaze { FaceRigSystem.applyGaze(rig.gaze, to: entity) }

            entity.components.set(rig)
        }
    }

    // MARK: Blend shape plumbing

    /// 하위 모든 ModelEntity에 BlendShapeWeightsComponent 를 붙입니다.
    @MainActor
    static func prepareBlendShapes(in root: Entity) {
        root.forEachDescendant { e in
            guard let model = e.components[ModelComponent.self],
                  e.components[BlendShapeWeightsComponent.self] == nil else { return }
            let mapping = BlendShapeWeightsMapping(meshResource: model.mesh)
            let comp = BlendShapeWeightsComponent(weightsMapping: mapping)
            // 블렌드셰이프가 없는 메시는 건너뜀
            let hasShapes = comp.weightSet.contains { !$0.weightNames.isEmpty }
            if hasShapes { e.components.set(comp) }
        }
    }

    /// 마지막으로 설정된 리그의 셰이프키 이름 체계 (UI 표시용): "ARKit 52 직통" / "레거시 13 → 어댑터".
    @MainActor static var lastNamingDescription = "셰이프키 없음"

    /// 하위 메시들의 셰이프키 이름(경로 마지막 토큰) 집합.
    @MainActor
    static func collectShapeNames(in root: Entity) -> Set<String> {
        var names = Set<String>()
        root.forEachDescendant { e in
            guard let comp = e.components[BlendShapeWeightsComponent.self] else { return }
            for data in comp.weightSet {
                for fullName in data.weightNames {
                    names.insert(fullName.split(separator: "/").last.map(String.init) ?? fullName)
                }
            }
        }
        if !names.isEmpty {
            lastNamingDescription = ShapeNameAdapter.usesArkitNames(names) ? "ARKit 52 직통 (\(names.count)개)" : "레거시 \(names.count)개 → ARKit 어댑터"
        }
        return names
    }

    @MainActor
    static func apply(_ values: [String: Float], to root: Entity) {
        root.forEachDescendant { e in
            guard var comp = e.components[BlendShapeWeightsComponent.self] else { return }
            for i in comp.weightSet.indices {
                var data = comp.weightSet[i]
                for (j, fullName) in data.weightNames.enumerated() {
                    // USD 경로 형태로 들어와도 마지막 이름만 비교
                    let name = fullName.split(separator: "/").last.map(String.init) ?? fullName
                    data.weights[j] = values[name] ?? 0
                }
                comp.weightSet[i] = data
            }
            e.components.set(comp)
        }
    }

    @MainActor
    static func applyGaze(_ g: SIMD2<Float>, to root: Entity) {
        root.forEachDescendant { e in
            let isEye: (Entity?) -> Bool = { $0.map { $0.name.hasSuffix("_Eye_L") || $0.name.hasSuffix("_Eye_R") } ?? false }
            // Xform/Mesh 가 같은 이름으로 중첩될 수 있으므로 가장 바깥 눈 엔티티만 회전
            guard isEye(e), !isEye(e.parent) else { return }
            // 눈알 엔티티의 원점 = 안구 중심 (블렌더에서 그렇게 만들었음)
            let yaw = simd_quatf(angle: g.x, axis: [0, 1, 0])
            let pitch = simd_quatf(angle: -g.y, axis: [1, 0, 0])
            e.orientation = yaw * pitch
        }
    }
}

// MARK: - Helpers

extension Entity {
    @MainActor
    func forEachDescendant(_ body: (Entity) -> Void) {
        body(self)
        for child in children { child.forEachDescendant(body) }
    }
}

/// 마이크 버퍼 → 0...1 음량 (AVAudioEngine 탭 등에서 사용)
enum AudioLevel {
    static func normalizedRMS(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = sqrt(sum / Float(samples.count))
        let db = 20 * log10(max(rms, 1e-6))          // -120 ... 0 dB
        return min(1, max(0, (db + 50) / 40))          // -50dB → 0, -10dB → 1
    }
}

/// 한글 음절의 중성(모음)으로 입모양 결정
enum HangulViseme {
    static func visemes(for text: String, secondsPerSyllable: Float) -> [(viseme: Viseme, duration: Float)] {
        var out: [(Viseme, Float)] = []
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v >= 0xAC00 && v <= 0xD7A3 {
                let idx = Int(v - 0xAC00)
                let initial = idx / (21 * 28)
                let medial = (idx % (21 * 28)) / 28
                let final = idx % 28
                // 초성 ㅁ(6) ㅂ(7) ㅃ(8) ㅍ(17) → 모음 앞에 짧은 입술 폐쇄(약 70 ms)
                if [6, 7, 8, 17].contains(initial) {
                    out.append((.press, min(0.07, secondsPerSyllable * 0.35)))
                    out.append((viseme(medial: medial), max(0.04, secondsPerSyllable - min(0.07, secondsPerSyllable * 0.35))))
                } else {
                    out.append((viseme(medial: medial), secondsPerSyllable))
                }
                // 받침 ㅁ(16) ㅂ(17) ㅍ(26) → 입술 닫기
                if [16, 17, 26].contains(final) { out.append((.press, secondsPerSyllable * 0.4)) }
            } else if scalar.properties.isWhitespace || ",.!?".unicodeScalars.contains(scalar) {
                out.append((.rest, secondsPerSyllable * 0.8))
            }
        }
        return out
    }

    private static func viseme(medial: Int) -> Viseme {
        switch medial {
        case 0, 2, 9, 10:           return .A   // ㅏ ㅑ ㅘ ㅙ
        case 1, 3, 5, 7, 11, 15:    return .E   // ㅐ ㅒ ㅔ ㅖ ㅚ ㅞ
        case 4, 6, 14:              return .O   // ㅓ ㅕ ㅝ (반쯤 벌린 둥근 입)
        case 8, 12:                 return .O   // ㅗ ㅛ
        case 13, 16, 17:            return .U   // ㅜ ㅟ ㅠ
        case 18, 19, 20:            return .I   // ㅡ ㅢ ㅣ
        default:                    return .A
        }
    }
}
