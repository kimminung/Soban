import Foundation

/// Persona 등록처럼 "정면 → 한쪽 → 반대쪽 → 살짝 위" 순서로 각도를 안내하고,
/// 조건이 0.7초 이상 유지되면 촬영을 요청하는 작은 상태 기계. 플랫폼 독립.
nonisolated enum CaptureAngle: String, CaseIterable, Codable, Sendable {
    case center, sideA, sideB, up

    var title: String {
        switch self {
        case .center: "정면"
        case .sideA: "한쪽으로"
        case .sideB: "반대쪽으로"
        case .up: "살짝 위로"
        }
    }

    var instruction: String {
        switch self {
        case .center: "카메라를 똑바로 바라보세요"
        case .sideA: "고개를 한쪽으로 천천히 돌리세요"
        case .sideB: "이번엔 반대쪽으로 돌리세요"
        case .up: "턱을 살짝 들어 위를 보세요"
        }
    }

    /// 패키지 side-view 키.
    var sideViewKey: String? {
        switch self {
        case .center: nil
        case .sideA: "sideA"
        case .sideB: "sideB"
        case .up: "up"
        }
    }
}

nonisolated struct CaptureGuide: Sendable, Equatable {
    nonisolated enum Phase: Equatable, Sendable {
        case idle
        case waiting(CaptureAngle)     // 조건을 기다리는 중
        case holding(CaptureAngle, Double) // 조건 충족, 0…1 진행
        case capturing(CaptureAngle)
        case done
    }

    var phase: Phase = .idle
    var completed: Set<CaptureAngle> = []
    /// 첫 측면 촬영에서 결정된 yaw 부호. 반대쪽은 이 부호의 반대여야 한다.
    var sideASign: Double?
    private var holdStart: Double?
    private var lastFaceAt: Double = 0

    static let holdSeconds = 0.7
    static let order: [CaptureAngle] = [.center, .sideA, .sideB, .up]

    var current: CaptureAngle? {
        switch phase {
        case .waiting(let a), .holding(let a, _), .capturing(let a): a
        default: nil
        }
    }

    var progressText: String {
        "\(completed.count) / \(Self.order.count)"
    }

    mutating func start() {
        phase = .waiting(.center)
        completed = []
        sideASign = nil
        holdStart = nil
    }

    mutating func reset() {
        phase = .idle
        completed = []
        sideASign = nil
        holdStart = nil
    }

    /// 매 프레임 호출. 얼굴이 없으면 yaw/pitch nil. 반환값이 true 면 촬영을 시작해야 한다.
    mutating func update(yaw: Double?, pitch: Double?, now: Double) -> Bool {
        guard let angle = current, case let p = phase, p != .capturing(angle) else { return false }
        guard let yaw, let pitch else {
            holdStart = nil
            phase = .waiting(angle)
            return false
        }
        lastFaceAt = now
        let ok: Bool
        switch angle {
        case .center:
            ok = abs(yaw) < 8 && abs(pitch) < 10
        case .sideA:
            ok = abs(yaw) >= 14 && abs(yaw) <= 45 && abs(pitch) < 18
        case .sideB:
            if let sign = sideASign {
                ok = abs(yaw) >= 14 && abs(yaw) <= 45 && (yaw.sign == .minus ? -1.0 : 1.0) != sign && abs(pitch) < 18
            } else {
                ok = abs(yaw) >= 14 && abs(yaw) <= 45
            }
        case .up:
            ok = abs(pitch) >= 9 && abs(pitch) <= 35 && abs(yaw) < 14
        }
        guard ok else {
            holdStart = nil
            phase = .waiting(angle)
            return false
        }
        let start = holdStart ?? now
        holdStart = start
        let t = min(1, (now - start) / Self.holdSeconds)
        if t >= 1 {
            if angle == .sideA { sideASign = yaw.sign == .minus ? -1 : 1 }
            phase = .capturing(angle)
            holdStart = nil
            return true
        }
        phase = .holding(angle, t)
        return false
    }

    /// 촬영이 끝났을 때 호출.
    mutating func didCapture(_ angle: CaptureAngle) {
        completed.insert(angle)
        if let next = Self.order.first(where: { !completed.contains($0) }) {
            phase = .waiting(next)
        } else {
            phase = .done
        }
    }

    /// 촬영 실패 시 같은 단계로 되돌린다.
    mutating func captureFailed(_ angle: CaptureAngle) {
        phase = .waiting(angle)
    }

    /// 특정 단계를 건너뛴다(예: 위쪽 각도가 잘 안 될 때).
    mutating func skipCurrent() {
        guard let angle = current else { return }
        didCapture(angle)
        completed.remove(angle)
        if phase == .done || !Self.order.contains(where: { !completed.contains($0) && $0 != angle }) {
            phase = .done
        }
    }
}
