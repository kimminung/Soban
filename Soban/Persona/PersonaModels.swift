import Foundation
import CoreGraphics
import simd

// MARK: - Geometry helpers (normalized, top-left origin, 0...1 inside the persona card)

/// 정규화 사각형. 원점은 좌상단, 값은 0...1. 페르소나 카드(body.png) 좌표계 기준.
nonisolated struct NRect: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    static let zero = NRect(x: 0, y: 0, width: 0, height: 0)

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// CGRect(픽셀, 좌상단 원점) → 정규화.
    init(pixelRect: CGRect, in size: CGSize) {
        x = pixelRect.minX / size.width
        y = pixelRect.minY / size.height
        width = pixelRect.width / size.width
        height = pixelRect.height / size.height
    }

    func insetBy(fraction: Double) -> NRect {
        let dx = width * fraction, dy = height * fraction
        return NRect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    func scaled(by factor: Double) -> NRect {
        let w = width * factor, h = height * factor
        return NRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }
}

nonisolated struct NPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
}

/// sRGB 0...1 색.
nonisolated struct RGB: Codable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    static let skinDefault = RGB(r: 0.93, g: 0.78, b: 0.68)
    static let lipDefault = RGB(r: 0.62, g: 0.28, b: 0.30)
    static let accentDefault = RGB(r: 0.22, g: 0.45, b: 0.62)

    func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    func darker(_ amount: Double) -> RGB {
        RGB(r: r * (1 - amount), g: g * (1 - amount), b: b * (1 - amount))
    }

    var simd: SIMD3<Float> { SIMD3(Float(r), Float(g), Float(b)) }
}

// MARK: - Face rig

/// Vision 얼굴 랜드마크에서 뽑아낸, 애니메이션에 필요한 최소 리그.
nonisolated struct FaceRig: Codable, Hashable, Sendable {
    var faceBox: NRect
    var leftEye: NRect
    var rightEye: NRect
    var mouth: NRect
    var noseTip: NPoint
    var skin: RGB
    var lip: RGB
}

// MARK: - Persona manifest

/// 페르소나 패키지의 메타데이터. body.png 와 함께 `Documents/Personas/<id>/` 에 저장된다.
nonisolated struct PersonaManifest: Codable, Hashable, Identifiable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case photo        // 사용자의 실제 사진으로 만든 페르소나
        case placeholder  // 앱이 그린 샘플/손님 페르소나
    }

    /// 어떤 경로로 모습을 수집했는지.
    nonisolated enum CaptureSource: String, Codable, Sendable {
        case photoLibrary        // Vision Pro 사진 보관함
        case depthCamera         // iPhone/iPad TrueDepth 또는 LiDAR 깊이 카메라
        case camera              // 깊이 없는 카메라 (iPhone/iPad/Mac)
        case generated           // 앱이 그린 샘플
        case importedFile        // .sobanpersona 또는 3DGS PLY 파일에서 불러옴
    }

    var id: UUID
    var name: String
    var createdAt: Date
    var kind: Kind
    var imageWidth: Int
    var imageHeight: Int
    var face: FaceRig?
    var accent: RGB
    /// 카드(상반신)의 실제 세로 크기(m). 좌식 테이블 위에 떠 있는 상반신 기준 0.8m.
    var cardHeightMeters: Float
    /// 말할 때 입이 벌어지는 강도 배율.
    var mouthStrength: Float
    var schemaVersion: Int
    var captureSource: CaptureSource
    /// 깊이 맵(`depth.png`)이 패키지에 함께 저장되어 있는지.
    var hasDepth: Bool
    /// 캡처한 기기 이름 (예: "iPhone 16 Pro").
    var capturedOn: String?
    /// `splats.bin`(가우시안 스플랫 클라우드)이 패키지에 있는지와 개수.
    var hasSplats: Bool
    var splatCount: Int
    /// `depth.png` 8비트 값을 미터로 되돌리기 위한 범위(밝을수록 가까움: 255 → near).
    var depthNearMeters: Float?
    var depthFarMeters: Float?

    init(id: UUID = UUID(), name: String, kind: Kind, imageWidth: Int, imageHeight: Int,
         face: FaceRig?, accent: RGB, cardHeightMeters: Float = 0.8, mouthStrength: Float = 1.0,
         captureSource: CaptureSource = .photoLibrary, hasDepth: Bool = false, capturedOn: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.kind = kind
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.face = face
        self.accent = accent
        self.cardHeightMeters = cardHeightMeters
        self.mouthStrength = mouthStrength
        self.schemaVersion = 2
        self.captureSource = captureSource
        self.hasDepth = hasDepth
        self.capturedOn = capturedOn
        self.hasSplats = false
        self.splatCount = 0
    }

    // 스키마 1 (captureSource 없음) 과의 호환
    nonisolated enum CodingKeys: String, CodingKey {
        case id, name, createdAt, kind, imageWidth, imageHeight, face, accent, cardHeightMeters, mouthStrength,
             schemaVersion, captureSource, hasDepth, capturedOn, hasSplats, splatCount, depthNearMeters, depthFarMeters
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        kind = try c.decode(Kind.self, forKey: .kind)
        imageWidth = try c.decode(Int.self, forKey: .imageWidth)
        imageHeight = try c.decode(Int.self, forKey: .imageHeight)
        face = try c.decodeIfPresent(FaceRig.self, forKey: .face)
        accent = try c.decode(RGB.self, forKey: .accent)
        cardHeightMeters = try c.decode(Float.self, forKey: .cardHeightMeters)
        mouthStrength = try c.decode(Float.self, forKey: .mouthStrength)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        captureSource = try c.decodeIfPresent(CaptureSource.self, forKey: .captureSource)
            ?? (kind == .placeholder ? .generated : .photoLibrary)
        hasDepth = try c.decodeIfPresent(Bool.self, forKey: .hasDepth) ?? false
        capturedOn = try c.decodeIfPresent(String.self, forKey: .capturedOn)
        hasSplats = try c.decodeIfPresent(Bool.self, forKey: .hasSplats) ?? false
        splatCount = try c.decodeIfPresent(Int.self, forKey: .splatCount) ?? 0
        depthNearMeters = try c.decodeIfPresent(Float.self, forKey: .depthNearMeters)
        depthFarMeters = try c.decodeIfPresent(Float.self, forKey: .depthFarMeters)
    }

    var aspect: Float { imageHeight == 0 ? 1 : Float(imageWidth) / Float(imageHeight) }
    var cardWidthMeters: Float { cardHeightMeters * aspect }
}

