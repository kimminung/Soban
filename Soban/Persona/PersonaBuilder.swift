import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// 사진 한 장 → 투명 배경 상반신 PNG + 얼굴 리그.
///
/// 파이프라인
/// 1. 긴 변 1024px 로 축소
/// 2. `GeneratePersonInstanceMaskRequest` 로 인물만 분리 (실패 시 `GenerateForegroundInstanceMaskRequest`)
/// 3. `DetectFaceLandmarksRequest` 로 눈·입·코 위치
/// 4. 알파 바운딩 박스로 크롭, 피부색/입술색/의상색 샘플링
nonisolated enum PersonaBuilder {

    nonisolated enum BuildError: LocalizedError {
        case decodeFailed
        case noPerson
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .decodeFailed: "사진을 읽을 수 없습니다."
            case .noPerson: "사진에서 사람을 찾지 못했습니다. 상반신이 보이는 정면 사진을 골라 주세요."
            case .renderFailed: "페르소나 이미지를 만들지 못했습니다."
            }
        }
    }

    nonisolated struct Progress: Sendable, Equatable {
        var step: Int
        var total: Int
        var message: String
    }

    static let maxDimension: CGFloat = 1024

    /// 카메라 캡처 입력: 정면 사진(+ 선택적 깊이 맵) 과 보조 각도 사진.
    nonisolated struct CaptureInput: Sendable {
        var frontal: CGImage
        var depth: DepthMap?
        var sideViews: [String: CGImage] = [:]
        var source: PersonaManifest.CaptureSource
        var deviceName: String?
    }

    /// 사진 데이터로 페르소나 패키지를 만든다. 무거운 작업이라 백그라운드 스레드에서 실행된다.
    @concurrent
    static func build(from imageData: Data, name: String,
                      progress: @escaping @Sendable (Progress) -> Void) async throws -> PersonaPackage {
        progress(Progress(step: 1, total: 5, message: "사진을 준비하는 중"))
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let original = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
              ] as CFDictionary) else {
            throw BuildError.decodeFailed
        }
        return try await build(image: original, depth: nil, name: name, source: .photoLibrary, deviceName: nil,
                               sideViews: [:], progress: progress)
    }

    /// 카메라(깊이 포함 가능)로 찍은 캡처로 페르소나를 만든다.
    @concurrent
    static func build(capture: CaptureInput, name: String,
                      progress: @escaping @Sendable (Progress) -> Void) async throws -> PersonaPackage {
        progress(Progress(step: 1, total: 5, message: "촬영본을 준비하는 중"))
        let scaled = downscale(capture.frontal, maxDimension: maxDimension) ?? capture.frontal
        var sides: [String: Data] = [:]
        for (key, img) in capture.sideViews {
            if let small = downscale(img, maxDimension: 640), let png = try? encodePNG(small) { sides[key] = png }
        }
        return try await build(image: scaled, depth: capture.depth, name: name, source: capture.source,
                               deviceName: capture.deviceName, sideViews: sides, progress: progress)
    }

    private static func build(image original: CGImage, depth: DepthMap?, name: String,
                              source: PersonaManifest.CaptureSource, deviceName: String?, sideViews: [String: Data],
                              progress: @escaping @Sendable (Progress) -> Void) async throws -> PersonaPackage {
        progress(Progress(step: 2, total: 5, message: "인물을 배경에서 분리하는 중"))
        let handler = ImageRequestHandler(original)
        var maskedBuffer: CVPixelBuffer?
        if let observation = try await handler.perform(GeneratePersonInstanceMaskRequest()),
           !observation.allInstances.isEmpty {
            maskedBuffer = try observation.generateMaskedImage(for: observation.allInstances, imageFrom: handler)
        } else if let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest()),
                  !observation.allInstances.isEmpty {
            maskedBuffer = try observation.generateMaskedImage(for: observation.allInstances, imageFrom: handler)
        }
        guard let maskedBuffer else { throw BuildError.noPerson }

        progress(Progress(step: 3, total: 5, message: "얼굴의 눈과 입을 찾는 중"))
        let faces = try await handler.perform(DetectFaceLandmarksRequest())
        let imageSize = CGSize(width: original.width, height: original.height)
        // 가장 큰 얼굴 하나만 사용
        let face = faces.max { a, b in
            a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
        }

        progress(Progress(step: 4, total: 5, message: depth == nil ? "카드로 다듬는 중" : "깊이로 가장자리를 다듬는 중"))
        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let ciImage = CIImage(cvPixelBuffer: maskedBuffer)
        guard let masked0 = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw BuildError.renderFailed
        }
        var masked = masked0
        var depthPNG: Data?
        var depthRange: (near: Float, far: Float)?
        if let depth {
            // 얼굴 깊이를 기준으로 그보다 0.45m 이상 먼 픽셀은 배경으로 간주해 알파를 깎는다.
            let faceRect = face?.boundingBox.toImageCoordinates(imageSize, origin: .upperLeft)
                ?? CGRect(x: imageSize.width * 0.3, y: imageSize.height * 0.1, width: imageSize.width * 0.4, height: imageSize.height * 0.4)
            let refined = DepthRefiner.refine(masked0, depth: depth, faceRect: faceRect, imageSize: imageSize)
            masked = refined.image
            depthPNG = refined.depthPNG
            depthRange = refined.range
        }
        let raster = try RGBARaster(cgImage: masked)
        guard var bbox = raster.alphaBoundingBox(threshold: 24) else { throw BuildError.noPerson }
        // 머리 위와 좌우에 여백을 조금 주고, 아래쪽은 사진 끝까지(상반신 카드 느낌)
        let margin = max(bbox.width, bbox.height) * 0.04
        bbox = bbox.insetBy(dx: -margin, dy: -margin)
        bbox.origin.y = max(0, bbox.origin.y)
        bbox = bbox.intersection(CGRect(origin: .zero, size: imageSize)).integral
        guard let cropped = masked.cropping(to: bbox) else { throw BuildError.renderFailed }

        var rig: FaceRig?
        if let face {
            rig = makeRig(face: face, imageSize: imageSize, crop: bbox, raster: raster)
        }
        let accent = raster.averageColor(in: torsoSampleRect(crop: bbox, face: rig, imageSize: imageSize))
            ?? .accentDefault

        progress(Progress(step: 5, total: 5, message: "저장용 PNG 인코딩 중"))
        let png = try encodePNG(cropped)
        var croppedDepthPNG: Data?
        if let depthPNG, let depthImage = decodeImage(depthPNG), let c = depthImage.cropping(to: bbox) {
            croppedDepthPNG = try? encodePNG(c)
        }
        var manifest = PersonaManifest(name: name, kind: .photo, imageWidth: cropped.width, imageHeight: cropped.height,
                                       face: rig, accent: accent, captureSource: source,
                                       hasDepth: croppedDepthPNG != nil, capturedOn: deviceName)
        if croppedDepthPNG != nil, let depthRange {
            manifest.depthNearMeters = depthRange.near
            manifest.depthFarMeters = depthRange.far
        }
        return PersonaPackage(manifest: manifest, bodyPNG: png, depthPNG: croppedDepthPNG, sideViews: sideViews)
    }

    static func downscale(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(1, maxDimension / max(w, h))
        guard scale < 1 else { return image }
        let nw = Int(w * scale), nh = Int(h * scale)
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }

    // MARK: - Rig extraction

    /// 완성된 카드 이미지(투명 배경)에서 얼굴 리그와 포인트 색을 다시 검출한다. PLY 처럼 리그가 없는 입력용.
    @concurrent
    static func detectRig(in image: CGImage) async -> (rig: FaceRig?, accent: RGB) {
        let handler = ImageRequestHandler(image)
        let imageSize = CGSize(width: image.width, height: image.height)
        let faces = (try? await handler.perform(DetectFaceLandmarksRequest())) ?? []
        let face = faces.max { a, b in a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height }
        guard let raster = try? RGBARaster(cgImage: image) else { return (nil, .accentDefault) }
        let full = CGRect(origin: .zero, size: imageSize)
        let rig = face.flatMap { makeRig(face: $0, imageSize: imageSize, crop: full, raster: raster) }
        let accent = raster.averageColor(in: torsoSampleRect(crop: full, face: rig, imageSize: imageSize)) ?? .accentDefault
        return (rig, accent)
    }

    private static func makeRig(face: FaceObservation, imageSize: CGSize, crop: CGRect, raster: RGBARaster) -> FaceRig? {
        guard let landmarks = face.landmarks else { return nil }
        let cropSize = crop.size

        func region(_ r: FaceObservation.Landmarks2D.Region, pad: Double) -> NRect {
            let pts = r.pointsInImageCoordinates(imageSize, origin: .upperLeft)
            guard !pts.isEmpty else { return .zero }
            var rect = CGRect(x: pts[0].x, y: pts[0].y, width: 0, height: 0)
            for p in pts { rect = rect.union(CGRect(origin: p, size: .zero)) }
            rect = rect.insetBy(dx: -rect.width * pad, dy: -rect.height * pad)
            rect.origin.x -= crop.minX
            rect.origin.y -= crop.minY
            return NRect(pixelRect: rect, in: cropSize)
        }

        var faceBox = face.boundingBox.toImageCoordinates(imageSize, origin: .upperLeft)
        faceBox.origin.x -= crop.minX
        faceBox.origin.y -= crop.minY

        let leftEye = region(landmarks.leftEye, pad: 0.35)
        let rightEye = region(landmarks.rightEye, pad: 0.35)
        var mouth = region(landmarks.outerLips, pad: 0.12)
        // 입은 세로로 조금 키워 벌어졌을 때 자연스럽게 덮이도록
        mouth = NRect(x: mouth.x, y: mouth.y, width: mouth.width, height: max(mouth.height, mouth.width * 0.45))

        let nosePts = landmarks.nose.pointsInImageCoordinates(imageSize, origin: .upperLeft)
        let noseCenter = nosePts.isEmpty ? CGPoint(x: faceBox.midX, y: faceBox.midY)
            : CGPoint(x: nosePts.map(\.x).reduce(0, +) / CGFloat(nosePts.count) - crop.minX,
                      y: nosePts.map(\.y).reduce(0, +) / CGFloat(nosePts.count) - crop.minY)

        // 피부색: 코 옆 뺨, 입술색: 입 안쪽
        let cheek = CGRect(x: noseCenter.x + faceBox.width * 0.12, y: noseCenter.y - faceBox.height * 0.02,
                           width: faceBox.width * 0.14, height: faceBox.height * 0.1).offsetBy(dx: crop.minX, dy: crop.minY)
        let lipsPixel = CGRect(x: mouth.x * cropSize.width + crop.minX, y: mouth.y * cropSize.height + crop.minY,
                               width: mouth.width * cropSize.width, height: mouth.height * cropSize.height)
            .insetBy(dx: mouth.width * cropSize.width * 0.3, dy: mouth.height * cropSize.height * 0.3)

        let skin = raster.averageColor(in: cheek) ?? .skinDefault
        let lip = raster.averageColor(in: lipsPixel).map { $0.mixed(with: .lipDefault, 0.35) } ?? .lipDefault

        return FaceRig(faceBox: NRect(pixelRect: faceBox, in: cropSize),
                       leftEye: leftEye, rightEye: rightEye, mouth: mouth,
                       noseTip: NPoint(x: noseCenter.x / cropSize.width, y: noseCenter.y / cropSize.height),
                       skin: skin, lip: lip)
    }

    private static func torsoSampleRect(crop: CGRect, face: FaceRig?, imageSize: CGSize) -> CGRect {
        if let face {
            let faceBottom = crop.minY + (face.faceBox.y + face.faceBox.height) * crop.height
            let y = min(crop.maxY - 10, faceBottom + crop.height * 0.18)
            return CGRect(x: crop.midX - crop.width * 0.18, y: y, width: crop.width * 0.36,
                          height: max(8, min(crop.maxY - y, crop.height * 0.2)))
        }
        return CGRect(x: crop.midX - crop.width * 0.2, y: crop.minY + crop.height * 0.6,
                      width: crop.width * 0.4, height: crop.height * 0.25)
    }

    // MARK: - Encoding

    static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw BuildError.renderFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw BuildError.renderFailed }
        return data as Data
    }

    static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: - Depth refinement

