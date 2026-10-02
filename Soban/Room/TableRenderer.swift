#if os(visionOS)
import Foundation
import RealityKit
import CoreGraphics
import simd

/// 렌더러가 매 틱 받아 가는 참가자 스냅샷.
struct RenderableParticipant {
    var id: UUID
    var slot: Int
    var manifest: PersonaManifest?
    var image: CGImage?
    var splats: SplatCloud?
    var pose: PersonaPose
    var level: Float
    /// 데모 손님이면 블렌더 USDZ 흉상.
    var demoAvatar: DemoAvatar?
    var displayName: String
}

/// 테이블 세트 + 참가자 아바타를 RealityKit 엔티티로 유지한다. `GatheringSession` 틱에서 `sync` 호출.
///
/// 아바타 종류
/// - 데모 손님 → `DemoBustAvatar` (블렌더 USDZ, FaceRig 블렌드셰이프)
/// - 페르소나 도착 → `PersonaAvatar` (카드 또는 스플랫 + USDZ 얼굴 키트)
/// - 아직 페르소나 없음 → `PlaceholderBustAvatar` (반투명 흉상)
final class TableRenderer {
    static let mirrorScale: Float = 0.6

    /// 아바타를 다시 만들어야 하는지 판단하는 키.
    private struct AvatarKey: Equatable {
        var personaID: UUID?
        var splatCount: Int
        var demo: DemoAvatar?
        var placeholder: Bool
    }

    let root = Entity()
    private(set) var layout: TableLayout
    private var sceneEntity: Entity?
    private var avatars: [UUID: any TableAvatar] = [:]
    private var avatarKeys: [UUID: AvatarKey] = [:]
    private var selfAvatar: (any TableAvatar)?
    private var selfKey: AvatarKey?
    private var lastTime: Double?

    /// 빌보딩 기준이 되는 뷰어(내 머리) 위치.
    var viewerPosition = SIMD3<Float>(0, 1.2, 0)

    init(distance: Float) {
        layout = TableLayout(distance: distance)
        rebuildScene()
    }

    func setDistance(_ distance: Float) {
        guard abs(layout.distance - distance) > 0.001 else { return }
        layout = TableLayout(distance: distance)
        rebuildScene()
    }

    private func rebuildScene() {
        sceneEntity?.removeFromParent()
        let scene = TableScene.build(layout: layout)
        root.addChild(scene)
        sceneEntity = scene
    }

    func worldPosition(forSlot slot: Int, cardHeight: Float = 0.8) -> SIMD3<Float> {
        layout.personaPosition(slot: slot, cardHeight: cardHeight)
    }

