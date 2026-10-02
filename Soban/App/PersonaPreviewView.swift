import SwiftUI
import RealityKit

/// 창 안에서 페르소나 한 명을 살아 움직이게 보여 주는 미리보기. 모든 플랫폼.
///
/// - `levelSource` 는 매 프레임 호출되는 클로저라 마이크/얼굴 추적 레벨이 실시간으로 반영된다.
/// - `splats` 가 있으면 가우시안 스플랫 입체로, 없으면 2.5D 카드로 그린다. `turntable` 이면 천천히 좌우로 돌려 입체감을 보여 준다.
/// - 3D 콘텐츠는 창 유리면보다 5cm 뒤에 두고, 시트/피커가 떠 있는 동안(`visible == false`)은 숨긴다.
struct PersonaPreviewView: View {
    let manifest: PersonaManifest
    let image: CGImage
    var splats: SplatCloud? = nil
    var name: String
    var levelSource: () -> Float
    var demoMotion = true
    var turntable = false
    var visible = true

    @State private var holder = PreviewHolder()

    var body: some View {
        RealityView { content in
            holder.rebuild(manifest: manifest, image: image, splats: splats)
            content.add(holder.root)
        } update: { _ in
            holder.rebuild(manifest: manifest, image: image, splats: splats)
            holder.setName(name)
            holder.root.isEnabled = visible
        }
        .task(id: "\(manifest.id)-\(splats?.count ?? 0)") {
            var last = CACurrentMediaTime()
            while !Task.isCancelled {
                let now = CACurrentMediaTime()
                holder.step(dt: now - last, level: levelSource(), demo: demoMotion, turntable: turntable, now: now)
                last = now
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
    }
}

@Observable
final class PreviewHolder {
    let root = Entity()
    private var avatar: PersonaAvatar?
    private var personaID: UUID?
    private var imageIdentity: ObjectIdentifier?
    private var splatCount = -1

    func rebuild(manifest: PersonaManifest, image: CGImage, splats: SplatCloud?) {
        let identity = ObjectIdentifier(image)
        let count = splats?.count ?? 0
        guard personaID != manifest.id || imageIdentity != identity || splatCount != count || avatar == nil else { return }
        avatar?.root.removeFromParent()
        guard let a = try? PersonaAvatar(manifest: manifest, image: image, splats: splats) else { return }
        // 창 크기에 맞게: 카드가 0.8m 라 그대로는 너무 크다 → 0.42 배. 유리면 뒤로 5cm.
        a.root.scale = SIMD3(repeating: 0.42)
        a.root.position = SIMD3(0, -0.02, -0.05)
        root.addChild(a.root)
        avatar = a
        personaID = manifest.id
        imageIdentity = identity
        splatCount = count
    }

    func setName(_ name: String) {
        guard let avatar, avatar.label.name != name else { return }
        avatar.label.name = name
    }

    func step(dt: Double, level: Float, demo: Bool, turntable: Bool, now: Double) {
        guard let avatar else { return }
        var pose = PersonaPose()
        let t = Float(now)
        if turntable {
            pose.yaw = 0.55 * sin(t * 0.5)
            pose.pitch = 0.05 * sin(t * 0.8)
        } else if demo {
            pose.yaw = 0.22 * sin(t * 0.6)
            pose.pitch = 0.06 * sin(t * 0.9 + 1)
            pose.roll = 0.04 * sin(t * 0.45)
        }
        pose.mouth = level
        pose.speaking = level > 0.12
        avatar.update(target: pose, dt: dt, level: level)
    }
}
