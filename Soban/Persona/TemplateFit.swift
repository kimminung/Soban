import Foundation
import simd

/// 2D 박판 스플라인(Thin-Plate Spline). 소수(≤ 60)의 대응점으로 평면을 부드럽게 휘는 사상 f: R² → R².
///
/// 커널 U(r) = r² log r², 정규화 λ 를 K 대각에 더해 랜드마크 잡음으로 접히는 것을 막는다.
/// 소반에서는 **사진 좌표(카드 m) → 흉상 템플릿 좌표**로 쓴다: 사진의 눈·눈썹·코·입·얼굴 윤곽이 흉상의 같은 부위에 가도록
/// 템플릿을 "휘어서" 깊이를 읽는다. 사진 픽셀은 그대로 두고 템플릿만 변형되는 셈이다.
nonisolated struct ThinPlateSpline: Sendable {
    let sources: [SIMD2<Float>]
    /// 비선형 가중치 (점마다 x,y)
    let weights: [SIMD2<Float>]
    /// 아핀 부분 a0 + a1·x + a2·y (x,y 각각)
    let affine: [SIMD2<Float>]   // [a0, a1, a2]

    /// - Parameters:
    ///   - source: 사진 쪽 점, target: 흉상 쪽 대응점 (같은 개수, ≥ 3개, 일직선 아님)
    ///   - lambda: 평활 정규화 (단위: 좌표²). 0 이면 보간, 클수록 아핀에 가까움.
    init?(source: [SIMD2<Float>], target: [SIMD2<Float>], lambda: Float = 0.002) {
        let n = source.count
        guard n >= 3, target.count == n else { return nil }
        // 시스템 행렬 L = [[K + λI, P], [Pᵀ, 0]] (크기 n+3)
        let m = n + 3
        var L = [Float](repeating: 0, count: m * m)
        func kernel(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            let r2 = simd_length_squared(a - b)
            return r2 > 1e-12 ? r2 * log(r2) : 0
        }
        for i in 0..<n {
            for j in 0..<n {
                L[i * m + j] = kernel(source[i], source[j]) + (i == j ? lambda : 0)
            }
            L[i * m + n] = 1
            L[i * m + n + 1] = source[i].x
            L[i * m + n + 2] = source[i].y
            L[n * m + i] = 1
            L[(n + 1) * m + i] = source[i].x
            L[(n + 2) * m + i] = source[i].y
        }
        // 우변: 목표 좌표 (x 열, y 열), 아래 3행은 0
        var bx = [Float](repeating: 0, count: m), by = [Float](repeating: 0, count: m)
        for i in 0..<n { bx[i] = target[i].x; by[i] = target[i].y }
        guard let wx = Self.solve(L, bx, m), let wy = Self.solve(L, by, m) else { return nil }
        sources = source
        weights = (0..<n).map { SIMD2(wx[$0], wy[$0]) }
        affine = (0..<3).map { SIMD2(wx[n + $0], wy[n + $0]) }
    }

    func map(_ p: SIMD2<Float>) -> SIMD2<Float> {
        var out = affine[0] + affine[1] * p.x + affine[2] * p.y
        for (s, w) in zip(sources, weights) {
            let r2 = simd_length_squared(p - s)
            if r2 > 1e-12 { out += w * (r2 * log(r2)) }
        }
        return out
    }

    /// 부분 피벗 가우스 소거. 작은 시스템(≤ 64) 전용.
    private static func solve(_ A: [Float], _ b: [Float], _ n: Int) -> [Float]? {
        var a = A, x = b
        for col in 0..<n {
            var pivot = col
            var best = abs(a[col * n + col])
            for r in (col + 1)..<n where abs(a[r * n + col]) > best { best = abs(a[r * n + col]); pivot = r }
            guard best > 1e-9 else { return nil }
            if pivot != col {
                for c in 0..<n { a.swapAt(col * n + c, pivot * n + c) }
                x.swapAt(col, pivot)
            }
            let d = a[col * n + col]
            for r in (col + 1)..<n {
                let f = a[r * n + col] / d
                guard f != 0 else { continue }
                for c in col..<n { a[r * n + c] -= f * a[col * n + c] }
                x[r] -= f * x[col]
            }
        }
        for col in stride(from: n - 1, through: 0, by: -1) {
            var s = x[col]
            for c in (col + 1)..<n { s -= a[col * n + c] * x[c] }
            x[col] = s / a[col * n + col]
        }
        return x
    }
}

