import Foundation
import RealityKit
import SwiftUI
import simd

/// 테이블 렌더러가 다루는 아바타의 공통 인터페이스.
/// - `PersonaAvatar`: 실제 사용자 페르소나(카드 또는 스플랫, 스플랫이면 USDZ 얼굴 키트 부착)
/// - `DemoBustAvatar`: 블렌더 USDZ 데모 이용자 흉상 (FaceRig 블렌드셰이프)
/// - `PlaceholderBustAvatar`: 페르소나가 아직 도착하지 않은 자리의 반투명 흉상
@MainActor
protocol TableAvatar: AnyObject {
    var root: Entity { get }
    var label: AvatarLabelState { get }
    func update(target: PersonaPose, dt: Double, level: Float)
    func show(reaction: Reaction)
    /// 말할 문장이 있으면(TTS 자막) 비셈 큐로 넘긴다. 기본은 무시.
    func speak(text: String, duration: Double)
    /// 8차: 외부 ARKit 52 표정 신호. nil 이면 합성. 기본은 무시.
    func setExpression(_ weights: ArkitWeights?, includesBlink: Bool)
}

extension TableAvatar {
    func speak(text: String, duration: Double) {}
    func setExpression(_ weights: ArkitWeights?, includesBlink: Bool) {}
}

/// 글로우·손·이름표·반응처럼 아바타 종류와 무관한 장식.
@MainActor
struct AvatarDecor {
    let glow: ModelEntity
    let leftHand: ModelEntity
    let rightHand: ModelEntity
    let labelEntity = Entity()
    let reactionEntity = Entity()

    init(accent: RGB, cardHeight: Float, cardWidth: Float, label: AvatarLabelState) throws {
        let accentColor = PlatformColor(red: accent.r, green: accent.g, blue: accent.b, alpha: 0.55)
        var handMaterial = UnlitMaterial(color: accentColor)
        handMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.55))
        leftHand = ModelEntity(mesh: .generateSphere(radius: 0.045), materials: [handMaterial])
        rightHand = ModelEntity(mesh: .generateSphere(radius: 0.045), materials: [handMaterial])
        leftHand.isEnabled = false
        rightHand.isEnabled = false

        let texture = try TextureResource(image: TextureFactory.softDisc(color: accent), options: .init(semantic: .color))
        var glowMaterial = UnlitMaterial()
        glowMaterial.color = .init(tint: .white, texture: .init(texture))
        glowMaterial.blending = .transparent(opacity: .init(floatLiteral: 1))
        glow = ModelEntity(mesh: .generatePlane(width: 0.6, depth: 0.6), materials: [glowMaterial])
        glow.position = SIMD3(0, -cardHeight / 2 - 0.08, 0)
        glow.components.set(OpacityComponent(opacity: 0.35))

        #if os(visionOS)
        labelEntity.position = SIMD3(0, cardHeight / 2 + 0.07, 0.01)
        labelEntity.components.set(ViewAttachmentComponent(rootView: AvatarNameplate(state: label)))
        reactionEntity.position = SIMD3(cardWidth / 2 + 0.05, cardHeight / 2 - 0.1, 0.02)
        reactionEntity.components.set(ViewAttachmentComponent(rootView: AvatarReactionBubble(state: label)))
        #endif
    }

    func attach(to root: Entity) {
        root.addChild(leftHand)
        root.addChild(rightHand)
        root.addChild(glow)
        #if os(visionOS)
        root.addChild(labelEntity)
        root.addChild(reactionEntity)
        #endif
    }

    func placeHands(_ pose: PersonaPose, headCenter: SIMD3<Float>) {
        func place(_ hand: ModelEntity, _ rel: SIMD3<Float>?) {
            guard let rel else { hand.isEnabled = false; return }
            hand.isEnabled = true
            let c = simd_clamp(rel, SIMD3(repeating: -0.7), SIMD3(repeating: 0.7))
            // 머리 좌표계: x 오른쪽, y 위, z 뒤. 아바타: +z 앞.
            hand.position = headCenter + SIMD3(c.x, c.y, -c.z * 0.6 + 0.03)
        }
        place(leftHand, pose.leftHand)
        place(rightHand, pose.rightHand)
    }

    func updateGlow(level: Float, pose: PersonaPose) {
        let opacity: Float = 0.25 + 0.6 * max(level, pose.speaking ? 0.4 : 0)
        glow.components.set(OpacityComponent(opacity: opacity))
        glow.scale = SIMD3(repeating: 1 + 0.25 * max(level, pose.mouth))
    }
}

