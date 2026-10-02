import Foundation
import CoreGraphics
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 사진에서 읽은 **외형 힌트**. 입체화에서 머리카락 범위·볼륨의 초기값에만 쓴다 (좌표는 Vision 랜드마크만 신뢰).
///
/// 출처는 두 가지: Apple Intelligence 온디바이스 언어 모델(`FoundationModels`, 사진 첨부 → `@Generable` 구조체) 또는
/// 모델을 쓸 수 없을 때(시뮬레이터·Apple Intelligence 꺼짐·시간 초과) 리그/색 기반 휴리스틱.
nonisolated struct AppearanceHints: Codable, Hashable, Sendable {
    nonisolated enum HairLength: String, Codable, Sendable { case short, medium, long }
    nonisolated enum Level: String, Codable, Sendable { case low, medium, high }

    var hairLength: HairLength = .medium
    var hairVolume: Level = .medium
    var hasBangs = false
    var wearsGlasses = false
    var shouldersVisible = true
    /// "FoundationModels" / "heuristic"
    var source: String = "heuristic"

    /// 머리카락 돔 두께 배율.
    var hairDepthScale: Float {
        switch hairVolume { case .low: 0.7; case .medium: 1.0; case .high: 1.4 }
    }
    /// 목선 아래로 머리카락을 인정하는 범위 (카드 높이 비율).
    var hairReachBelowNeck: Float {
        switch hairLength { case .short: 0.04; case .medium: 0.14; case .long: 0.38 }
    }

    var summary: String {
        var parts: [String] = []
        parts.append(hairLength == .long ? "긴 머리" : (hairLength == .short ? "짧은 머리" : "중간 머리"))
        parts.append(hairVolume == .high ? "볼륨 큼" : (hairVolume == .low ? "볼륨 작음" : "볼륨 보통"))
        if hasBangs { parts.append("앞머리") }
        if wearsGlasses { parts.append("안경") }
        parts.append(shouldersVisible ? "어깨 보임" : "어깨 안 보임")
        return parts.joined(separator: " · ") + (source == "FoundationModels" ? " (Apple Intelligence)" : " (휴리스틱)")
    }
}

#if canImport(FoundationModels)
@Generable
struct AppearanceReport {
    @Generable
    enum HairLength { case short, medium, long }
    @Generable
    enum Level { case low, medium, high }

    @Guide(description: "Hair length of the person: short (above ears), medium (to the jaw), long (past the shoulders)")
    var hairLength: HairLength
    @Guide(description: "How voluminous or thick the hair looks")
    var hairVolume: Level
    @Guide(description: "True if bangs or fringe cover part of the forehead")
    var hasBangs: Bool
    @Guide(description: "True if the person wears eyeglasses")
    var wearsGlasses: Bool
    @Guide(description: "True if the shoulders are visible in the photo")
    var shouldersVisible: Bool
}
#endif

/// 외형 힌트 분석기. 메인 액터에서 호출(FoundationModels 세션), 실제 추론은 시스템이 백그라운드에서 돌린다.
@MainActor
enum AppearanceAnalyzer {
    /// 8초 안에 모델 응답이 없거나 모델을 쓸 수 없으면 휴리스틱.
    static func analyze(image: CGImage, rig: FaceRig?) async -> AppearanceHints {
        if let hints = await analyzeWithFoundationModels(image: image) { return hints }
        return heuristic(image: image, rig: rig)
    }

    static var isModelAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    #if canImport(FoundationModels)
    /// 사진 첨부(`Attachment`)는 OS 27 부터. 그 이전 OS 에서는 휴리스틱으로 떨어진다.
    @available(iOS 27, macOS 27, visionOS 27, *)
    private static func respondWithImage(_ small: CGImage) async throws -> AppearanceHints {
        let session = LanguageModelSession(instructions: """
        You describe only coarse visual attributes of a person in a photo for a cartoon avatar. \
        Do not identify the person. Answer with the requested fields only.
        """)
        let response = try await session.respond(generating: AppearanceReport.self) {
            "Look at this photo of a person and fill in the appearance fields."
            Attachment(small)
        }
        let r = response.content
        var h = AppearanceHints()
        h.hairLength = switch r.hairLength { case .short: .short; case .medium: .medium; case .long: .long }
        h.hairVolume = switch r.hairVolume { case .low: .low; case .medium: .medium; case .high: .high }
        h.hasBangs = r.hasBangs
        h.wearsGlasses = r.wearsGlasses
        h.shouldersVisible = r.shouldersVisible
        h.source = "FoundationModels"
        return h
    }
    #endif

