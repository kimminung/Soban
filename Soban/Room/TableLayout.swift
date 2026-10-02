import Foundation
import simd

/// 둥근 두레반(좌식 원탁) 주위 6자리 배치. 슬롯 0 은 항상 "나"(뷰어 쪽, +z).
nonisolated struct TableLayout: Sendable, Equatable {
    static let seatCount = 6

    /// 테이블 중심(바닥 높이). 이머시브 공간 원점은 사용자의 발밑.
    var center: SIMD3<Float>
    var seatRadius: Float = 1.05
    var tableRadius: Float = 0.62
    var tableHeight: Float = 0.30
    var cushionRadius: Float = 0.25
    /// 페르소나 카드 아랫변이 뜨는 높이.
    var personaBaseY: Float = 0.34

    init(distance: Float = 1.05) {
        center = SIMD3(0, 0, -distance)
    }

    var distance: Float { -center.z }

    /// 슬롯 각도. 0 번이 +z(뷰어 쪽), 반시계 방향으로 증가.
    func angle(slot: Int) -> Float {
        .pi / 2 + Float(slot) * (2 * .pi / Float(Self.seatCount))
    }

    func seatPosition(slot: Int) -> SIMD3<Float> {
        let a = angle(slot: slot)
        return center + SIMD3(cos(a) * seatRadius, 0, sin(a) * seatRadius)
    }

    /// 카드 중심 위치.
    func personaPosition(slot: Int, cardHeight: Float) -> SIMD3<Float> {
        var p = seatPosition(slot: slot)
        p.y = personaBaseY + cardHeight / 2
        return p
    }

    func cupPosition(slot: Int) -> SIMD3<Float> {
        let a = angle(slot: slot)
        return center + SIMD3(cos(a) * (tableRadius - 0.14), tableHeight + 0.0175 + 0.0225, sin(a) * (tableRadius - 0.14))
    }

    /// "내 모습 보기" 거울 아바타 위치: 내 자리 오른쪽 위, 테이블 안쪽으로 살짝.
    func mirrorPosition(cardHeight: Float, scale: Float) -> SIMD3<Float> {
        let a = angle(slot: 0) - 0.62
        let r = seatRadius * 0.8
        return center + SIMD3(cos(a) * r, personaBaseY + 0.45 + cardHeight * scale / 2, sin(a) * r)
    }

    /// 전역 좌석 번호를 내 좌석 기준 렌더 슬롯으로.
    static func slot(forSeat seat: Int, mySeat: Int) -> Int {
        ((seat - mySeat) % seatCount + seatCount) % seatCount
    }
}