// MARK: - Demo bust (Blender USDZ)

/// 블렌더에서 만든 데모 이용자 흉상. 깜빡임·시선·입 모양은 `FaceRigSystem` 이 블렌드셰이프로 구동하고,
/// 여기서는 고개(yaw/pitch/roll)·이동·손·글로우·이름표만 다룬다.
final class DemoBustAvatar: TableAvatar {
    static let bustScale: Float = 1.25
    /// 흉상(0.566 m) × 스케일 ≈ 카드 높이와 비슷하게.
    static var cardHeight: Float { FaceKitSex.crown * bustScale + 0.1 }

    let avatar: DemoAvatar
    let root = Entity()
    let label = AvatarLabelState()
    private let pivotNode = Entity()
    private var bust: Entity?
    private let decor: AvatarDecor
    private var pose = PersonaPose.rest
    private var time: Double = 0
    private let breathPhase = Float.random(in: 0...(2 * .pi))
    private var pendingSpeech: (String, Double)?
    private(set) var isLoaded = false
    private(set) var loadError: String?
    private var externalExpression: ArkitWeights?
    private var externalIncludesBlink = false

    /// 흉상 바닥을 카드 아랫변에 맞추기 위한 로컬 오프셋. 루트는 카드 중심에 놓인다.
    private var bottomY: Float { -Self.cardHeight / 2 }
    /// 머리 중심(눈 높이) 로컬 위치.
    private var headCenter: SIMD3<Float> { SIMD3(0, bottomY + FaceKitSex.eyeHeight * Self.bustScale, 0) }

    init(avatar: DemoAvatar, name: String) throws {
        self.avatar = avatar
        decor = try AvatarDecor(accent: avatar.accent, cardHeight: Self.cardHeight,
                                cardWidth: 0.5, label: label)
        label.name = name
        // 목 높이를 회전축으로
        let neckY = bottomY + 0.33 * Self.bustScale
        pivotNode.position = SIMD3(0, neckY, 0)
        root.addChild(pivotNode)
        decor.attach(to: root)
        Task { await load() }
    }

    private func load() async {
        do {
            let e = try await SobanFaceAssets.makeDemoAvatar(avatar)
            e.scale = SIMD3(repeating: Self.bustScale)
            // pivotNode 가 neckY 에 있으므로 흉상 바닥은 그만큼 아래로
            e.position = SIMD3(0, bottomY - pivotNode.position.y, 0)
            pivotNode.addChild(e)
            bust = e
            isLoaded = true
            if let (text, duration) = pendingSpeech {
                speak(text: text, duration: duration)
                pendingSpeech = nil
            }
        } catch {
            loadError = "데모 아바타 로드 실패: \(error.localizedDescription)"
        }
    }

