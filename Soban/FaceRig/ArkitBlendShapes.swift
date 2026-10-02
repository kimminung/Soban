//
//  ArkitBlendShapes.swift
//  Soban
//
//  8차: 얼굴 표정의 **내부 표준을 ARKit 52 블렌드셰이프 이름**으로 통일한다.
//  - iPhone ARKit(TrueDepth), MediaPipe, Audio2Face, LAM-A2E 가 모두 이 52개 이름을 내므로 매핑 없이 꽂힌다.
//  - 기존 비셈(A/I/U/E/O)은 ARKit 조합으로 정의한 "프리셋 레이어"로 유지한다.
//  - 블렌더 USDZ 가 아직 레거시 이름(Blink_L, JawOpen, A, Smile, Press…)이면 `ShapeNameAdapter` 가 조합해서 넣고,
//    ARKit 52 이름으로 다시 내보내면(Docs/blender/ARKit52-요청.md) 자동으로 직통 경로를 탄다.
//

import Foundation
import simd

/// ARKit `ARFaceAnchor.BlendShapeLocation` 과 같은 52개 이름 (rawValue 가 그대로 ARKit 이름).
enum ArkitShape: String, CaseIterable, Codable, Sendable {
    // 눈 (14)
    case eyeBlinkLeft, eyeLookDownLeft, eyeLookInLeft, eyeLookOutLeft, eyeLookUpLeft, eyeSquintLeft, eyeWideLeft
    case eyeBlinkRight, eyeLookDownRight, eyeLookInRight, eyeLookOutRight, eyeLookUpRight, eyeSquintRight, eyeWideRight
    // 턱 (4)
    case jawForward, jawLeft, jawRight, jawOpen
    // 입 (23)
    case mouthClose, mouthFunnel, mouthPucker, mouthLeft, mouthRight
    case mouthSmileLeft, mouthSmileRight, mouthFrownLeft, mouthFrownRight
    case mouthDimpleLeft, mouthDimpleRight, mouthStretchLeft, mouthStretchRight
    case mouthRollLower, mouthRollUpper, mouthShrugLower, mouthShrugUpper
    case mouthPressLeft, mouthPressRight, mouthLowerDownLeft, mouthLowerDownRight, mouthUpperUpLeft, mouthUpperUpRight
    // 눈썹 (5)
    case browDownLeft, browDownRight, browInnerUp, browOuterUpLeft, browOuterUpRight
    // 볼·코·혀 (6)
    case cheekPuff, cheekSquintLeft, cheekSquintRight, noseSneerLeft, noseSneerRight, tongueOut

    var index: Int { Self.indexByCase[self]! }
    private static let indexByCase: [ArkitShape: Int] = Dictionary(uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })
    static let count = allCases.count   // 52

    /// 립싱크 최소 세트 (문서 (b) 표).
    static let lipSyncMinimum: [ArkitShape] = [.jawOpen, .mouthClose, .mouthFunnel, .mouthPucker, .mouthStretchLeft, .mouthStretchRight,
                                               .mouthLowerDownLeft, .mouthLowerDownRight, .mouthPressLeft, .mouthPressRight,
                                               .mouthSmileLeft, .mouthSmileRight]
}

/// 52개 가중치 (0…1). 값 타입이라 네트워크/컴포넌트에 그대로 들어간다.
nonisolated struct ArkitWeights: Hashable, Sendable, Codable {
    var values: [Float]

    init() { values = [Float](repeating: 0, count: ArkitShape.count) }
    init(_ dict: [ArkitShape: Float]) {
        self.init()
        for (k, v) in dict { values[k.index] = v }
    }
    /// ARKit 이름 문자열 사전에서 (ARFaceAnchor.blendShapes, MediaPipe 등).
    init(named dict: [String: Float]) {
        self.init()
        for (name, v) in dict { if let s = ArkitShape(rawValue: name) { values[s.index] = v } }
    }

    static let zero = ArkitWeights()

    subscript(_ shape: ArkitShape) -> Float {
        get { values[shape.index] }
        set { values[shape.index] = newValue }
    }

    /// 누적 (최대 1).
    mutating func add(_ shape: ArkitShape, _ v: Float) { values[shape.index] = min(1, values[shape.index] + v) }
    mutating func add(_ other: ArkitWeights, scale: Float = 1) {
        for i in values.indices { values[i] = min(1, values[i] + other.values[i] * scale) }
    }
    mutating func scale(_ s: Float) { for i in values.indices { values[i] *= s } }

    /// ARKit 이름 → 값 (0 은 생략).
    var named: [String: Float] {
        var out: [String: Float] = [:]
        for s in ArkitShape.allCases where values[s.index] > 0.0005 { out[s.rawValue] = values[s.index] }
        return out
    }

    /// 선형 보간.
    func blended(toward target: ArkitWeights, _ t: Float) -> ArkitWeights {
        var out = self
        for i in values.indices { out.values[i] += (target.values[i] - values[i]) * t }
        return out
    }

    var isEmpty: Bool { !values.contains { $0 > 0.0005 } }
}

