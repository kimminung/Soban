//
//  SobanFaceAssets.swift
//  Soban
//
//  USDZ 로더 + 플레이스홀더 교체 + 스플랫 완료 후 눈꺼풀/입 부착.
//  (블렌더 MCP 에셋과 함께 들어온 원본을 소반 멀티플랫폼 빌드에 맞게 손봤다: UIColor → PlatformColor, 프로토타입 캐시 + clone)
//
//  좌표계 (모든 USDZ 공통, 단위 m, Y-up, 얼굴이 +Z 를 바라봄)
//    y = 0      : 흉상 바닥(가슴 절단면)
//    y ≈ 0.44   : 눈 높이 (양 눈 중심 x = ±0.032)
//    y ≈ 0.357  : 입 중심
//    y ≈ 0.566  : 정수리
//  → 가우시안 스플랫을 이 "흉상 공간"으로 정규화해두면 눈꺼풀/입이 별도 오프셋 없이 맞습니다.
//     소반에서는 반대로 키트를 페르소나의 얼굴 리그(눈 중심·입 중심) 위치로 옮기고 눈 간격으로 스케일을 맞춥니다.
//

import RealityKit
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum DemoAvatar: String, CaseIterable, Sendable {
    case ethan  = "DemoAvatar_Ethan"    // 남 · 갈색 단발 커트 · 파란 눈 · 네이비 니트
    case olivia = "DemoAvatar_Olivia"   // 여 · 금발 롱헤어 · 초록 눈 · 크림 블라우스
    case lucas  = "DemoAvatar_Lucas"    // 남 · 다크브라운 곱슬 · 헤이즐 눈 · 안경 · 올리브 후디
    case emma   = "DemoAvatar_Emma"     // 여 · 적갈색 앞머리 단발 · 파란 눈 · 코랄 상의

    /// 이름표에 쓰는 한글 표기.
    var displayName: String {
        switch self {
        case .ethan: "에단"
        case .olivia: "올리비아"
        case .lucas: "루카스"
        case .emma: "엠마"
        }
    }

    var sex: FaceKitSex {
        switch self {
        case .ethan, .lucas: .male
        case .olivia, .emma: .female
        }
    }

    /// TTS 음높이 (손님마다 다르게).
    var voicePitch: Float {
        switch self {
        case .ethan: 0.92
        case .olivia: 1.22
        case .lucas: 0.82
        case .emma: 1.12
        }
    }

    /// 자리 카드·글로우 포인트 색 (의상색).
    var accent: RGB {
        switch self {
        case .ethan: RGB(r: 0.16, g: 0.24, b: 0.45)   // 네이비
        case .olivia: RGB(r: 0.93, g: 0.88, b: 0.78)  // 크림
        case .lucas: RGB(r: 0.42, g: 0.48, b: 0.28)   // 올리브
        case .emma: RGB(r: 0.95, g: 0.50, b: 0.42)    // 코랄
        }
    }
}

enum FaceKitSex: String, Sendable, CaseIterable {
    case male = "Male", female = "Female"
    var eyesAsset: String { "SplatFace_Eyes_\(rawValue)" }     // 눈알 2개 + 눈꺼풀(깜빡임)
    var mouthAsset: String { "SplatFace_Mouth_\(rawValue)" }   // 입술 + 치아 + 입 안

    var label: String { self == .male ? "남성형" : "여성형" }

    /// 흉상 공간 기준 눈 높이 / 입 높이 / 눈 간격.
    static let eyeHeight: Float = 0.44
    static let mouthHeight: Float = 0.357
    static let eyeSpacing: Float = 0.064
    static let crown: Float = 0.566
}

/// USDZ 는 한 번만 디스크에서 읽고(4.8 MB 씩) 이후엔 복제해서 쓴다.
@MainActor
final class FaceAssetLoader {
    static let shared = FaceAssetLoader()
    private var prototypes: [String: Entity] = [:]
    private var inflight: [String: Task<Entity, any Error>] = [:]

    func entity(named name: String) async throws -> Entity {
        if let proto = prototypes[name] { return proto.clone(recursive: true) }
        if let task = inflight[name] { return try await task.value.clone(recursive: true) }
        let task = Task<Entity, any Error> { try await Entity(named: name) }
        inflight[name] = task
        defer { inflight[name] = nil }
        let proto = try await task.value
        prototypes[name] = proto
        return proto.clone(recursive: true)
    }