/// 흉상 템플릿을 **사진에 맞춰 변형**하는 사상 (카드 m → 흉상 공간).
///
/// - 얼굴 안: Vision 76점 랜드마크(눈·눈썹·코·입·얼굴 윤곽) ↔ 흉상 대응점 TPS
/// - 얼굴 밖(목·어깨·머리카락): 인물 마스크의 행별 실루엣 폭 ↔ 흉상 실루엣 폭을 맞춰 가로를 늘이고 줄임
/// - 두 사상은 얼굴 타원 가장자리에서 부드럽게 섞는다
nonisolated struct TemplateFit: Sendable {
    /// 사진 행별 실루엣 (카드 m): 중심 x, 반폭. 빈 행은 nan.
    struct Row: Sendable { var centerX: Float; var halfWidth: Float }

    let template: BustTemplate
    let k: Float                      // 흉상 단위 / 카드 m (눈 간격 기준)
    let eyeMid: SIMD2<Float>
    let tps: ThinPlateSpline?
    let rows: [Row]
    let rowMinY: Float, rowMaxY: Float
    /// 얼굴 타원 (TPS ↔ 행 맞춤 블렌딩 기준)
    let faceCenter: SIMD2<Float>
    let faceAxes: SIMD2<Float>
    let chinYBust: Float
    let noseYBust: Float
    let correspondenceCount: Int

    /// - Parameters:
    ///   - alphaRow: 카드 행(y, m) → 불투명 픽셀 범위 (xMin, xMax) in m. nil 이면 빈 행.
    init(template: BustTemplate, rig: FaceRig?, cardSize: SIMD2<Float>, rowCount: Int,
         alphaRow: (Float) -> (Float, Float)?) {
        self.template = template
        let cardW = cardSize.x, cardH = cardSize.y
        func local(_ p: NPoint) -> SIMD2<Float> { SIMD2(Float(p.x - 0.5) * cardW, Float(0.5 - p.y) * cardH) }
        func localMid(_ r: NRect) -> SIMD2<Float> { SIMD2(Float(r.midX - 0.5) * cardW, Float(0.5 - r.midY) * cardH) }

        // 흉상 쪽 기준점 (템플릿에서 측정)
        chinYBust = template.chinY
        noseYBust = template.noseY
        let eyeYB = FaceKitSex.eyeHeight, eyeXB = FaceKitSex.eyeSpacing / 2
        let mouthYB = FaceKitSex.mouthHeight

        // 눈 중심/간격 → 전역 스케일
        var mid = SIMD2<Float>(0, cardH * 0.2)
        var dist = cardW * 0.12
        if let rig {
            let l = localMid(rig.leftEye), r = localMid(rig.rightEye)
            mid = (l + r) / 2
            dist = max(0.02, abs(r.x - l.x))
        }
        eyeMid = mid
        k = FaceKitSex.eyeSpacing / dist

        // 행별 실루엣
        var rs: [Row] = []
        rs.reserveCapacity(rowCount)
        rowMinY = -cardH / 2; rowMaxY = cardH / 2
        for i in 0..<rowCount {
            let y = rowMinY + (Float(i) + 0.5) / Float(rowCount) * cardH
            if let (x0, x1) = alphaRow(y), x1 > x0 + 0.004 {
                rs.append(Row(centerX: (x0 + x1) / 2, halfWidth: (x1 - x0) / 2))
            } else {
                rs.append(Row(centerX: .nan, halfWidth: .nan))
            }
        }
        rows = rs

        // TPS 대응점
        var src: [SIMD2<Float>] = [], dst: [SIMD2<Float>] = []
        if let rig {
            let l = localMid(rig.leftEye), r = localMid(rig.rightEye)
            let leftIsLeft = l.x < r.x
            // 눈 (사진에서 x 가 작은 눈 → 흉상 −x)
            src.append(leftIsLeft ? l : r); dst.append(SIMD2(-eyeXB, eyeYB))
            src.append(leftIsLeft ? r : l); dst.append(SIMD2(eyeXB, eyeYB))
            // 눈썹 (있으면)
            if let lb = rig.leftBrow, let rb = rig.rightBrow {
                let lbm = localMid(lb), rbm = localMid(rb)
                let browYB = eyeYB + 0.022
                src.append(lbm.x < rbm.x ? lbm : rbm); dst.append(SIMD2(-eyeXB, browYB))
                src.append(lbm.x < rbm.x ? rbm : lbm); dst.append(SIMD2(eyeXB, browYB))
            }
            // 코끝
            src.append(local(rig.noseTip)); dst.append(SIMD2(0, noseYBust))
            // 입 중심 + 양 끝
            let m = localMid(rig.mouth)
            let halfMouth = Float(rig.mouth.width) * cardW / 1.24 / 2
            src.append(m); dst.append(SIMD2(0, mouthYB))
            src.append(SIMD2(m.x - halfMouth, m.y)); dst.append(SIMD2(-0.025, mouthYB))
            src.append(SIMD2(m.x + halfMouth, m.y)); dst.append(SIMD2(0.025, mouthYB))
            // 얼굴 윤곽: 높이 비율 t(눈=0, 턱=1) 로 흉상 실루엣 가장자리에 대응
            if let contour = rig.contour, contour.count >= 5 {
                let pts = contour.map(local)
                let chinY = pts.map(\.y).min() ?? (mid.y - dist * 2.2)
                let eyeY = mid.y
                let span = max(0.02, eyeY - chinY)
                // 윤곽 점이 많으면 ~12개로 솎는다
                let step = max(1, pts.count / 12)
                var i = 0
                while i < pts.count {
                    let p = pts[i]
                    i += step
                    let t = max(-0.15, min(1, (eyeY - p.y) / span))
                    let by = eyeYB - t * (eyeYB - chinYBust)
                    guard let edge = template.edge(atY: by) else { continue }
                    // 관자놀이(눈 높이)는 귀 안쪽이므로 0.9, 턱 쪽은 0.98
                    let factor = 0.9 + 0.08 * max(0, t)
                    let sx: Float = p.x < mid.x ? -1 : 1
                    src.append(p); dst.append(SIMD2(sx * edge.halfWidth * factor, by))
                }
            }
        }
        correspondenceCount = src.count
        tps = src.count >= 6 ? ThinPlateSpline(source: src, target: dst, lambda: 0.002) : nil

        // 얼굴 타원 (블렌딩용)
        if let rig {
            let fb = rig.faceBox
            let fc = SIMD2(Float(fb.midX - 0.5) * cardW, Float(0.5 - fb.midY) * cardH)
            faceCenter = fc
            faceAxes = SIMD2(Float(fb.width) * cardW * 0.5 * 1.1, Float(fb.height) * cardH * 0.5 * 1.1)
        } else {
            faceCenter = mid
            faceAxes = SIMD2(dist * 1.6, dist * 2.2)
        }
    }

    /// 눈 간격 기준 아핀 사상 (예비).
    func affine(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2((p.x - eyeMid.x) * k, FaceKitSex.eyeHeight + (p.y - eyeMid.y) * k)
    }

    /// 행별 실루엣 폭 맞춤: 사진 행의 (중심, 반폭) 을 흉상 같은 높이의 실루엣 반폭으로.
    func rowFit(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let by = FaceKitSex.eyeHeight + (p.y - eyeMid.y) * k
        guard !rows.isEmpty else { return affine(p) }
        let fi = (p.y - rowMinY) / max(1e-4, rowMaxY - rowMinY) * Float(rows.count)
        let i = min(rows.count - 1, max(0, Int(fi)))
        let row = rows[i]
        guard row.halfWidth.isFinite, row.halfWidth > 0.01,
              let edge = template.edge(atY: min(template.maxY, max(template.minY, by))), edge.halfWidth > 0.005 else {
            return affine(p)
        }
        // 흉상 실루엣보다 사진이 넓은 행(머리카락·어깨)은 그대로 늘려서 끝이 가장자리 밖으로 나가게 둔다 (뒤로 기울어짐)
        let u = (p.x - row.centerX) / row.halfWidth            // −1…1
        let ratio = min(1.6, max(0.6, (row.halfWidth * k) / edge.halfWidth))  // 폭 비율 과대/과소 제한
        let bx = u * edge.halfWidth * ratio
        return SIMD2(bx, by)
    }

    /// 최종 사상: 얼굴 안은 TPS, 밖은 행 맞춤, 경계는 블렌딩.
    func map(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let row = rowFit(p)
        guard let tps else { return row }
        let d = simd_length((p - faceCenter) / faceAxes)
        if d >= 1.4 { return row }
        let face = tps.map(p)
        if d <= 1.0 { return face }
        let w = (1.4 - d) / 0.4            // 1 → 0
        let s = w * w * (3 - 2 * w)        // smoothstep
        return face * s + row * (1 - s)
    }
}

