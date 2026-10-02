import Foundation
import RealityKit
import simd

/// `SplatPlaceholder_Bust.usdz` 를 **투명 목(mock) 데이터**로 읽어 만든 정면 깊이 템플릿.
///
/// 블렌더 흉상(단위 m, Y-up, 얼굴 +Z, 눈 y≈0.44·간격 0.064, 입 y≈0.357, 정수리 y≈0.566)을 정면에서 래스터화해
/// 셀마다 가장 앞쪽 z 를 기록한다. `SplatBuilder` 는 페르소나 사진의 눈 간격/눈 중심을 이 흉상 공간에 맞춰 놓고
/// 머리·목·어깨 굴곡을 여기서 읽어 스플랫 z 로 삼는다 (흉상 자체는 화면에 그리지 않는다).
nonisolated struct BustTemplate: Sendable {
    let width: Int
    let height: Int
    let minX: Float, maxX: Float
    let minY: Float, maxY: Float
    /// 행 우선(아래→위 = y 증가). 비어 있는 셀은 `.nan`.
    let depth: [Float]
    /// 행별 실루엣 반폭·가장자리 z (7행 박스 평활). 실루엣 밖 점을 뒤로 기울일 때 행 양자화 띠가 생기지 않게 보간해서 쓴다.
    let rowHalfWidth: [Float]
    let rowEdgeZ: [Float]

    init(width: Int, height: Int, minX: Float, maxX: Float, minY: Float, maxY: Float, depth: [Float]) {
        self.width = width; self.height = height
        self.minX = minX; self.maxX = maxX; self.minY = minY; self.maxY = maxY
        self.depth = depth
        let cell = (maxX - minX) / Float(max(1, width - 1))
        var hw = [Float](repeating: .nan, count: height)
        var ez = [Float](repeating: .nan, count: height)
        for row in 0..<height {
            var lo = Int.max, hi = Int.min
            for i in 0..<width where depth[row * width + i].isFinite { lo = min(lo, i); hi = max(hi, i) }
            guard lo <= hi else { continue }
            let half = Float(hi - lo) * cell / 2
            hw[row] = half
            // 가장자리에서 10% 안쪽의 z (경사가 완만한 곳) 좌우 평균
            let inset = max(1, Int(Float(hi - lo) * 0.05))
            let zl = depth[row * width + min(hi, lo + inset)], zr = depth[row * width + max(lo, hi - inset)]
            let zs = [zl, zr].filter { $0.isFinite }
            ez[row] = zs.isEmpty ? .nan : zs.reduce(0, +) / Float(zs.count)
        }
        func smooth(_ a: [Float]) -> [Float] {
            var out = a
            for i in a.indices {
                var s: Float = 0, n: Float = 0
                for d in -3...3 {
                    let j = i + d
                    guard j >= 0, j < a.count, a[j].isFinite else { continue }
                    s += a[j]; n += 1
                }
                out[i] = n > 0 ? s / n : .nan
            }
            return out
        }
        rowHalfWidth = smooth(hw)
        rowEdgeZ = smooth(ez)
    }

    /// 실루엣 가장자리 정보 (행 사이 선형 보간). y 가 범위 밖이면 가장 가까운 행.
    func edge(atY y: Float) -> (halfWidth: Float, z: Float)? {
        let fy = max(0, min(Float(height - 1), (y - minY) / (maxY - minY) * Float(height - 1)))
        let r0 = Int(fy), r1 = min(height - 1, r0 + 1), t = fy - Float(r0)
        let h0 = rowHalfWidth[r0], h1 = rowHalfWidth[r1], z0 = rowEdgeZ[r0], z1 = rowEdgeZ[r1]
        if h0.isFinite && h1.isFinite && z0.isFinite && z1.isFinite {
            return (h0 * (1 - t) + h1 * t, z0 * (1 - t) + z1 * t)
        }
        if h0.isFinite && z0.isFinite { return (h0, z0) }
        if h1.isFinite && z1.isFinite { return (h1, z1) }
        return nil
    }

    /// 흉상 공간 (x, y) 의 정면 z. 실루엣 밖이면 nil. 이웃 셀 쌍선형 보간.
    func z(x: Float, y: Float) -> Float? {
        guard x >= minX, x <= maxX, y >= minY, y <= maxY else { return nil }
        let fx = (x - minX) / (maxX - minX) * Float(width - 1)
        let fy = (y - minY) / (maxY - minY) * Float(height - 1)
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let z00 = depth[y0 * width + x0], z10 = depth[y0 * width + x1]
        let z01 = depth[y1 * width + x0], z11 = depth[y1 * width + x1]
        // 네 셀 중 유효한 것만 가중 평균
        var sum: Float = 0, wsum: Float = 0
        for (z, w) in [(z00, (1 - tx) * (1 - ty)), (z10, tx * (1 - ty)), (z01, (1 - tx) * ty), (z11, tx * ty)] where z.isFinite {
            sum += z * w; wsum += w
        }
        guard wsum > 0.3 else { return nil }
        return sum / wsum
    }

    /// 해당 y 높이에서 실루엣의 좌우 반폭 (어깨/머리 폭 비교용). 없으면 nil.
    func halfWidth(atY y: Float) -> Float? {
        guard y >= minY, y <= maxY else { return nil }
        let row = min(height - 1, max(0, Int((y - minY) / (maxY - minY) * Float(height - 1))))
        var lo = Int.max, hi = Int.min
        for i in 0..<width where depth[row * width + i].isFinite { lo = min(lo, i); hi = max(hi, i) }
        guard lo <= hi else { return nil }
        let cell = (maxX - minX) / Float(width - 1)
        return Float(hi - lo) * cell / 2
    }
}