    /// 번들에 에셋이 들어 있는지 (빌드 누락 진단용).
    nonisolated static func isBundled(_ name: String) -> Bool {
        Bundle.main.url(forResource: name, withExtension: "usdz") != nil
            || Bundle.main.url(forResource: name, withExtension: "reality") != nil
    }
}

@MainActor
enum SobanFaceAssets {

    // MARK: 1. 페르소나가 아직 없을 때 플레이스홀더 (사람 윤곽 흉상)

    static func makeSplatPlaceholder(opacity: Float = 0.55) async throws -> Entity {
        let bust = try await FaceAssetLoader.shared.entity(named: "SplatPlaceholder_Bust")
        bust.name = "SplatPlaceholder"
        bust.components.set(OpacityComponent(opacity: opacity))
        return bust
    }

    /// 기존 플레이스홀더를 교체할 때 사용 (위치/회전/스케일 유지)
    static func replacePlaceholder(_ old: Entity) async throws -> Entity {
        let bust = try await makeSplatPlaceholder()
        bust.transform = old.transform
        old.parent?.addChild(bust)
        old.removeFromParent()
        return bust
    }

    // MARK: 2. 데모 이용자 아바타

    static func makeDemoAvatar(_ avatar: DemoAvatar) async throws -> Entity {
        let e = try await FaceAssetLoader.shared.entity(named: avatar.rawValue)
        e.name = avatar.rawValue
        e.components.set(FaceRigComponent())
        return e
    }

    // MARK: 3. 스플랫 완료 후 눈(눈알+눈꺼풀) + 입

    /// 눈과 입을 **따로** 불러온다. 소반은 두 엔티티를 페르소나의 눈 중심/입 중심에 각각 맞춰 놓는다.
    static func loadFaceKit(sex: FaceKitSex, skinTint: PlatformColor? = nil, irisTint: PlatformColor? = nil)
        async throws -> (eyes: Entity, mouth: Entity) {
        let eyes = try await FaceAssetLoader.shared.entity(named: sex.eyesAsset)
        let mouth = try await FaceAssetLoader.shared.entity(named: sex.mouthAsset)
        if let skinTint { tintEyelidSkin(in: eyes, color: skinTint) }   // 밝은(피부) 머티리얼만, 속눈썹 라인은 유지
        if let irisTint {
            eyes.forEachDescendant { e in
                if e.name.hasSuffix("_Eye_L") || e.name.hasSuffix("_Eye_R") {
                    replaceMaterial(e, index: 1, color: irisTint, roughness: 0.2)   // 0 흰자, 1 홍채, 2 동공
                }
            }
        }
        return (eyes, mouth)
    }

    // MARK: 3b. 페르소나 사진 위에 올릴 때: 눈알은 숨기고 눈꺼풀만, 입술은 색 맞춤

    /// 눈 에셋에서 **눈꺼풀만 남긴다**. 흰자·홍채·동공 모델은 비활성화해 사진의 실제 눈이 그대로 보이고,
    /// 깜빡일 때만 눈꺼풀(피부색)이 덮인다. 숨기기 전에 눈알 중심/반지름을 읽어 돌려준다.
    struct EyeGeometry {
        var centers: [SIMD3<Float>]      // 눈알 중심 (에셋 루트 기준)
        var eyeballRadius: Float         // 눈알 반지름 (에셋 단위)
        var lidBounds: BoundingBox?      // 눈꺼풀 전체 바운즈 (에셋 루트 기준)
        var lidEntities: [Entity]        // 눈꺼풀 모델 엔티티
    }