extension BustTemplate {
    /// 턱 끝 y: 목(최소 반폭) 위에서 반폭이 목의 1.25배가 되는 첫 행. 못 찾으면 0.295 (인체 비례).
    var chinY: Float {
        let cell = (maxY - minY) / Float(max(1, height - 1))
        func rowIndex(_ y: Float) -> Int { min(height - 1, max(0, Int((y - minY) / cell))) }
        let r0 = rowIndex(0.20), r1 = rowIndex(0.36)
        guard r1 > r0 else { return 0.295 }
        var neck: Float = .greatestFiniteMagnitude, neckRow = r0
        for r in r0...r1 where rowHalfWidth[r].isFinite && rowHalfWidth[r] < neck { neck = rowHalfWidth[r]; neckRow = r }
        guard neck.isFinite else { return 0.295 }
        for r in neckRow...min(height - 1, rowIndex(0.42)) where rowHalfWidth[r].isFinite && rowHalfWidth[r] > neck * 1.25 {
            return minY + Float(r) * cell
        }
        return 0.295
    }

    /// 코끝 y: x=0 에서 0.37…0.43 사이 가장 앞(z 최대)인 행. 못 찾으면 0.40.
    var noseY: Float {
        var best: (y: Float, z: Float)?
        var y: Float = 0.37
        while y <= 0.43 {
            if let z = self.z(x: 0, y: y), best == nil || z > best!.z { best = (y, z) }
            y += 0.004
        }
        return best?.y ?? 0.40
    }
}
