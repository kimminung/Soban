import Foundation
import simd

/// 혼자서도 상이 북적이도록 자리를 채우는 데모 손님의 "두뇌".
/// 번갈아 말하고, 고개를 끄덕이고, 가끔 반응을 보낸다.
nonisolated struct BotBrain: Sendable {
    var seed: Float
    var speakingUntil: Double = 0
    var nextTurnAt: Double
    var nextReactionAt: Double
    var gestureUntil: Double = 0
    /// TTS 목소리 높낮이 (손님마다 다르게).
    var pitch: Float
    /// 실제 음성의 50ms 레벨 엔벨로프. 비어 있으면 합성 엔벨로프를 쓴다.
    var envelope: [Float] = []
    var envelopeHop: Double = 0.05
    var turnStart: Double = 0

    init(index: Int, now: Double) {
        seed = Float(index) * 1.37 + 0.5
        nextTurnAt = now + Double(index) * 2.5 + 1.0
        nextReactionAt = now + Double.random(in: 6...14)
        pitch = [1.0, 0.82, 1.22, 0.92, 1.1][index % 5]
    }

    var isSpeaking: Bool { speakingUntil > 0 }

    /// 호스트(세션)가 "지금 말할 차례" 를 주면 호출.
    mutating func beginTurn(now: Double, duration: Double, envelope: [Float] = [], hop: Double = 0.05) {
        speakingUntil = now + duration
        turnStart = now
        self.envelope = envelope
        envelopeHop = hop
    }

    mutating func pose(at now: Double) -> (PersonaPose, Float) {
        var p = PersonaPose()
        let t = Float(now)
        let speaking = now < speakingUntil
        if !speaking { speakingUntil = 0 }

        // 듣는 중: 느린 고갯짓. 말하는 중: 조금 더 활발
        let energy: Float = speaking ? 1.0 : 0.45
        p.yaw = 0.18 * sin(t * 0.55 + seed) * energy + 0.05 * sin(t * 1.7 + seed * 2)
        p.pitch = 0.08 * sin(t * 0.9 + seed * 3) * energy + (speaking ? 0.04 * sin(t * 3.1) : 0)
        p.roll = 0.05 * sin(t * 0.4 + seed)
        p.offset = SIMD3(0.02 * sin(t * 0.3 + seed), 0.01 * sin(t * 0.8 + seed), 0.03 * sin(t * 0.25))

        var level: Float = 0
        if speaking {
            if !envelope.isEmpty {
                // 실제 TTS 음성과 동기화된 입 모양
                let idx = Int((now - turnStart) / envelopeHop)
                level = idx >= 0 && idx < envelope.count ? min(1, envelope[idx] * 1.15) : 0
            } else {
                // 음절 느낌의 합성 엔벨로프
                let syllable = max(0, sin(t * 11 + seed * 5)) * (0.55 + 0.45 * sin(t * 2.3 + seed))
                let pause = sin(t * 0.7 + seed * 2) > -0.4 ? 1 : Float(0)
                level = min(1, syllable * pause)
            }
            p.mouth = level
            p.speaking = true
        }

        // 가끔 손을 들어 보이는 제스처
        if now < gestureUntil {
            let k = Float(min(1, (gestureUntil - now) / 1.2))
            p.rightHand = SIMD3(0.28, 0.12 + 0.05 * sin(t * 6) * k, -0.25)
            p.handRaised = p.rightHand!.y > 0.08
        }
        return (p, level)
    }

    mutating func maybeReaction(at now: Double) -> Reaction? {
        guard now >= nextReactionAt else { return nil }
        nextReactionAt = now + Double.random(in: 9...22)
        if Bool.random() { gestureUntil = now + 2.2 }
        return Reaction.allCases.randomElement()
    }
}