/// 매니페스트 + 투명 배경 PNG 데이터. 네트워크로는 manifest 와 bodyPNG 만 전송된다.
nonisolated struct PersonaPackage: Sendable, Hashable {
    var manifest: PersonaManifest
    var bodyPNG: Data
    /// 깊이 카메라로 찍었을 때의 8비트 깊이 맵 PNG (가까울수록 밝음). 로컬 저장 전용.
    var depthPNG: Data?
    /// 각도별 보조 촬영(좌/우/위). 스플랫 측면 색 채우기와 v2 입체화에 쓴다.
    var sideViews: [String: Data] = [:]
    /// 가우시안 스플랫 클라우드(`SplatCloud.encode()`).
    var splats: Data?

    init(manifest: PersonaManifest, bodyPNG: Data, depthPNG: Data? = nil, sideViews: [String: Data] = [:], splats: Data? = nil) {
        self.manifest = manifest
        self.bodyPNG = bodyPNG
        self.depthPNG = depthPNG
        self.sideViews = sideViews
        self.splats = splats
    }
}

/// 깊이 카메라에서 받은 미터 단위 깊이 맵 (행 우선, 좌상단 원점, 유효하지 않으면 NaN).
nonisolated struct DepthMap: Sendable {
    var width: Int
    var height: Int
    var meters: [Float]

    func value(u: Double, v: Double) -> Float {
        let x = min(width - 1, max(0, Int(u * Double(width))))
        let y = min(height - 1, max(0, Int(v * Double(height))))
        return meters[y * width + x]
    }
}

// MARK: - Live pose

/// 15Hz 로 전송되는 "살아있는" 페르소나 상태. 머리 자세, 입, 손 위치.
nonisolated struct PersonaPose: Codable, Hashable, Sendable {
    /// 좌석 정면 기준 머리 회전(rad).
    var yaw: Float = 0
    var pitch: Float = 0
    var roll: Float = 0
    /// 앉은 자리에서의 머리 이동(m).
    var offset: SIMD3<Float> = .zero
    /// 0...1 입 벌림.
    var mouth: Float = 0
    var speaking: Bool = false
    /// 머리 기준 손 위치(m). 없으면 손을 그리지 않는다.
    var leftHand: SIMD3<Float>?
    var rightHand: SIMD3<Float>?
    /// 손들기 등 간단한 제스처 상태.
    var handRaised: Bool = false

    static let rest = PersonaPose()

    func blended(toward target: PersonaPose, _ t: Float) -> PersonaPose {
        var out = target
        out.yaw = yaw + (target.yaw - yaw) * t
        out.pitch = pitch + (target.pitch - pitch) * t
        out.roll = roll + (target.roll - roll) * t
        out.offset = offset + (target.offset - offset) * t
        out.mouth = mouth + (target.mouth - mouth) * min(1, t * 1.6)
        if let a = leftHand, let b = target.leftHand { out.leftHand = a + (b - a) * t }
        if let a = rightHand, let b = target.rightHand { out.rightHand = a + (b - a) * t }
        return out
    }
}

/// 테이블 위에 잠깐 떠오르는 반응.
nonisolated enum Reaction: String, Codable, CaseIterable, Sendable {
    case wave = "👋"
    case thumbsUp = "👍"
    case heart = "❤️"
    case laugh = "😂"
    case tea = "🍵"
    case clap = "👏"

    var label: String {
        switch self {
        case .wave: "손인사"
        case .thumbsUp: "좋아요"
        case .heart: "하트"
        case .laugh: "웃음"
        case .tea: "차 한 잔"
        case .clap: "박수"
        }
    }
}