/// 비셈 → ARKit 조합 프리셋 (문서 (b) 표의 출발값, 소반 메시 기준으로 조금 조정).
enum ArkitVisemePreset {
    static func weights(for viseme: Viseme, amount: Float) -> ArkitWeights {
        var w = ArkitWeights()
        let a = max(0, min(1, amount))
        switch viseme {
        case .rest:
            break
        case .A:    // 아: 턱 크게, 아랫입술 내림 (+ 윗입술 올림 0.3 — 블렌더 재합성 오차 보정, ARKit 52 에셋 기준)
            w[.jawOpen] = 0.6 * a; w[.mouthLowerDownLeft] = 0.3 * a; w[.mouthLowerDownRight] = 0.3 * a
            w[.mouthUpperUpLeft] = 0.3 * a; w[.mouthUpperUpRight] = 0.3 * a
        case .I:    // 이: 옆으로 당김, 턱 조금
            w[.jawOpen] = 0.15 * a; w[.mouthStretchLeft] = 0.5 * a; w[.mouthStretchRight] = 0.5 * a
            w[.mouthSmileLeft] = 0.2 * a; w[.mouthSmileRight] = 0.2 * a
        case .U:    // 우: 오므림
            w[.mouthPucker] = 0.8 * a; w[.mouthFunnel] = 0.3 * a; w[.jawOpen] = 0.1 * a
        case .E:    // 에 (jawOpen 0.3 → 0.4: E 전용 키 없이 I 파생 stretch 로 재구성한 오차 보정)
            w[.jawOpen] = 0.4 * a; w[.mouthStretchLeft] = 0.4 * a; w[.mouthStretchRight] = 0.4 * a
        case .O:    // 오/어
            w[.jawOpen] = 0.35 * a; w[.mouthFunnel] = 0.7 * a; w[.mouthPucker] = 0.3 * a
        case .press: // ㅁ/ㅂ/ㅍ 폐쇄
            w[.mouthPressLeft] = 0.8 * a; w[.mouthPressRight] = 0.8 * a; w[.mouthClose] = 0.6 * a
        }
        return w
    }
}

/// ARKit 가중치를 **메시가 실제로 가진 셰이프키 이름**으로 바꾼다.
enum ShapeNameAdapter {
    /// 레거시(블렌더 1차 에셋) 이름.
    static let legacyNames: Set<String> = ["Blink_L", "Blink_R", "EyeWide", "Squint", "BrowUp", "JawOpen", "A", "I", "U", "E", "O", "Smile", "Press"]

    /// 메시 이름 집합이 ARKit 이름을 포함하는가 (하나라도 있으면 ARKit 에셋으로 본다).
    static func usesArkitNames(_ names: Set<String>) -> Bool {
        names.contains("jawOpen") || names.contains("eyeBlinkLeft") || names.contains("mouthSmileLeft")
    }

    /// - Parameters:
    ///   - arkit: 표준 가중치
    ///   - legacyVisemes: 레거시 비셈 셰이프(A/I/U/E/O/Press)에 직접 줄 값(비셈 합성 경로일 때만). ARKit 에셋에서는 무시된다.
    ///   - names: 메시의 셰이프키 이름 집합
    static func resolve(_ arkit: ArkitWeights, legacyVisemes: [String: Float], names: Set<String>) -> [String: Float] {
        if usesArkitNames(names) {
            return arkit.named
        }
        return legacy(from: arkit, visemes: legacyVisemes)
    }

    /// ARKit → 레거시 13개. 좌우 분리 셰이프는 max 로 합친다.
    static func legacy(from w: ArkitWeights, visemes: [String: Float]) -> [String: Float] {
        var out: [String: Float] = [:]
        func put(_ k: String, _ v: Float) { if v > 0.0005 { out[k, default: 0] = min(1, out[k, default: 0] + v) } }
        put("Blink_L", w[.eyeBlinkLeft])
        put("Blink_R", w[.eyeBlinkRight])
        put("EyeWide", max(w[.eyeWideLeft], w[.eyeWideRight]))
        put("Squint", max(w[.eyeSquintLeft], w[.eyeSquintRight]))
        put("BrowUp", max(w[.browInnerUp], w[.browOuterUpLeft], w[.browOuterUpRight]))
        put("Smile", max(w[.mouthSmileLeft], w[.mouthSmileRight]))
        put("Press", max(w[.mouthPressLeft], w[.mouthPressRight], w[.mouthClose]))
        if visemes.isEmpty {
            // 외부 ARKit 신호(iPhone/카메라)만 있을 때: 조합에서 비셈을 근사
            put("JawOpen", w[.jawOpen])
            put("U", w[.mouthPucker])
            put("O", w[.mouthFunnel] * (1 - w[.mouthPucker]))
            put("I", max(w[.mouthStretchLeft], w[.mouthStretchRight]) * (1 - w[.jawOpen]))
            put("A", max(w[.mouthLowerDownLeft], w[.mouthLowerDownRight]) * w[.jawOpen])
        } else {
            // 비셈 합성 경로: 레거시 비셈 셰이프를 그대로 쓰고 턱은 ARKit jawOpen 의 일부만 보탠다
            for (k, v) in visemes { put(k, v) }
            put("JawOpen", w[.jawOpen] * 0.4)
        }
        return out
    }
}