/// 깊이 맵으로 Vision 마스크의 배경 번짐을 깎고, 8비트 깊이 PNG 를 만든다.
nonisolated enum DepthRefiner {
    nonisolated struct Result: Sendable {
        var image: CGImage
        var depthPNG: Data?
        /// depth.png 의 255 → near, 0 → far (미터)
        var range: (near: Float, far: Float)?
    }

    static func refine(_ masked: CGImage, depth: DepthMap, faceRect: CGRect, imageSize: CGSize) -> Result {
        guard var raster = try? RGBARaster(cgImage: masked), depth.width > 0, depth.height > 0 else {
            return Result(image: masked, depthPNG: nil, range: nil)
        }
        // 얼굴 영역 깊이 중앙값
        var faceDepths: [Float] = []
        let fx0 = max(0, faceRect.minX / imageSize.width), fx1 = min(1, faceRect.maxX / imageSize.width)
        let fy0 = max(0, faceRect.minY / imageSize.height), fy1 = min(1, faceRect.maxY / imageSize.height)
        var v = fy0
        while v < fy1 {
            var u = fx0
            while u < fx1 {
                let d = depth.value(u: u, v: v)
                if d.isFinite && d > 0.05 { faceDepths.append(d) }
                u += (fx1 - fx0) / 16
            }
            v += (fy1 - fy0) / 16
        }
        guard faceDepths.count > 8 else {
            return Result(image: masked, depthPNG: makeDepthPNG(depth, near: 0.2, far: 2.5), range: (0.2, 2.5))
        }
        faceDepths.sort()
        let faceDepth = faceDepths[faceDepths.count / 2]
        let cutoff = faceDepth + 0.45
        let soft: Float = 0.12

        for y in 0..<raster.height {
            let vv = (Double(y) + 0.5) / Double(raster.height)
            for x in 0..<raster.width {
                let i = (y * raster.width + x) * 4
                let a = raster.bytes[i + 3]
                guard a > 0 else { continue }
                let d = depth.value(u: (Double(x) + 0.5) / Double(raster.width), v: vv)
                guard d.isFinite && d > 0.05 else { continue }
                if d > cutoff {
                    let t = min(1, (d - cutoff) / soft) // 0→1 멀어질수록 투명
                    let keep = 1 - t
                    raster.bytes[i] = UInt8(Float(raster.bytes[i]) * keep)
                    raster.bytes[i + 1] = UInt8(Float(raster.bytes[i + 1]) * keep)
                    raster.bytes[i + 2] = UInt8(Float(raster.bytes[i + 2]) * keep)
                    raster.bytes[i + 3] = UInt8(Float(a) * keep)
                }
            }
        }
        let image = raster.makeImage() ?? masked
        let near = max(0.1, faceDepth - 0.3), far = cutoff + 0.3
        return Result(image: image, depthPNG: makeDepthPNG(depth, near: near, far: far,
                                                           size: CGSize(width: raster.width, height: raster.height)),
                      range: (near, far))
    }

    /// 가까울수록 밝은 8비트 그레이 PNG. 입력 크기에 리샘플.
    static func makeDepthPNG(_ depth: DepthMap, near: Float, far: Float, size: CGSize? = nil) -> Data? {
        let w = Int(size?.width ?? CGFloat(depth.width)), h = Int(size?.height ?? CGFloat(depth.height))
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let d = depth.value(u: (Double(x) + 0.5) / Double(w), v: (Double(y) + 0.5) / Double(h))
                guard d.isFinite else { continue }
                let t = 1 - min(1, max(0, (d - near) / max(0.01, far - near)))
                bytes[y * w + x] = UInt8(t * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return try? PersonaBuilder.encodePNG(img)
    }
}

// MARK: - RGBA raster (CPU 샘플링용)

/// CGImage 를 RGBA8(비프리멀티플라이) 버퍼로 렌더링해 알파 바운딩 박스와 평균색을 계산한다.
nonisolated struct RGBARaster: Sendable {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    /// 현재 바이트로 CGImage 를 만든다 (premultiplied RGBA8).
    func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    init(cgImage: CGImage) throws {
        let w = cgImage.width
        let h = cgImage.height
        width = w
        height = h
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw PersonaBuilder.BuildError.renderFailed }
        bytes = buffer
    }

    /// 알파가 threshold 를 넘는 픽셀들의 바운딩 박스(좌상단 원점).
    func alphaBoundingBox(threshold: UInt8) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where bytes[row + x * 4 + 3] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// 사각형(픽셀, 좌상단 원점) 안의 불투명 픽셀 평균색.
    func averageColor(in rect: CGRect) -> RGB? {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
        let stepX = max(1, Int(r.width) / 24), stepY = max(1, Int(r.height) / 24)
        var y = Int(r.minY)
        while y < Int(r.maxY) {
            var x = Int(r.minX)
            while x < Int(r.maxX) {
                let i = (y * width + x) * 4
                let a = Double(bytes[i + 3]) / 255
                if a > 0.5 {
                    // premultiplied → un-premultiply
                    sr += Double(bytes[i]) / 255 / a
                    sg += Double(bytes[i + 1]) / 255 / a
                    sb += Double(bytes[i + 2]) / 255 / a
                    n += 1
                }
                x += stepX
            }
            y += stepY
        }
        guard n > 4 else { return nil }
        return RGB(r: min(1, sr / n), g: min(1, sg / n), b: min(1, sb / n))
    }
}
