import Foundation
import simd

/// 가우시안 스플랫 하나. 위치(m, 카드 좌표계: x 오른쪽, y 위, z 뷰어 쪽), 색, 불투명도, 반지름(m).
nonisolated struct Splat: Sendable, Hashable {
    var position: SIMD3<Float>
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8
    var scale: Float
}

/// 페르소나 한 명의 스플랫 클라우드 + 입/눈 오버레이가 표면에 붙도록 쓰는 저해상도 부조(relief) 그리드.
///
/// 생성 방식은 **깊이/부조 초기화형 가우시안 스플랫**이다: 깊이 맵(또는 얼굴 리그로 맞춘 머리 타원체)에서 3D 점을 만들고
/// 각 점을 색·불투명도·크기를 가진 2D 가우시안으로 초기화한다. 3DGS 논문처럼 미분 가능한 최적화(학습)는 하지 않는다
/// (Apple 공개 API 없음). 표준 3DGS PLY 로 내보낼 수 있어 외부 스플랫 뷰어에서 열린다.
nonisolated struct SplatCloud: Sendable {
    static let magic: UInt32 = 0x5053_4253 // "SBSP"
    static let version: UInt32 = 1

    var cardWidth: Float
    var cardHeight: Float
    var reliefWidth: Int
    var reliefHeight: Int
    /// 행 우선, 좌상단 원점. 해당 셀의 최대 z (뷰어 쪽이 +).
    var relief: [Float]
    var splats: [Splat]

    var count: Int { splats.count }

    /// 정규화 (u,v) 위치의 표면 z.
    func surfaceZ(u: Double, v: Double) -> Float {
        guard reliefWidth > 0, reliefHeight > 0 else { return 0 }
        let x = min(reliefWidth - 1, max(0, Int(u * Double(reliefWidth))))
        let y = min(reliefHeight - 1, max(0, Int(v * Double(reliefHeight))))
        let z = relief[y * reliefWidth + x]
        return z.isFinite ? z : 0
    }

    // MARK: - Binary

    func encode() -> Data {
        var data = Data()
        data.reserveCapacity(32 + relief.count * 4 + splats.count * 20)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        put(Self.magic); put(Self.version)
        put(UInt32(splats.count))
        put(cardWidth); put(cardHeight)
        put(UInt32(reliefWidth)); put(UInt32(reliefHeight))
        for z in relief { put(z) }
        for s in splats {
            put(s.position.x); put(s.position.y); put(s.position.z)
            data.append(contentsOf: [s.r, s.g, s.b, s.a])
            put(s.scale)
        }
        return data
    }

    init(cardWidth: Float, cardHeight: Float, reliefWidth: Int, reliefHeight: Int, relief: [Float], splats: [Splat]) {
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.reliefWidth = reliefWidth
        self.reliefHeight = reliefHeight
        self.relief = relief
        self.splats = splats
    }

    init?(data: Data) {
        var offset = 0
        func get<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            let v = data.withUnsafeBytes { raw in raw.loadUnaligned(fromByteOffset: offset, as: T.self) }
            offset += size
            return v
        }
        guard get(UInt32.self) == Self.magic, get(UInt32.self) == Self.version,
              let count = get(UInt32.self), let cw = get(Float.self), let ch = get(Float.self),
              let rw = get(UInt32.self), let rh = get(UInt32.self) else { return nil }
        let reliefCount = Int(rw) * Int(rh)
        var relief: [Float] = []
        relief.reserveCapacity(reliefCount)
        for _ in 0..<reliefCount { guard let z = get(Float.self) else { return nil }; relief.append(z) }
        var splats: [Splat] = []
        splats.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
            guard let x = get(Float.self), let y = get(Float.self), let z = get(Float.self),
                  offset + 4 <= data.count else { return nil }
            let r = data[data.startIndex + offset], g = data[data.startIndex + offset + 1],
                b = data[data.startIndex + offset + 2], a = data[data.startIndex + offset + 3]
            offset += 4
            guard let scale = get(Float.self) else { return nil }
            splats.append(Splat(position: SIMD3(x, y, z), r: r, g: g, b: b, a: a, scale: scale))
        }
        self.init(cardWidth: cw, cardHeight: ch, reliefWidth: Int(rw), reliefHeight: Int(rh), relief: relief, splats: splats)
    }

    // MARK: - 3DGS PLY export

    /// 표준 3D Gaussian Splatting PLY (binary little endian). SuperSplat 등 외부 뷰어에서 열린다.
    func plyData() -> Data {
        var header = "ply\nformat binary_little_endian 1.0\nelement vertex \(splats.count)\n"
        for p in ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
                  "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"] {
            header += "property float \(p)\n"
        }
        header += "end_header\n"
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + splats.count * 17 * 4)
        let sh0: Float = 0.28209479177387814
        func put(_ v: Float) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        for s in splats {
            // 3DGS 는 y 아래가 양수인 경우가 많아 뷰어마다 다르다. 여기서는 Y-up, Z 는 뷰어 쪽(+) 그대로 둔다.
            put(s.position.x); put(s.position.y); put(s.position.z)
            put(0); put(0); put(1)
            put((Float(s.r) / 255 - 0.5) / sh0); put((Float(s.g) / 255 - 0.5) / sh0); put((Float(s.b) / 255 - 0.5) / sh0)
            let alpha = min(0.999, max(0.001, Float(s.a) / 255))
            put(log(alpha / (1 - alpha)))
            let ls = log(max(1e-4, s.scale))
            put(ls); put(ls); put(ls * 0.6)
            put(1); put(0); put(0); put(0)
        }
        return data
    }
}
