import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import simd

/// 파일(.sobanpersona 또는 3DGS .ply)에서 페르소나 패키지를 만든다.
///
/// - `.sobanpersona`: 그대로 디코딩.
/// - `.ply`: 3DGS PLY 를 `SplatCloud` 로 파싱 → 스플랫을 정면에서 직교 투영해 카드 PNG 를 렌더 →
///   Vision 으로 얼굴 리그를 다시 검출 → 입체 초안. 단위가 미터가 아니면 키 0.8m 로 정규화한다.
nonisolated enum PersonaImporter {
    nonisolated enum ImportError: LocalizedError {
        case unsupported(String)
        case unreadable
        case emptyCloud
        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): "지원하지 않는 파일입니다 (.\(ext)). .sobanpersona 또는 .ply 를 골라 주세요."
            case .unreadable: "파일을 읽을 수 없습니다."
            case .emptyCloud: "PLY 에서 스플랫을 찾지 못했습니다."
            }
        }
    }

    nonisolated struct Progress: Sendable, Equatable {
        var message: String
    }

    /// 보안 범위 URL 도 처리한다(fileImporter 가 준 URL).
    @concurrent
    static func importFile(at url: URL, flipY: Bool = false,
                           progress: @escaping @Sendable (Progress) -> Void) async throws -> PersonaPackage {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case PersonaPackageFile.fileExtension:
            progress(Progress(message: "소반 패키지를 여는 중"))
            return try PersonaPackageFile.decode(data)
        case "ply":
            let name = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "소반-", with: "")
            return try await importPLY(data, name: name.isEmpty ? "불러온 페르소나" : name, flipY: flipY, progress: progress)
        default:
            throw ImportError.unsupported(ext)
        }
    }

    /// 이미 파싱된 스플랫으로 패키지를 만든다 (위아래 뒤집기 재적용용).
    @concurrent
    static func package(from cloudIn: SplatCloud, name: String, flipY: Bool,
                        progress: @escaping @Sendable (Progress) -> Void) async throws -> PersonaPackage {
        var cloud = cloudIn
        if flipY {
            for i in cloud.splats.indices { cloud.splats[i].position.y = -cloud.splats[i].position.y }
            cloud.relief = Self.reliefGrid(cloud.splats, width: cloud.reliefWidth, height: cloud.reliefHeight,
                                           cardWidth: cloud.cardWidth, cardHeight: cloud.cardHeight)
        }
        progress(Progress(message: "스플랫을 카드 이미지로 렌더링하는 중"))
        guard let card = renderCard(cloud) else { throw ImportError.emptyCloud }
        progress(Progress(message: "얼굴의 눈과 입을 찾는 중"))
        let (rig, accent) = await PersonaBuilder.detectRig(in: card)
        progress(Progress(message: "패키지로 묶는 중"))
        let png = try PersonaBuilder.encodePNG(card)
        var manifest = PersonaManifest(name: name, kind: .photo, imageWidth: card.width, imageHeight: card.height,
                                       face: rig, accent: accent, cardHeightMeters: cloud.cardHeight,
                                       captureSource: .importedFile, hasDepth: false, capturedOn: "3DGS PLY")
        manifest.hasSplats = true
        manifest.splatCount = cloud.count
        return PersonaPackage(manifest: manifest, bodyPNG: png, splats: cloud.encode())
    }

    private static func importPLY(_ data: Data, name: String, flipY: Bool,
                                  progress: @escaping @Sendable (Progress) -> Void) async throws -> PersonaPackage {
        progress(Progress(message: "PLY 를 읽는 중"))
        guard let cloud = SplatCloud(plyData: data), cloud.count > 0 else { throw ImportError.emptyCloud }
        return try await package(from: cloud, name: name, flipY: flipY, progress: progress)
    }

    // MARK: - Card rendering

    /// 스플랫을 정면(+z 방향에서) 직교 투영해 투명 배경 카드로 그린다. 뒤→앞 순서로 소프트 디스크.
    static func renderCard(_ cloud: SplatCloud, height: Int = 800) -> CGImage? {
        guard cloud.cardHeight > 0, cloud.cardWidth > 0 else { return nil }
        let H = height
        let W = max(64, Int(Float(height) * cloud.cardWidth / cloud.cardHeight))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setShouldAntialias(true)
        let pxPerMeter = CGFloat(Float(W) / cloud.cardWidth)
        let sorted = cloud.splats.sorted { $0.position.z < $1.position.z }
        for s in sorted {
            // CGContext 는 좌하단 원점 → y 그대로
            let px = CGFloat(s.position.x / cloud.cardWidth + 0.5) * CGFloat(W)
            let py = CGFloat(s.position.y / cloud.cardHeight + 0.5) * CGFloat(H)
            let r = max(1.2, CGFloat(s.scale) * pxPerMeter * 1.3)
            ctx.setFillColor(CGColor(srgbRed: CGFloat(s.r) / 255, green: CGFloat(s.g) / 255, blue: CGFloat(s.b) / 255,
                                     alpha: CGFloat(s.a) / 255))
            ctx.fillEllipse(in: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))
        }
        return ctx.makeImage()
    }

    static func reliefGrid(_ splats: [Splat], width: Int, height: Int, cardWidth: Float, cardHeight: Float) -> [Float] {
        var relief = [Float](repeating: 0, count: width * height)
        for s in splats {
            let u = Double(s.position.x / cardWidth + 0.5), v = Double(0.5 - s.position.y / cardHeight)
            guard u >= 0, u < 1, v >= 0, v < 1 else { continue }
            let x = Int(u * Double(width)), y = Int(v * Double(height))
            relief[y * width + x] = max(relief[y * width + x], s.position.z)
        }
        return relief
    }
}

