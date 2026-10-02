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
}

/// 테이블 세트 + 참가자 아바타를 RealityKit 엔티티로 유지한다. `GatheringSession` 틱에서 `sync` 호출.
final class TableRenderer {
    static let mirrorScale: Float = 0.6

    let root = Entity()
    private(set) var layout: TableLayout
    private var sceneEntity: Entity?
    private var avatars: [UUID: PersonaAvatar] = [:]
    private var avatarImageIDs: [UUID: UUID] = [:] // participant → persona id (이미지 교체 감지)
    private var avatarSplatCounts: [UUID: Int] = [:] // participant → 스플랫 개수 (입체 도착 감지)
    private var selfAvatar: PersonaAvatar?
    private var selfAvatarPersonaID: UUID?
    private var selfAvatarSplatCount = 0
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
    func sync(_ participants: [RenderableParticipant], selfParticipant: RenderableParticipant?,
              reactions: [(UUID, Reaction)], now: Double) {
        let dt = lastTime.map { min(0.1, now - $0) } ?? (1.0 / 30.0)
        lastTime = now

        var seen = Set<UUID>()
        for p in participants {
            seen.insert(p.id)
            guard let manifest = p.manifest, let image = p.image else { continue }
            let splatCount = p.splats?.count ?? 0
            if (avatarImageIDs[p.id] != manifest.id || avatarSplatCounts[p.id] != splatCount), let old = avatars[p.id] {
                old.root.removeFromParent()
                avatars[p.id] = nil
            }
            let avatar: PersonaAvatar
            if let existing = avatars[p.id] {
                avatar = existing
            } else {
                guard let created = try? PersonaAvatar(manifest: manifest, image: image, splats: p.splats) else { continue }
                avatars[p.id] = created
                avatarImageIDs[p.id] = manifest.id
                avatarSplatCounts[p.id] = splatCount
                root.addChild(created.root)
                avatar = created
            }
            let position = layout.personaPosition(slot: p.slot, cardHeight: manifest.cardHeightMeters)
            avatar.root.position = position
            avatar.root.orientation = billboard(from: position)
            avatar.update(target: p.pose, dt: dt, level: p.level)
        }
        for (id, reaction) in reactions {
            avatars[id]?.show(reaction: reaction)
            if id == selfParticipant?.id { selfAvatar?.show(reaction: reaction) }
        }
        for (id, avatar) in avatars where !seen.contains(id) {
            avatar.root.removeFromParent()
            avatars[id] = nil
            avatarImageIDs[id] = nil
            avatarSplatCounts[id] = nil
        }

        // 거울
        if let me = selfParticipant, let manifest = me.manifest, let image = me.image {
            if (selfAvatarPersonaID != manifest.id || selfAvatarSplatCount != (me.splats?.count ?? 0)), let old = selfAvatar {
                old.root.removeFromParent()
                selfAvatar = nil
            }
            if selfAvatar == nil, let created = try? PersonaAvatar(manifest: manifest, image: image, splats: me.splats) {
                selfAvatarSplatCount = me.splats?.count ?? 0
                created.root.scale = SIMD3(repeating: Self.mirrorScale)
                created.label.isMirror = true
                root.addChild(created.root)
                selfAvatar = created
                selfAvatarPersonaID = manifest.id
            }
            if let avatar = selfAvatar {
                let position = layout.mirrorPosition(cardHeight: manifest.cardHeightMeters, scale: Self.mirrorScale)
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
            selfAvatarPersonaID = nil
        }
    }

    private func billboard(from position: SIMD3<Float>) -> simd_quatf {
        let toViewer = viewerPosition - position
        let yaw = atan2(toViewer.x, toViewer.z)
        return simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
    }

    func removeAll() {
        for (_, a) in avatars { a.root.removeFromParent() }
        avatars.removeAll()
        avatarImageIDs.removeAll()
        selfAvatar?.root.removeFromParent()
        selfAvatar = nil
        selfAvatarPersonaID = nil
    }
}
#endif