    /// - Parameters:
    ///   - participants: 나를 제외한 참가자들
    ///   - selfParticipant: "내 모습 보기" 가 켜져 있을 때 거울로 보여 줄 나
    ///   - speeches: 데모 손님 TTS 문장 (비셈 큐)
    func sync(_ participants: [RenderableParticipant], selfParticipant: RenderableParticipant?,
              reactions: [(UUID, Reaction)], speeches: [(UUID, String, Double)] = [], now: Double) {
        let dt = lastTime.map { min(0.1, now - $0) } ?? (1.0 / 30.0)
        lastTime = now

        var seen = Set<UUID>()
        for p in participants {
            seen.insert(p.id)
            let hasPersona = p.manifest != nil && p.image != nil
            let demo = p.demoAvatar ?? p.manifest?.demoAvatarCase
            let key = AvatarKey(personaID: p.manifest?.id, splatCount: p.splats?.count ?? 0,
                                demo: demo, placeholder: !hasPersona && demo == nil)
            if avatarKeys[p.id] != key, let old = avatars[p.id] {
                old.root.removeFromParent()
                avatars[p.id] = nil
            }
            let avatar: any TableAvatar
            if let existing = avatars[p.id] {
                avatar = existing
            } else {
                guard let created = makeAvatar(for: p) else { continue }
                avatars[p.id] = created
                avatarKeys[p.id] = key
                root.addChild(created.root)
                avatar = created
            }
            let cardHeight = demo != nil ? DemoBustAvatar.cardHeight : (p.manifest?.cardHeightMeters ?? DemoBustAvatar.cardHeight)
            let position = layout.personaPosition(slot: p.slot, cardHeight: cardHeight)
            avatar.root.position = position
            avatar.root.orientation = billboard(from: position)
            avatar.update(target: p.pose, dt: dt, level: p.level)
        }
        for (id, reaction) in reactions {
            avatars[id]?.show(reaction: reaction)
            if id == selfParticipant?.id { selfAvatar?.show(reaction: reaction) }
        }
        for (id, text, duration) in speeches {
            avatars[id]?.speak(text: text, duration: duration)
        }
        for (id, avatar) in avatars where !seen.contains(id) {
            avatar.root.removeFromParent()
            avatars[id] = nil
            avatarKeys[id] = nil
        }

        // 거울
        if let me = selfParticipant, let manifest = me.manifest, let image = me.image {
            let demo = me.demoAvatar ?? manifest.demoAvatarCase
            let key = AvatarKey(personaID: manifest.id, splatCount: me.splats?.count ?? 0, demo: demo, placeholder: false)
            if selfKey != key, let old = selfAvatar {
                old.root.removeFromParent()
                selfAvatar = nil
            }
            if selfAvatar == nil {
                let created: (any TableAvatar)?
                if let demo {
                    created = try? DemoBustAvatar(avatar: demo, name: manifest.name)
                } else if let persona = try? PersonaAvatar(manifest: manifest, image: image, splats: me.splats) {
                    Task { await persona.attachFaceKitIfNeeded() }
                    created = persona
                } else {
                    created = nil
                }
                if let created {
                    selfKey = key
                    created.root.scale = SIMD3(repeating: Self.mirrorScale)
                    created.label.isMirror = true
                    root.addChild(created.root)
                    selfAvatar = created
                }
            }
            if let avatar = selfAvatar {
                let position = layout.mirrorPosition(cardHeight: demo != nil ? DemoBustAvatar.cardHeight : manifest.cardHeightMeters, scale: Self.mirrorScale)
                avatar.root.position = position
                avatar.root.orientation = billboard(from: position)
                // 거울: 좌우 반전
                var pose = me.pose
                pose.yaw = -pose.yaw
                pose.roll = -pose.roll
                pose.offset.x = -pose.offset.x
                if let h = pose.leftHand { pose.leftHand = SIMD3(-h.x, h.y, h.z) }
                if let h = pose.rightHand { pose.rightHand = SIMD3(-h.x, h.y, h.z) }
                avatar.update(target: pose, dt: dt, level: me.level)
            }
        } else if let avatar = selfAvatar {
            avatar.root.removeFromParent()
            selfAvatar = nil
            selfKey = nil
        }
    }

    private func makeAvatar(for p: RenderableParticipant) -> (any TableAvatar)? {
        // 데모 손님, 또는 흉상 샘플을 페르소나로 쓰는 참가자(원격 포함 — 매니페스트만 오면 그린다)
        if let demo = p.demoAvatar ?? p.manifest?.demoAvatarCase {
            return try? DemoBustAvatar(avatar: demo, name: p.displayName)
        }
        if let manifest = p.manifest, let image = p.image {
            guard let avatar = try? PersonaAvatar(manifest: manifest, image: image, splats: p.splats) else { return nil }
            Task { await avatar.attachFaceKitIfNeeded() }
            return avatar
        }
        return try? PlaceholderBustAvatar(name: p.displayName, accent: p.manifest?.accent ?? .accentDefault)
    }

    private func billboard(from position: SIMD3<Float>) -> simd_quatf {
        let toViewer = viewerPosition - position
        let yaw = atan2(toViewer.x, toViewer.z)
        return simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
    }

    func removeAll() {
        for (_, a) in avatars { a.root.removeFromParent() }
        avatars.removeAll()
        avatarKeys.removeAll()
        selfAvatar?.root.removeFromParent()
        selfAvatar = nil
        selfKey = nil
    }
}
#endif