// MARK: - 3DGS PLY parsing

extension SplatCloud {
    /// 3D Gaussian Splatting PLY(binary little endian 또는 ascii) 를 읽는다.
    /// x y z 필수. 색은 f_dc_0..2 또는 red/green/blue, 불투명도 opacity(logit) 또는 alpha, 크기 scale_0..2(log).
    /// 단위가 미터로 보이지 않으면(키 0.3~1.5m 밖) 키 0.8m 로 정규화하고 중심을 원점으로 옮긴다.
    init?(plyData data: Data) {
        guard let headerEnd = data.range(of: Data("end_header\n".utf8)) else { return nil }
        guard let header = String(data: data[data.startIndex..<headerEnd.upperBound], encoding: .ascii) else { return nil }
        var isBinary = true
        var isLittle = true
        var vertexCount = 0
        var props: [(name: String, type: String)] = []
        var inVertex = false
        for line in header.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard let key = parts.first else { continue }
            switch key {
            case "format":
                if parts.count > 1 {
                    isBinary = parts[1].hasPrefix("binary")
                    isLittle = parts[1] != "binary_big_endian"
                }
            case "element":
                inVertex = parts.count > 2 && parts[1] == "vertex"
                if inVertex { vertexCount = Int(parts[2]) ?? 0 }
            case "property":
                if inVertex, parts.count >= 3, parts[1] != "list" { props.append((parts[2], parts[1])) }
            default: break
            }
        }
        guard vertexCount > 0, !props.isEmpty, isLittle else { return nil }
        func index(_ n: String) -> Int? { props.firstIndex { $0.name == n } }
        guard let ix = index("x"), let iy = index("y"), let iz = index("z") else { return nil }
        let idc = (index("f_dc_0"), index("f_dc_1"), index("f_dc_2"))
        let irgb = (index("red") ?? index("r"), index("green") ?? index("g"), index("blue") ?? index("b"))
        let iop = index("opacity") ?? index("alpha")
        let isc = (index("scale_0"), index("scale_1"))

        func size(_ t: String) -> Int {
            switch t {
            case "char", "uchar", "int8", "uint8": 1
            case "short", "ushort", "int16", "uint16": 2
            case "int", "uint", "float", "int32", "uint32", "float32": 4
            case "double", "float64": 8
            default: 4
            }
        }
        var values = [Float](repeating: 0, count: props.count)
        var splats: [Splat] = []
        splats.reserveCapacity(min(vertexCount, SplatBuilder.maxCount * 2))
        let body = data[headerEnd.upperBound...]
        let sh0: Float = 0.28209479177387814

