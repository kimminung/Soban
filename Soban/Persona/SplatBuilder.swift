import Foundation
import CoreGraphics
import simd
import Vision

/// 페르소나 패키지(정면 카드 + 깊이 + 측면 사진)에서 가우시안 스플랫 클라우드를 만든다.
///
/// 1. 카드의 불투명 픽셀을 ~3만 개가 되도록 격자 샘플링
/// 2. z: 깊이 맵이 있으면 `depth.png` 를 미터로 되돌려 얼굴 중앙값 기준 상대 깊이, 없으면 얼굴 리그로 맞춘 **머리 타원체 + 몸통 반원기둥** 부조
/// 3. 측면 사진이 있으면 코 위치로 회전각을 추정해 머리 옆면(법선이 옆을 보는 스플랫)의 색을 측면 사진에서 샘플
/// 4. 뒤→앞 정렬(알파 블렌딩용), 부조 그리드 기록
nonisolated enum SplatBuilder {
    nonisolated struct Progress: Sendable, Equatable {
        var step: Int
        var total: Int
        var message: String
    }

    nonisolated enum BuildError: LocalizedError {
        case decodeFailed
        var errorDescription: String? { "카드 이미지를 읽을 수 없습니다." }
    }

    static let targetCount = 30_000
    static let maxCount = 36_000

    @concurrent
    static func build(from package: PersonaPackage,
                      progress: @escaping @Sendable (Progress) -> Void) async throws -> SplatCloud {
        progress(Progress(step: 1, total: 4, message: "카드를 3D 점으로 펼치는 중"))
        guard let image = PersonaBuilder.decodeImage(package.bodyPNG) else { throw BuildError.decodeFailed }
        let raster = try RGBARaster(cgImage: image)
        let m = package.manifest
        let cardW = m.cardWidthMeters, cardH = m.cardHeightMeters
        let W = raster.width, H = raster.height

        // 얼굴 기하 (미터, 카드 중심 원점)
        let face = m.face
        let faceBox = face?.faceBox ?? NRect(x: 0.3, y: 0.08, width: 0.4, height: 0.42)
        let cx = Float(faceBox.midX - 0.5) * cardW
        let cy = Float(0.5 - faceBox.midY) * cardH
        let a = Float(faceBox.width) * cardW * 0.62      // 머리 반폭 (머리카락 포함)
        let b = Float(faceBox.height) * cardH * 0.72     // 머리 반높이
        let rz = a * 0.95                                 // 머리 반깊이
        let torsoHalf = cardW * 0.5
        let neckY = cy - b * 0.9

        // 깊이 맵 (있으면)
        var depthRaster: RGBARaster?
        var depthFace: Float = 0
        var near: Float = 0, far: Float = 1
        if let dpng = package.depthPNG, let dimg = PersonaBuilder.decodeImage(dpng), let dr = try? RGBARaster(cgImage: dimg),
           let n = m.depthNearMeters, let f = m.depthFarMeters, f > n {
            depthRaster = dr
            near = n; far = f
            // 얼굴 박스 안 깊이 중앙값
            var vals: [Float] = []
            let x0 = Int(faceBox.x * Double(dr.width)), x1 = Int((faceBox.x + faceBox.width) * Double(dr.width))
            let y0 = Int(faceBox.y * Double(dr.height)), y1 = Int((faceBox.y + faceBox.height) * Double(dr.height))
            var yy = max(0, y0)
            while yy < min(dr.height, y1) {
                var xx = max(0, x0)
                while xx < min(dr.width, x1) {
                    let t = Float(dr.bytes[(yy * dr.width + xx) * 4]) / 255
                    if t > 0.02 { vals.append(far - t * (far - near)) }
                    xx += max(1, (x1 - x0) / 20)
                }
                yy += max(1, (y1 - y0) / 20)
            }
            vals.sort()
            depthFace = vals.isEmpty ? (near + far) / 2 : vals[vals.count / 2]
            if vals.count < 10 { depthRaster = nil }
        }

        func depthZ(u: Double, v: Double) -> Float? {
            guard let dr = depthRaster else { return nil }
            let x = min(dr.width - 1, max(0, Int(u * Double(dr.width))))
            let y = min(dr.height - 1, max(0, Int(v * Double(dr.height))))
            let t = Float(dr.bytes[(y * dr.width + x) * 4]) / 255
            guard t > 0.02 else { return nil }
            let d = far - t * (far - near)
            return max(-0.22, min(0.14, depthFace - d))
        }

        /// 부조 모델: 머리 타원체 + 몸통. 법선도 함께.
        func reliefZ(x: Float, y: Float) -> (z: Float, n: SIMD3<Float>) {
            let ex = (x - cx) / a, ey = (y - cy) / b
            let e2 = ex * ex + ey * ey
            if e2 < 1 {
                let z = rz * sqrt(1 - e2)
                let n = simd_normalize(SIMD3(ex / a, ey / b, z / (rz * rz)))
                return (z, n)
            }
            // 목/몸통: 반원기둥, 어깨로 갈수록 뒤로
            let tx = max(-1, min(1, (x - cx) / torsoHalf))
            var z = rz * 0.55 * sqrt(max(0, 1 - tx * tx))
            if y > neckY { // 머리 타원 바깥의 머리 주변(머리카락 끝) 은 얕게
                z *= 0.5
            }
            let shoulderFade = max(0, min(1, (neckY - y) / max(0.05, cardH * 0.25)))
            z *= 1 - 0.25 * shoulderFade
            return (z, simd_normalize(SIMD3(tx * 0.8, 0, 1)))
        }

        // 샘플링 간격
        var opaque = 0
        for i in stride(from: 3, to: raster.bytes.count, by: 16) where raster.bytes[i] > 40 { opaque += 1 }
        opaque *= 4
        let stride = max(1, Int((Double(opaque) / Double(targetCount)).squareRoot().rounded(.up)))
        let pixelMeters = cardW / Float(W)
        let baseScale = pixelMeters * Float(stride) * 0.9

        var splats: [Splat] = []
        splats.reserveCapacity(min(maxCount, opaque / (stride * stride) + 100))
        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(splats.capacity)

        let reliefW = 48, reliefH = 64
        var relief = [Float](repeating: -1, count: reliefW * reliefH)

        var y = stride / 2
        while y < H {
            var x = stride / 2
            while x < W {
                let i = (y * W + x) * 4
                let alpha = raster.bytes[i + 3]
                if alpha > 40 {
                    let u = (Double(x) + 0.5) / Double(W), v = (Double(y) + 0.5) / Double(H)
                    let px = Float(u - 0.5) * cardW, py = Float(0.5 - v) * cardH
                    let rel = reliefZ(x: px, y: py)
                    let z = depthZ(u: u, v: v) ?? rel.z
                    // premultiplied → straight
                    let af = Float(alpha) / 255
                    let r = UInt8(min(255, Float(raster.bytes[i]) / af))
                    let g = UInt8(min(255, Float(raster.bytes[i + 1]) / af))
                    let bch = UInt8(min(255, Float(raster.bytes[i + 2]) / af))
                    // 가장자리는 조금 작게·투명하게
                    let edge = alpha < 200 ? Float(alpha) / 200 : 1
                    splats.append(Splat(position: SIMD3(px, py, z), r: r, g: g, b: bch,
                                        a: UInt8(min(255, 235 * edge + 20)), scale: baseScale * (0.75 + 0.35 * edge)))
                    normals.append(rel.n)
                    let rx = min(reliefW - 1, Int(u * Double(reliefW))), ry = min(reliefH - 1, Int(v * Double(reliefH)))
                    relief[ry * reliefW + rx] = max(relief[ry * reliefW + rx], z)
                    if splats.count >= maxCount { break }
                }
                x += stride
            }
            if splats.count >= maxCount { break }
            y += stride
        }
        // 비어 있는 부조 셀은 이웃 평균으로
        for idx in relief.indices where relief[idx] < 0 { relief[idx] = 0 }

        // 측면 융합
        if !package.sideViews.isEmpty {
            progress(Progress(step: 2, total: 4, message: "측면 사진으로 옆면 색을 채우는 중"))
            await fuseSides(package.sideViews, into: &splats, normals: normals, headCenter: SIMD3(cx, cy, 0),
                            headAxes: SIMD3(a, b, rz), frontalFace: faceBox, cardSize: SIMD2(cardW, cardH))
        }

        progress(Progress(step: 3, total: 4, message: "뒤에서 앞으로 정렬하는 중"))
        splats.sort { $0.position.z < $1.position.z }

        progress(Progress(step: 4, total: 4, message: "스플랫 \(splats.count)개 완성"))
        return SplatCloud(cardWidth: cardW, cardHeight: cardH, reliefWidth: reliefW, reliefHeight: reliefH,
                          relief: relief, splats: splats)
    }

    // MARK: - Side fusion

    /// 측면 사진 하나에 대한 기하: 얼굴 박스(정규화), 코 중심, 추정 회전각(라디안, +면 코가 이미지 오른쪽으로)
    private nonisolated struct SideGeometry: Sendable {
        var raster: RGBARaster
        var faceBox: CGRect   // 픽셀
        var theta: Float
    }

    private static func analyzeSide(_ png: Data) async -> SideGeometry? {
        guard let img0 = PersonaBuilder.decodeImage(png) else { return nil }
        let img = PersonaBuilder.downscale(img0, maxDimension: 640) ?? img0
        let handler = ImageRequestHandler(img)
        guard let faces = try? await handler.perform(DetectFaceLandmarksRequest()),
              let face = faces.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let landmarks = face.landmarks else { return nil }
        let size = CGSize(width: img.width, height: img.height)
        let box = face.boundingBox.toImageCoordinates(size, origin: .upperLeft)
        let nose = landmarks.nose.pointsInImageCoordinates(size, origin: .upperLeft)
        guard !nose.isEmpty, box.width > 10 else { return nil }
        let noseX = nose.map(\.x).reduce(0, +) / CGFloat(nose.count)
        let ratio = max(-1, min(1, (noseX - box.midX) / (box.width / 2)))
        let theta = Float(ratio) * 0.75 // 코가 박스 가장자리까지 가면 약 43°

        // 인물 마스크 (배경 색을 섞지 않도록)
        var masked = img
        if let obs = try? await handler.perform(GeneratePersonInstanceMaskRequest()), !obs.allInstances.isEmpty,
           let buf = try? obs.generateMaskedImage(for: obs.allInstances, imageFrom: handler) {
            let ci = CIImage(cvPixelBuffer: buf)
            if let cg = CIContext().createCGImage(ci, from: ci.extent) { masked = cg }
        }
        guard let raster = try? RGBARaster(cgImage: masked) else { return nil }
        return SideGeometry(raster: raster, faceBox: box, theta: theta)
    }

    private static func fuseSides(_ sides: [String: Data], into splats: inout [Splat], normals: [SIMD3<Float>],
                                  headCenter: SIMD3<Float>, headAxes: SIMD3<Float>, frontalFace: NRect,
                                  cardSize: SIMD2<Float>) async {
        var geometries: [SideGeometry] = []
        for (key, png) in sides where key != "up" {
            if let g = await analyzeSide(png), abs(g.theta) > 0.12 { geometries.append(g) }
        }
        guard !geometries.isEmpty else { return }
        let frontalFaceW = Float(frontalFace.width) * cardSize.x   // 미터
        let frontalFaceH = Float(frontalFace.height) * cardSize.y
        let frontalFaceCenter = SIMD2(Float(frontalFace.midX - 0.5) * cardSize.x, Float(0.5 - frontalFace.midY) * cardSize.y)

        for i in splats.indices {
            let p = splats[i].position
            let n = normals[i]
            // 머리 범위 안(타원체 + 약간)만
            let rel = p - headCenter
            let e2 = (rel.x / (headAxes.x * 1.15)) * (rel.x / (headAxes.x * 1.15)) + (rel.y / (headAxes.y * 1.15)) * (rel.y / (headAxes.y * 1.15))
            guard e2 < 1.2 else { continue }
            let frontVis = max(0, n.z)
            var best: (score: Float, color: (UInt8, UInt8, UInt8))?
            for g in geometries {
                // 머리를 theta 만큼 돌린 좌표계에서의 법선/위치
                let c = cos(g.theta), s = sin(g.theta)
                let nz = -n.x * s + n.z * c
                let sideVis = max(0, nz)
                guard sideVis > frontVis + 0.15 else { continue }
                let rx = rel.x * c + rel.z * s
                let ry = rel.y
                // 측면 얼굴 박스 크기로 스케일 (정면 얼굴 폭 ↔ 측면 얼굴 폭, 회전으로 좁아진 만큼 cos 보정)
                let scaleX = Float(g.faceBox.width) / max(0.01, frontalFaceW * max(0.55, c))
                let scaleY = Float(g.faceBox.height) / max(0.01, frontalFaceH)
                let px = Float(g.faceBox.midX) + (rx - (frontalFaceCenter.x - headCenter.x)) * scaleX
                let py = Float(g.faceBox.midY) - (ry - (frontalFaceCenter.y - headCenter.y)) * scaleY
                let xi = Int(px), yi = Int(py)
                guard xi >= 0, yi >= 0, xi < g.raster.width, yi < g.raster.height else { continue }
                let idx = (yi * g.raster.width + xi) * 4
                let alpha = g.raster.bytes[idx + 3]
                guard alpha > 120 else { continue }
                let af = Float(alpha) / 255
                let color = (UInt8(min(255, Float(g.raster.bytes[idx]) / af)),
                             UInt8(min(255, Float(g.raster.bytes[idx + 1]) / af)),
                             UInt8(min(255, Float(g.raster.bytes[idx + 2]) / af)))
                if best == nil || sideVis > best!.score { best = (sideVis, color) }
            }
            if let best {
                // 정면 색과 부드럽게 섞기 (경계 띠 방지)
                let w = min(1, (best.score - frontVis - 0.15) / 0.35)
                func mix(_ f: UInt8, _ s: UInt8) -> UInt8 { UInt8(Float(f) * (1 - w) + Float(s) * w) }
                splats[i].r = mix(splats[i].r, best.color.0)
                splats[i].g = mix(splats[i].g, best.color.1)
                splats[i].b = mix(splats[i].b, best.color.2)
            }
        }
    }
}

import CoreImage