/// 흉상 USDZ → 깊이 템플릿. 메인 액터에서 한 번 만들고 캐시한다 (RealityKit 메시 접근은 메인 액터).
@MainActor
enum BustTemplateLoader {
    private static var cached: BustTemplate?
    private static var inflight: Task<BustTemplate?, Never>?

    static func load() async -> BustTemplate? {
        if let cached { return cached }
        if let inflight { return await inflight.value }
        let task = Task<BustTemplate?, Never> {
            guard let bust = try? await FaceAssetLoader.shared.entity(named: "SplatPlaceholder_Bust") else { return nil }
            let tris = collectTriangles(bust)
            guard tris.count > 100 else { return nil }
            return await Self.rasterize(tris)
        }
        inflight = task
        let result = await task.value
        inflight = nil
        cached = result
        return result
    }

    /// 흉상 루트 공간의 삼각형 목록.
    private static func collectTriangles(_ root: Entity) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        root.forEachDescendant { e in
            guard let model = e.components[ModelComponent.self] else { return }
            let m = e.transformMatrix(relativeTo: root)
            for mesh in model.mesh.contents.models {
                for part in mesh.parts {
                    let pos = part.positions.elements
                    guard !pos.isEmpty else { continue }
                    let world = pos.map { p -> SIMD3<Float> in
                        let v = m * SIMD4(p, 1)
                        return SIMD3(v.x, v.y, v.z)
                    }
                    if let idx = part.triangleIndices?.elements, idx.count >= 3 {
                        out.reserveCapacity(out.count + idx.count)
                        var i = 0
                        while i + 2 < idx.count {
                            let a = Int(idx[i]), b = Int(idx[i + 1]), c = Int(idx[i + 2])
                            if a < world.count, b < world.count, c < world.count {
                                out.append(world[a]); out.append(world[b]); out.append(world[c])
                            }
                            i += 3
                        }
                    } else {
                        // 인덱스가 없으면 정점 자체를 점으로 (삼각형 퇴화)
                        for p in world { out.append(p); out.append(p); out.append(p) }
                    }
                }
            }
        }
        return out
    }

    /// 정면(+Z) 직교 투영 z-버퍼. 백그라운드에서 계산.
    @concurrent
    private static func rasterize(_ tris: [SIMD3<Float>]) async -> BustTemplate {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in tris { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let W = 192, H = 256
        var depth = [Float](repeating: .nan, count: W * H)
        let sx = Float(W - 1) / max(1e-4, hi.x - lo.x)
        let sy = Float(H - 1) / max(1e-4, hi.y - lo.y)
        var i = 0
        while i + 2 < tris.count {
            let a = tris[i], b = tris[i + 1], c = tris[i + 2]
            i += 3
            // 뒤를 보는 면(법선 z<0)은 건너뛴다 → 머리 뒷면이 앞면을 덮지 않음 (어차피 max 지만 비용 절약)
            let n = simd_cross(b - a, c - a)
            if n.z < 0 && simd_length_squared(n) > 1e-12 { continue }
            let ax = (a.x - lo.x) * sx, ay = (a.y - lo.y) * sy
            let bx = (b.x - lo.x) * sx, by = (b.y - lo.y) * sy
            let cx = (c.x - lo.x) * sx, cy = (c.y - lo.y) * sy
            let x0 = max(0, Int(floor(min(ax, bx, cx)))), x1 = min(W - 1, Int(ceil(max(ax, bx, cx))))
            let y0 = max(0, Int(floor(min(ay, by, cy)))), y1 = min(H - 1, Int(ceil(max(ay, by, cy))))
            let det = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
            if abs(det) < 1e-6 {
                // 퇴화 삼각형(점) → 셀 하나
                let xi = min(W - 1, max(0, Int(ax.rounded()))), yi = min(H - 1, max(0, Int(ay.rounded())))
                let k = yi * W + xi
                depth[k] = depth[k].isFinite ? max(depth[k], a.z) : a.z
                continue
            }
            for yi in y0...y1 {
                let py = Float(yi)
                for xi in x0...x1 {
                    let px = Float(xi)
                    var l0 = ((bx - px) * (cy - py) - (cx - px) * (by - py)) / det
                    var l1 = ((cx - px) * (ay - py) - (ax - px) * (cy - py)) / det
                    var l2 = 1 - l0 - l1
                    let eps: Float = -0.002
                    guard l0 >= eps, l1 >= eps, l2 >= eps else { continue }
                    l0 = max(0, l0); l1 = max(0, l1); l2 = max(0, l2)
                    let z = a.z * l0 + b.z * l1 + c.z * l2
                    let k = yi * W + xi
                    depth[k] = depth[k].isFinite ? max(depth[k], z) : z
                }
            }
        }
        // 작은 구멍 메우기 (이웃 평균 1회)
        var filled = depth
        for y in 0..<H {
            for x in 0..<W where !depth[y * W + x].isFinite {
                var s: Float = 0, n = 0
                for dy in -1...1 { for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < W, yy < H else { continue }
                    let v = depth[yy * W + xx]
                    if v.isFinite { s += v; n += 1 }
                } }
                if n >= 5 { filled[y * W + x] = s / Float(n) }
            }
        }
        return BustTemplate(width: W, height: H, minX: lo.x, maxX: hi.x, minY: lo.y, maxY: hi.y, depth: filled)
    }
}