        func makeSplat() {
            var r: Float = 0.6, g: Float = 0.6, b: Float = 0.6
            if let a = idc.0, let bb = idc.1, let c = idc.2 {
                r = values[a] * sh0 + 0.5; g = values[bb] * sh0 + 0.5; b = values[c] * sh0 + 0.5
            } else if let a = irgb.0, let bb = irgb.1, let c = irgb.2 {
                let isByte = props[a].type.contains("char") || props[a].type.contains("int8")
                r = isByte ? values[a] / 255 : values[a]; g = isByte ? values[bb] / 255 : values[bb]; b = isByte ? values[c] / 255 : values[c]
            }
            var alpha: Float = 1
            if let io = iop {
                let v = values[io]
                let isByte = props[io].type.contains("char") || props[io].type.contains("int8")
                alpha = isByte ? v / 255 : (props[io].name == "opacity" ? 1 / (1 + exp(-v)) : v)
            }
            var scale: Float = 0.004
            if let a = isc.0 {
                let s0 = exp(values[a])
                let s1 = isc.1.map { exp(values[$0]) } ?? s0
                scale = (s0 + s1) / 2
            }
            func c8(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v * 255))) }
            splats.append(Splat(position: SIMD3(values[ix], values[iy], values[iz]), r: c8(r), g: c8(g), b: c8(b),
                                a: c8(alpha), scale: scale))
        }

        if isBinary {
            let stride = props.reduce(0) { $0 + size($1.type) }
            guard body.count >= stride * vertexCount else { return nil }
            body.withUnsafeBytes { raw in
                var offset = 0
                for _ in 0..<vertexCount {
                    for (i, p) in props.enumerated() {
                        switch p.type {
                        case "float", "float32": values[i] = raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
                        case "double", "float64": values[i] = Float(raw.loadUnaligned(fromByteOffset: offset, as: Double.self))
                        case "uchar", "uint8": values[i] = Float(raw.load(fromByteOffset: offset, as: UInt8.self))
                        case "char", "int8": values[i] = Float(raw.load(fromByteOffset: offset, as: Int8.self))
                        case "ushort", "uint16": values[i] = Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                        case "short", "int16": values[i] = Float(raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                        case "uint", "uint32": values[i] = Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                        case "int", "int32": values[i] = Float(raw.loadUnaligned(fromByteOffset: offset, as: Int32.self))
                        default: values[i] = 0
                        }
                        offset += size(p.type)
                    }
                    makeSplat()
                }
            }
        } else {
            guard let text = String(data: body, encoding: .ascii) else { return nil }
            for line in text.split(separator: "\n").prefix(vertexCount) {
                let nums = line.split(separator: " ").compactMap { Float($0) }
                guard nums.count >= props.count else { continue }
                for i in 0..<props.count { values[i] = nums[i] }
                makeSplat()
            }
        }
        guard !splats.isEmpty else { return nil }

        // 큰 클라우드는 균등 추출
        if splats.count > SplatBuilder.maxCount {
            let step = Double(splats.count) / Double(SplatBuilder.maxCount)
            var picked: [Splat] = []
            picked.reserveCapacity(SplatBuilder.maxCount)
            var i = 0.0
            while Int(i) < splats.count && picked.count < SplatBuilder.maxCount { picked.append(splats[Int(i)]); i += step }
            splats = picked
        }

        // 바운딩 박스 → 정규화
        var minP = splats[0].position, maxP = splats[0].position
        for s in splats { minP = simd_min(minP, s.position); maxP = simd_max(maxP, s.position) }
        let center = (minP + maxP) / 2
        let extent = maxP - minP
        var scaleFactor: Float = 1
        if extent.y < 0.3 || extent.y > 1.5 { scaleFactor = 0.8 / max(0.001, extent.y) }
        for i in splats.indices {
            splats[i].position = (splats[i].position - center) * scaleFactor
            splats[i].scale *= scaleFactor
        }
        let cardH = max(0.3, extent.y * scaleFactor * 1.04)
        let cardW = max(0.2, extent.x * scaleFactor * 1.04)
        splats.sort { $0.position.z < $1.position.z }
        let relief = PersonaImporter.reliefGrid(splats, width: 48, height: 64, cardWidth: cardW, cardHeight: cardH)
        self.init(cardWidth: cardW, cardHeight: cardH, reliefWidth: 48, reliefHeight: 64, relief: relief, splats: splats)
    }
}
