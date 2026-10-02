import Foundation
import CoreGraphics
import simd
import Vision

/// 페르소나 패키지(정면 카드 + 깊이 + 측면 사진)에서 가우시안 스플랫 클라우드를 만든다.
///
/// 1. 카드의 불투명 픽셀을 ~3만 개가 되도록 격자 샘플링
/// 2. z: 깊이 맵이 있으면 `depth.png` 를 미터로 되돌려 얼굴 중앙값 기준 상대 깊이.
///    없으면 **`SplatPlaceholder_Bust.usdz` 흉상 템플릿**(`BustTemplate`, 투명 목데이터)을 눈 간격·눈 중심으로 맞춰
///    머리·목·어깨 굴곡을 읽는다. 템플릿도 없으면 얼굴 리그로 맞춘 머리 타원체 + 몸통 반원기둥 부조.
/// 3. 머리카락: Vision 리그(눈썹 윗선·얼굴 윤곽 폭·피부/머리카락 색)로 분류 → 볼륨 돔 + 흩뿌린 2겹 셸
/// 4. 측면 사진이 있으면 코 위치로 회전각을 추정해 머리 옆면(법선이 옆을 보는 스플랫)의 색을 측면 사진에서 샘플
/// 5. 뒤→앞 정렬(알파 블렌딩용), 부조 그리드 기록
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
                      template: BustTemplate? = nil,
                      hints: AppearanceHints? = nil,
                      progress: @escaping @Sendable (Progress) -> Void) async throws -> SplatCloud {
        progress(Progress(step: 1, total: 5, message: template == nil ? "카드를 3D 점으로 펼치는 중" : "흉상 템플릿을 얼굴 윤곽에 맞춰 휘는 중"))
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
        let faceW = Float(faceBox.width) * cardW
        let faceH = Float(faceBox.height) * cardH
        let a = faceW * 0.62                              // 머리 반폭 (머리카락 포함)
        let b = faceH * 0.72                              // 머리 반높이
        let rz = a * 0.95                                 // 머리 반깊이
        let torsoHalf = cardW * 0.5
        let neckY = cy - b * 0.9

        // 눈 중심/간격 → 흉상 공간 매핑 (눈 간격 0.064, 눈 높이 0.44)
        var eyeMid = SIMD2(cx, cy + b * 0.1)
        var eyeDist = a * 0.67
        if let face {
            let l = SIMD2(Float(face.leftEye.midX - 0.5) * cardW, Float(0.5 - face.leftEye.midY) * cardH)
            let r = SIMD2(Float(face.rightEye.midX - 0.5) * cardW, Float(0.5 - face.rightEye.midY) * cardH)
            eyeMid = (l + r) / 2
            eyeDist = max(0.02, abs(r.x - l.x))
        }
        let k = FaceKitSex.eyeSpacing / eyeDist           // 흉상 단위 / 카드 미터

        // 7차: 템플릿을 사진에 맞춰 변형하는 사상 (얼굴 = 랜드마크 TPS, 그 밖 = 인물 마스크 행별 폭 맞춤)
        var fit: TemplateFit?
        if let template {
            let rowCount = 160
            var ranges = [(Float, Float)?](repeating: nil, count: rowCount)
            for i in 0..<rowCount {
                // 행 중심의 픽셀 y (카드 아래 → 위 = v 1 → 0)
                let v = 1 - (Float(i) + 0.5) / Float(rowCount)
                let py = min(H - 1, max(0, Int(v * Float(H))))
                var x0 = -1, x1 = -1
                var xx = 0
                while xx < W {
                    if raster.bytes[(py * W + xx) * 4 + 3] > 40 { if x0 < 0 { x0 = xx }; x1 = xx }
                    xx += 2
                }
                if x0 >= 0 {
                    ranges[i] = ((Float(x0) / Float(W) - 0.5) * cardW, (Float(x1 + 1) / Float(W) - 0.5) * cardW)
                }
            }
            fit = TemplateFit(template: template, rig: face, cardSize: SIMD2(cardW, cardH), rowCount: rowCount) { y in
                let idx = min(rowCount - 1, max(0, Int((y + cardH / 2) / cardH * Float(rowCount))))
                return ranges[idx]
            }
        }
        func bustXY(_ x: Float, _ y: Float) -> SIMD2<Float> {
            if let fit { return fit.map(SIMD2(x, y)) }
            return SIMD2((x - eyeMid.x) * k, FaceKitSex.eyeHeight + (y - eyeMid.y) * k)
        }
        // 기준 깊이: 양 뺨(코 옆) 평균 → 뺨이 z≈0, 코끝만 살짝 +
        var templateFaceZ: Float = 0
        if let template {
            let zs = [template.z(x: -0.045, y: 0.40), template.z(x: 0.045, y: 0.40)].compactMap { $0 }
            templateFaceZ = zs.isEmpty ? (template.z(x: 0, y: 0.40) ?? 0) : zs.reduce(0, +) / Float(zs.count)
        }

        /// 흉상 템플릿 z (카드 미터, 뺨 기준 상대). 실루엣 밖(넓은 어깨·머리카락 끝)은 가장자리 z 에서 뒤로 기울인다.
        func templateZ(x: Float, y: Float) -> Float? {
            guard let template else { return nil }
            let p = bustXY(x, y)
            if let tz = template.z(x: p.x, y: p.y) {
                return max(-0.25, min(0.15, (tz - templateFaceZ) / k))
            }
            // 실루엣 밖(넓은 어깨·머리카락 끝·정수리 위): 같은 높이 가장자리 z(행 보간·평활) 에서 뒤로 기울인다
            guard let edge = template.edge(atY: p.y), edge.halfWidth > 0.005 else { return nil }
            // 옆으로 벗어난 만큼은 뒤로 기울이고(머리끝·어깨 끝), 흉상 절단면 아래(가슴·배)와 정수리 위는 거의 수직으로 잇는다
            // (7차: 아래쪽을 0.8 로 기울이면 몸통이 그림자 카드 뒤로 들어가 회색으로 비쳤다)
            let sideOut = max(0, abs(p.x) - edge.halfWidth)
            let vertOut = max(0, p.y - template.maxY) + max(0, template.minY - p.y)
            return max(-0.25, (edge.z - templateFaceZ) / k - sideOut / k * 0.8 - vertOut / k * 0.12)
        }

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
        let hasDepth = depthRaster != nil

        func depthZ(u: Double, v: Double) -> Float? {
            guard let dr = depthRaster else { return nil }
            let x = min(dr.width - 1, max(0, Int(u * Double(dr.width))))
            let y = min(dr.height - 1, max(0, Int(v * Double(dr.height))))
            let t = Float(dr.bytes[(y * dr.width + x) * 4]) / 255
            guard t > 0.02 else { return nil }
            let d = far - t * (far - near)
            return max(-0.22, min(0.14, depthFace - d))
        }

        /// 해석적 부조 모델(템플릿이 없을 때): 머리 타원체 + 몸통. 법선도 함께.
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

        /// 표면 z + 법선: 깊이 맵 → 흉상 템플릿 → 해석적 부조 순.
        func surface(u: Double, v: Double, x: Float, y: Float) -> (z: Float, n: SIMD3<Float>, fromTemplate: Bool) {
            if let dz = depthZ(u: u, v: v) { return (dz, reliefZ(x: x, y: y).n, false) }
            if let tz = templateZ(x: x, y: y) {
                let h: Float = 0.01
                let zx = templateZ(x: x + h, y: y) ?? tz, zy = templateZ(x: x, y: y + h) ?? tz
                let n = simd_normalize(SIMD3(-(zx - tz) / h, -(zy - tz) / h, 1))
                return (tz, n, true)
            }
            let r = reliefZ(x: x, y: y)
            return (r.z, r.n, false)
        }

        // 머리카락 분류 (온디바이스 Vision 리그: 눈썹 윗선 + 얼굴 윤곽 폭 + 피부/머리카락 색)
        let skin = face?.skin ?? .skinDefault
        let hairColor = face?.hair
        let browV = face?.browLineV ?? (faceBox.y + faceBox.height * 0.22)
        let hairLineY = Float(0.5 - browV) * cardH
        var faceHalfW = faceW * 0.5
        if let contour = face?.contour, contour.count >= 3 {
            let xs = contour.map { Float($0.x - 0.5) * cardW }
            faceHalfW = max(faceHalfW * 0.8, (xs.max()! - xs.min()!) / 2)
        }
        // 외형 힌트(FoundationModels 또는 휴리스틱)는 머리카락 **범위·볼륨 초기값**에만 쓴다. 좌표는 Vision 리그만 신뢰.
        let hairDepth = faceW * 0.14 * (hints?.hairDepthScale ?? 1)
        let hairReach = cardH * (hints?.hairReachBelowNeck ?? 0.12)     // 목선 아래로 머리카락을 인정하는 범위
        let bangs = hints?.hasBangs ?? false
        func colorDist(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ c: RGB) -> Float {
            let dr = Float(r) / 255 - Float(c.r), dg = Float(g) / 255 - Float(c.g), db = Float(b) / 255 - Float(c.b)
            return sqrt(dr * dr + dg * dg + db * db) / 1.732
        }
        func isHair(_ r: UInt8, _ g: UInt8, _ bl: UInt8, x: Float, y: Float) -> Bool {
            guard y > neckY - hairReach, y > cy - b * 0.6 || abs(x - cx) > faceHalfW * 0.95 else { return false }
            // 앞머리가 있으면 이마 중앙은 눈썹 선 아래 10% 까지도 머리카락으로 인정
            let browMargin: Float = (bangs && abs(x - cx) < faceHalfW * 0.6) ? -faceH * 0.10 : faceH * 0.05
            let aboveBrow = y > hairLineY + browMargin
            let outsideFace = abs(x - cx) > faceHalfW * 0.92
            guard aboveBrow || outsideFace else { return false }
            let dSkin = colorDist(r, g, bl, skin)
            if let hairColor {
                let dHair = colorDist(r, g, bl, hairColor)
                return dHair < dSkin * 0.9 || dSkin > 0.22
            }
            return dSkin > 0.22
        }
        /// 머리카락 볼륨 돔 (정수리 쪽일수록, 머리 중앙일수록 두껍게).
        func hairDome(x: Float, y: Float) -> Float {
            let ex = (x - cx) / (a * 1.12)
            let lateral = sqrt(max(0, 1 - ex * ex))
            let vertical = max(0.25, min(1, (y - (cy - b * 0.3)) / max(0.01, b * 0.9)))
            return hairDepth * lateral * vertical
        }

        // 입 안쪽 컬링(문서 (d) "구멍 뚫기"): 얼굴 키트를 쓰면 입술 안쪽 스플랫을 비워 치아·입 안 메시가 턱을 벌릴 때 보이게 한다.
        let cullMouth = face != nil && m.faceKitSex != nil
        let mouthCenter = face.map { SIMD2(Float($0.mouth.midX - 0.5) * cardW, Float(0.5 - $0.mouth.midY) * cardH) } ?? .zero
        let mouthRx = (face.map { Float($0.mouth.width) * cardW / 1.24 } ?? 0.05) * 0.42
        let mouthRy = (face.map { Float($0.mouth.height) * cardH } ?? 0.03) * 0.22
        func mouthInterior(_ x: Float, _ y: Float) -> Float {   // 0 = 완전 안쪽(제거), 1 = 바깥
            guard cullMouth else { return 1 }
            let d = sqrt(pow((x - mouthCenter.x) / max(0.004, mouthRx), 2) + pow((y - mouthCenter.y) / max(0.003, mouthRy), 2))
            if d < 0.6 { return 0 }
            if d < 1 { return (d - 0.6) / 0.4 }
            return 1
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
        var hairIndices: [Int] = []

        let reliefW = 96, reliefH = 128   // 눈꺼풀/입술 키트가 변형된 표면 z 에 정확히 앉도록 7차에 2배로
        var relief = [Float](repeating: -1, count: reliefW * reliefH)
        var templateHits = 0

        var y = stride / 2
        while y < H {
            var x = stride / 2
            while x < W {
                let i = (y * W + x) * 4
                let alpha = raster.bytes[i + 3]
                if alpha > 40 {
                    let u = (Double(x) + 0.5) / Double(W), v = (Double(y) + 0.5) / Double(H)
                    let px = Float(u - 0.5) * cardW, py = Float(0.5 - v) * cardH
                    // premultiplied → straight
                    let af = Float(alpha) / 255
                    let r = UInt8(min(255, Float(raster.bytes[i]) / af))
                    let g = UInt8(min(255, Float(raster.bytes[i + 1]) / af))
                    let bch = UInt8(min(255, Float(raster.bytes[i + 2]) / af))
                    let interior = mouthInterior(px, py)
                    if interior <= 0 { x += stride; continue }
                    let s = surface(u: u, v: v, x: px, y: py)
                    if s.fromTemplate { templateHits += 1 }
                    var z = s.z
                    let hair = isHair(r, g, bch, x: px, y: py)
                    if hair && !hasDepth { z += hairDome(x: px, y: py) }
                    // 가장자리는 조금 작게·투명하게
                    let edge = (alpha < 200 ? Float(alpha) / 200 : 1) * interior
                    if hair { hairIndices.append(splats.count) }
                    // 경사 보정: 옆을 보는 표면(머리 옆면·어깨 라운드)은 정면 격자가 z 로 늘어나 줄무늬 틈이 생기므로 스플랫을 키운다
                    let slope = min(3.2, 1 / max(0.3, s.n.z))
                    splats.append(Splat(position: SIMD3(px, py, z), r: r, g: g, b: bch,
                                        a: UInt8(min(255, 235 * edge + 20)), scale: baseScale * (0.75 + 0.35 * edge) * slope))
                    normals.append(s.n)
                    let rx = min(reliefW - 1, Int(u * Double(reliefW))), ry = min(reliefH - 1, Int(v * Double(reliefH)))
                    relief[ry * reliefW + rx] = max(relief[ry * reliefW + rx], z)
                    if splats.count >= maxCount { break }
                }
                x += stride
            }
            if splats.count >= maxCount { break }
            y += stride
        }
        // 비어 있는 부조 셀은 0 으로
        for idx in relief.indices where relief[idx] < 0 { relief[idx] = 0 }

        // 머리카락 입체감: 돔 위에 한 겹 더(살짝 앞·흩뿌림·명도 변화) → 가닥 느낌의 볼륨
        progress(Progress(step: 2, total: 5, message: "머리카락 볼륨을 덧씌우는 중 (\(hairIndices.count)점)"))
        if !hairIndices.isEmpty {
            var rng = SystemRandomNumberGenerator()
            let budget = max(0, maxCount - splats.count)
            let take = min(hairIndices.count, budget)
            let step = max(1, hairIndices.count / max(1, take))
            var j = 0
            while j < hairIndices.count && splats.count < maxCount {
                let src = splats[hairIndices[j]]
                let jitter = pixelMeters * Float(stride)
                let lift = hairDepth * Float.random(in: 0.25...0.7, using: &rng)
                let shade = Float.random(in: 0.88...1.1, using: &rng)
                func sh(_ c: UInt8) -> UInt8 { UInt8(max(0, min(255, Float(c) * shade))) }
                var dup = src
                dup.position += SIMD3(Float.random(in: -jitter...jitter, using: &rng),
                                      Float.random(in: -jitter...jitter, using: &rng), lift)
                dup.r = sh(src.r); dup.g = sh(src.g); dup.b = sh(src.b)
                dup.a = UInt8(Float(src.a) * 0.7)
                dup.scale = src.scale * 0.85
                splats.append(dup)
                normals.append(normals[hairIndices[j]])
                j += step
            }
        }

        // 측면 융합
        if !package.sideViews.isEmpty {
            progress(Progress(step: 3, total: 5, message: "측면 사진으로 옆면 색을 채우는 중"))
            await fuseSides(package.sideViews, into: &splats, normals: normals, headCenter: SIMD3(cx, cy, 0),
                            headAxes: SIMD3(a, b, rz), frontalFace: faceBox, cardSize: SIMD2(cardW, cardH))
        }

        progress(Progress(step: 4, total: 5, message: "뒤에서 앞으로 정렬하는 중"))
        splats.sort { $0.position.z < $1.position.z }

        var how = hasDepth ? "깊이 카메라" : (templateHits > 0 ? "흉상 템플릿" : "부조 모델")
        if let fit, fit.tps != nil { how += " · 윤곽 TPS \(fit.correspondenceCount)점" }
        progress(Progress(step: 5, total: 5, message: "스플랫 \(splats.count)개 완성 · \(how)"))
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