    static func isEyelidName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("lid") || n.contains("lash")
    }

    static func isEyeballName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix("_eye_l") || n.hasSuffix("_eye_r") || n.contains("sclera") || n.contains("iris") || n.contains("pupil")
            || n.contains("eyeball") || n.contains("cornea")
    }

    @discardableResult
    static func keepOnlyEyelids(in eyes: Entity) -> EyeGeometry {
        var centers: [SIMD3<Float>] = []
        var radii: [Float] = []
        var lids: [Entity] = []
        var lidBounds: BoundingBox?
        eyes.forEachDescendant { e in
            let isEye = e.name.hasSuffix("_Eye_L") || e.name.hasSuffix("_Eye_R")
            let parentIsEye = e.parent.map { $0.name.hasSuffix("_Eye_L") || $0.name.hasSuffix("_Eye_R") } ?? false
            if isEye && !parentIsEye {
                let bb = e.visualBounds(relativeTo: eyes)
                centers.append(bb.center)
                radii.append(max(bb.extents.x, bb.extents.y) / 2)
            }
        }
        // 눈꺼풀 여부는 자기 이름 또는 조상 이름으로 판단. 눈꺼풀이 아닌 모델은 전부 숨긴다.
        func hasLidAncestor(_ e: Entity) -> Bool {
            var cur: Entity? = e
            while let c = cur, c !== eyes {
                if isEyelidName(c.name) { return true }
                cur = c.parent
            }
            return false
        }
        eyes.forEachDescendant { e in
            guard e.components.has(ModelComponent.self) else { return }
            if hasLidAncestor(e) {
                lids.append(e)
                let bb = e.visualBounds(relativeTo: eyes)
                lidBounds = lidBounds.map { $0.union(bb) } ?? bb
            } else {
                e.isEnabled = false
            }
        }
        // 눈알 모델을 못 찾았으면(이름 규칙이 다르면) 눈꺼풀 바운즈로 추정
        if centers.isEmpty, let lb = lidBounds {
            let half = lb.extents.x / 4
            centers = [SIMD3(lb.center.x - half, lb.center.y, lb.center.z), SIMD3(lb.center.x + half, lb.center.y, lb.center.z)]
            radii = [lb.extents.y / 2]
        }
        let radius = radii.isEmpty ? 0.012 : radii.reduce(0, +) / Float(radii.count)
        return EyeGeometry(centers: centers, eyeballRadius: radius, lidBounds: lidBounds, lidEntities: lids)
    }

    /// 머티리얼 틴트의 sRGB 성분 (PBR 머티리얼이 아니거나 색을 못 읽으면 nil).
    static func tintRGB(of material: any Material) -> (r: Float, g: Float, b: Float)? {
        guard let pbr = material as? PhysicallyBasedMaterial else { return nil }
        let cg = pbr.baseColor.tint.cgColor
        let srgb = cg.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? cg
        guard let c = srgb.components, c.count >= 3 else { return nil }
        return (Float(c[0]), Float(c[1]), Float(c[2]))
    }

    /// 입 에셋(블렌더 USDZ 는 입술·치아·입 안이 **한 메시의 머티리얼 4개**)에서 **입술색 머티리얼**(붉고 중간 명도)만
    /// 페르소나 입술색으로 바꾼다. 치아(밝음)·입 안(어두움)은 그대로. 이름으로 못 찾을 때를 대비해 색으로 고른다.
    static func tintLips(in mouth: Entity, color: PlatformColor) {
        mouth.forEachDescendant { e in
            guard var model = e.components[ModelComponent.self] else { return }
            var changed = false
            for i in model.materials.indices {
                guard let t = tintRGB(of: model.materials[i]) else { continue }
                let lum = 0.2126 * t.r + 0.7152 * t.g + 0.0722 * t.b
                let reddish = t.r > t.g * 1.2 && t.r > t.b * 1.2
                // 블렌더 키트 측정값: 입술 (0.76,0.50,0.47) · 잇몸/혀 (0.53,0.35,0.33) · 입 안 (0.18,0.05,0.06) · 치아 (0.93,0.91,0.86)
                guard reddish, lum > 0.45, lum < 0.8 else { continue }
                var m = PhysicallyBasedMaterial()
                m.baseColor = .init(tint: color)
                m.roughness = .init(floatLiteral: 0.45)
                m.specular = .init(floatLiteral: 0.3)
                model.materials[i] = m
                changed = true
            }
            if changed { e.components.set(model) }
        }
    }

    /// 눈꺼풀 메시의 **피부색 머티리얼**(밝은 것)만 페르소나 피부색으로. 속눈썹 라인(어두움)은 그대로.
    static func tintEyelidSkin(in eyes: Entity, color: PlatformColor) {
        eyes.forEachDescendant { e in
            guard isEyelidName(e.name), var model = e.components[ModelComponent.self] else { return }
            var changed = false
            for i in model.materials.indices {
                guard let t = tintRGB(of: model.materials[i]) else { continue }
                let lum = 0.2126 * t.r + 0.7152 * t.g + 0.0722 * t.b
                guard lum > 0.3 else { continue }
                var m = PhysicallyBasedMaterial()
                m.baseColor = .init(tint: color)
                m.roughness = .init(floatLiteral: 0.6)
                model.materials[i] = m
                changed = true
            }
            if changed { e.components.set(model) }
        }
    }

    /// 입술 부분의 바운즈 (에셋 루트 기준). 입술이 따로 떨어진 엔티티가 아니면 입 전체 바운즈(블렌더 키트: 입술 폭 = 메시 폭).
    static func lipsBounds(in mouth: Entity) -> BoundingBox {
        var bb: BoundingBox?
        mouth.forEachDescendant { e in
            guard e.name.lowercased().contains("lip"), e.components.has(ModelComponent.self) else { return }
            let b = e.visualBounds(relativeTo: mouth)
            bb = bb.map { $0.union(b) } ?? b
        }
        return bb ?? mouth.visualBounds(relativeTo: mouth)
    }

    #if DEBUG
    /// 계층 덤프 (에셋 이름 규칙 확인용).
    static func dumpHierarchy(_ root: Entity) {
        var out = ""
        func walk(_ e: Entity, _ indent: String) {
            let model = e.components[ModelComponent.self].map { mc in
                " [model " + mc.materials.map { m in tintRGB(of: m).map { String(format: "(%.2f,%.2f,%.2f)", $0.r, $0.g, $0.b) } ?? "?" }.joined(separator: " ") + "]"
            } ?? ""
            var bs = ""
            if let model = e.components[ModelComponent.self] {
                let mapping = BlendShapeWeightsMapping(meshResource: model.mesh)
                let names = BlendShapeWeightsComponent(weightsMapping: mapping).weightSet.flatMap { $0.weightNames }
                    .map { $0.split(separator: "/").last.map(String.init) ?? $0 }
                if !names.isEmpty { bs = " [blend \(names.count): \(names.joined(separator: ","))]" }
            }
            let bb = e.components.has(ModelComponent.self) ? " bounds=\(e.visualBounds(relativeTo: root))" : ""
            out += "\(indent)\(e.name.isEmpty ? "<unnamed>" : e.name)\(model)\(bs) enabled=\(e.isEnabled)\(bb)\n"
            for c in e.children { walk(c, indent + "  ") }
        }
        walk(root, "")
        print(out)
        // 시뮬레이터에서는 stdout 을 보기 어려워 tmp 파일에도 남긴다 (simctl get_app_container data 로 확인)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("soban-kit-dump.txt")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(out.utf8)); try? h.close() }
        else { try? out.write(to: url, atomically: true, encoding: .utf8) }
    }
    #endif

    /// - splatRoot: 흉상 공간으로 정규화된 가우시안 스플랫 엔티티 (원본 API 유지)
    @discardableResult
    static func attachFaceKit(to splatRoot: Entity,
                              sex: FaceKitSex,
                              skinTint: PlatformColor? = nil,
                              irisTint: PlatformColor? = nil,
                              faceOffset: SIMD3<Float> = .zero) async throws -> Entity {
        let kit = Entity()
        kit.name = "SplatFaceKit_\(sex.rawValue)"
        kit.position = faceOffset
        let (eyes, mouth) = try await loadFaceKit(sex: sex, skinTint: skinTint, irisTint: irisTint)
        kit.addChild(eyes)
        kit.addChild(mouth)
        kit.components.set(FaceRigComponent())
        splatRoot.addChild(kit)
        return kit
    }

    static func replaceMaterial(_ root: Entity, index: Int, color: PlatformColor, roughness: Float) {
        root.forEachDescendant { e in
            guard var model = e.components[ModelComponent.self], model.materials.count > index else { return }
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: color)
            m.roughness = .init(floatLiteral: roughness)
            model.materials[index] = m
            e.components.set(model)
        }
    }

    static func color(_ rgb: RGB, alpha: CGFloat = 1) -> PlatformColor {
        PlatformColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }
}