    func update(target: PersonaPose, dt: Double, level: Float) {
        time += dt
        pose = pose.blended(toward: target, Float(min(1, dt * 10)))
        let sway = 0.01 * sin(Float(time) * 0.7 + breathPhase)
        let yaw = simd_quatf(angle: pose.yaw * 0.9, axis: SIMD3(0, 1, 0))
        let pitch = simd_quatf(angle: -pose.pitch * 0.6, axis: SIMD3(1, 0, 0))
        let roll = simd_quatf(angle: pose.roll * 0.5 + sway, axis: SIMD3(0, 0, 1))
        pivotNode.orientation = yaw * pitch * roll
        let offset = simd_clamp(pose.offset, SIMD3(repeating: -0.25), SIMD3(repeating: 0.25))
        let neckY = bottomY + 0.33 * Self.bustScale
        pivotNode.position = SIMD3(offset.x, neckY + offset.y + 0.006 * sin(Float(time) * 1.6 + breathPhase), offset.z * 0.5)
        let breath = 1 + 0.01 * sin(Float(time) * 1.6 + breathPhase)
        pivotNode.scale = SIMD3(1, breath, 1)

        if let bust, var rig = bust.components[FaceRigComponent.self] {
            rig.audioLevel = min(1, max(level, pose.mouth))
            rig.smile = pose.speaking ? 0.1 : 0.25
            rig.externalWeights = externalExpression
            rig.externalIncludesBlink = externalIncludesBlink
            bust.components.set(rig)
        }

        decor.placeHands(pose, headCenter: headCenter)
        decor.updateGlow(level: level, pose: pose)
        label.isSpeaking = pose.speaking || level > 0.15
        label.handRaised = pose.handRaised
        if let (_, at) = label.reaction, Date().timeIntervalSince(at) > 2.4 { label.reaction = nil }
    }

    func show(reaction: Reaction) {
        label.reaction = (reaction, Date())
    }

    func setExpression(_ weights: ArkitWeights?, includesBlink: Bool) {
        externalExpression = weights
        externalIncludesBlink = includesBlink
    }

    /// TTS 자막 → 한글 모음 비셈 큐. 전체 길이를 음절 수로 나눠 TTS 와 보조를 맞춘다.
    func speak(text: String, duration: Double) {
        guard let bust, var rig = bust.components[FaceRigComponent.self] else {
            pendingSpeech = (text, duration)
            return
        }
        let syllables = max(1, text.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count)
        let perSyllable = Float(duration) / Float(syllables) * 0.9
        rig.visemeQueue.removeAll()
        rig.speak(text: text, secondsPerSyllable: max(0.08, min(0.3, perSyllable)))
        bust.components.set(rig)
    }
}

// MARK: - Placeholder bust

/// 페르소나(카드·스플랫)가 아직 도착하지 않은 참가자 자리에 놓는 반투명 사람 윤곽.
final class PlaceholderBustAvatar: TableAvatar {
    let root = Entity()
    let label = AvatarLabelState()
    private let decor: AvatarDecor
    private var pose = PersonaPose.rest
    private var time: Double = 0
    private var bust: Entity?
    private let holder = Entity()

    init(name: String, accent: RGB = .accentDefault) throws {
        decor = try AvatarDecor(accent: accent, cardHeight: DemoBustAvatar.cardHeight, cardWidth: 0.5, label: label)
        label.name = name
        holder.position = SIMD3(0, -DemoBustAvatar.cardHeight / 2, 0)
        root.addChild(holder)
        decor.attach(to: root)
        Task { await load() }
    }

    private func load() async {
        guard let e = try? await SobanFaceAssets.makeSplatPlaceholder(opacity: 0.45) else { return }
        e.scale = SIMD3(repeating: DemoBustAvatar.bustScale)
        holder.addChild(e)
        bust = e
    }

    func update(target: PersonaPose, dt: Double, level: Float) {
        time += dt
        pose = pose.blended(toward: target, Float(min(1, dt * 10)))
        holder.orientation = simd_quatf(angle: pose.yaw * 0.7, axis: SIMD3(0, 1, 0))
        // 숨 쉬듯 투명도 흔들림
        bust?.components.set(OpacityComponent(opacity: 0.38 + 0.08 * sin(Float(time) * 1.5)))
        decor.updateGlow(level: level, pose: pose)
        label.isSpeaking = level > 0.15
    }

    func show(reaction: Reaction) {
        label.reaction = (reaction, Date())
    }
}