    private static func analyzeWithFoundationModels(image: CGImage) async -> AppearanceHints? {
        #if canImport(FoundationModels)
        guard isModelAvailable else { return nil }
        guard #available(iOS 27, macOS 27, visionOS 27, *) else { return nil }
        let small = PersonaBuilder.downscale(image, maxDimension: 512) ?? image
        let work = Task<AppearanceHints?, Never> {
            try? await respondWithImage(small)
        }
        let timeout = Task<AppearanceHints?, Never> {
            try? await Task.sleep(for: .seconds(8))
            return nil
        }
        // 먼저 끝나는 쪽
        let result = await withTaskGroup(of: AppearanceHints?.self, returning: AppearanceHints?.self) { group in
            group.addTask { await work.value }
            group.addTask { await timeout.value }
            let first = await group.next() ?? nil
            if first == nil, let second = await group.next() ?? nil { return second }
            group.cancelAll()
            work.cancel(); timeout.cancel()
            return first
        }
        return result
        #else
        return nil
        #endif
    }

    /// 리그·색 기반 휴리스틱 (모델 없을 때).
    nonisolated static func heuristic(image: CGImage, rig: FaceRig?) -> AppearanceHints {
        var h = AppearanceHints()
        h.source = "heuristic"
        guard let rig, let raster = try? RGBARaster(cgImage: image) else { return h }
        let W = Double(raster.width), H = Double(raster.height)
        let fb = rig.faceBox
        let skin = rig.skin
        func dist(_ a: RGB, _ b: RGB) -> Double { sqrt(pow(a.r - b.r, 2) + pow(a.g - b.g, 2) + pow(a.b - b.b, 2)) / 1.732 }
        func hairLike(_ c: RGB?) -> Bool {
            guard let c else { return false }
            if let hair = rig.hair { return dist(c, hair) < dist(c, skin) * 0.9 || dist(c, skin) > 0.22 }
            return dist(c, skin) > 0.22
        }
        // 긴 머리: 턱 아래 양옆(어깨 위)에 머리카락색 픽셀
        let chinY = fb.y + fb.height
        let sideL = CGRect(x: (fb.x - fb.width * 0.25) * W, y: (chinY + fb.height * 0.1) * H, width: fb.width * 0.2 * W, height: fb.height * 0.25 * H)
        let sideR = CGRect(x: (fb.x + fb.width * 1.05) * W, y: (chinY + fb.height * 0.1) * H, width: fb.width * 0.2 * W, height: fb.height * 0.25 * H)
        let longHair = hairLike(raster.averageColor(in: sideL)) || hairLike(raster.averageColor(in: sideR))
        let jawL = CGRect(x: (fb.x - fb.width * 0.22) * W, y: (fb.y + fb.height * 0.55) * H, width: fb.width * 0.18 * W, height: fb.height * 0.3 * H)
        let mediumHair = hairLike(raster.averageColor(in: jawL))
        h.hairLength = longHair ? .long : (mediumHair ? .medium : .short)
        // 앞머리: 이마 중앙(눈썹 위 ~ 헤어라인) 이 머리카락색
        let browV = rig.browLineV
        let forehead = CGRect(x: (fb.midX - fb.width * 0.15) * W, y: (browV - fb.height * 0.16) * H, width: fb.width * 0.3 * W, height: fb.height * 0.1 * H)
        h.hasBangs = hairLike(raster.averageColor(in: forehead))
        // 볼륨: 머리 위쪽 머리카락 폭이 얼굴 폭의 1.3배 이상이면 큼
        let topRow = max(0, (fb.y - fb.height * 0.15) * H)
        var minX = Int.max, maxX = Int.min
        var x = 0
        while x < raster.width {
            let i = (Int(topRow) * raster.width + x) * 4
            if raster.bytes[i + 3] > 40 { minX = min(minX, x); maxX = max(maxX, x) }
            x += 2
        }
        if minX <= maxX {
            let ratio = Double(maxX - minX) / max(1, fb.width * W)
            h.hairVolume = ratio > 1.3 ? .high : (ratio < 0.95 ? .low : .medium)
        }
        // 어깨: 카드 아래쪽 폭이 얼굴 폭의 1.6배 이상
        let bottomRow = min(raster.height - 1, Int(H * 0.92))
        minX = Int.max; maxX = Int.min; x = 0
        while x < raster.width {
            let i = (bottomRow * raster.width + x) * 4
            if raster.bytes[i + 3] > 40 { minX = min(minX, x); maxX = max(maxX, x) }
            x += 2
        }
        h.shouldersVisible = minX <= maxX && Double(maxX - minX) > fb.width * W * 1.6
        return h
    }
}
