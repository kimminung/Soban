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
    /// 8차: 외부 ARKit 52 표정(iPhone TrueDepth 전체 / 카메라 랜드마크 미니 세트)과 깜빡임 포함 여부. nil 이면 합성.
    var expressionSource: () -> (ArkitWeights, Bool)? = { nil }
    /// 9차: 말할 문장(비셈 큐). id 가 바뀔 때마다 한 번 아바타에 전달된다.
    var speech: (id: UUID, text: String, duration: Double)? = nil
    /// visionOS 창 안 배율 (스튜디오 0.42, 홈 카드 0.19). iOS/macOS 는 전용 카메라라 무시.
    var previewScale: Float = 0.42
    /// visionOS 창 유리면 기준 깊이(m). 스튜디오는 시트가 가려지지 않게 −5cm, 홈 카드는 0 (뒤로 두면 창 중심에서 먼 뷰일수록 옆으로 밀려 보인다).
    var previewDepth: Float = -0.05
    var demoMotion = true
    var turntable = false
    var visible = true

    @State private var holder = PreviewHolder()

    var body: some View {
        RealityView { content in
            holder.scale = previewScale
            holder.depth = previewDepth
            holder.rebuild(manifest: manifest, image: image, splats: splats)
            content.add(holder.root)
            #if !os(visionOS)
            // iPhone/iPad/Mac: 가상 카메라를 직접 두어 페르소나가 프레임을 꽉 채우게 한다
            // (기본 카메라는 멀리 있어 엔티티가 작고 여백이 컸다). 카드 0.8m 가 세로의 ~90% 가 되는 거리.
            let cam = PerspectiveCamera()
            cam.camera.fieldOfViewInDegrees = 36
            let visibleH = manifest.cardHeightMeters * 1.12
            let d = visibleH / (2 * tan(36 * Float.pi / 360))
            cam.position = SIMD3(0, 0.0, d)
            cam.look(at: SIMD3(0, 0.0, 0), from: cam.position, relativeTo: nil)
            content.add(cam)
            #endif
        } update: { _ in
            holder.rebuild(manifest: manifest, image: image, splats: splats)
            holder.setName(name)
            holder.root.isEnabled = visible
            holder.deliver(speech)
        }
        .task(id: "\(manifest.id)-\(splats?.count ?? 0)") {
            var last = CACurrentMediaTime()
            while !Task.isCancelled {
                let now = CACurrentMediaTime()
                holder.step(dt: now - last, level: levelSource(), expression: expressionSource(), demo: demoMotion, turntable: turntable, now: now)
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
    private var avatar: (any TableAvatar)?
    private var personaID: UUID?
    private var imageIdentity: ObjectIdentifier?
    private var splatCount = -1
    private var demo: DemoAvatar?
    private var lastSpeechID: UUID?
    var scale: Float = 0.42
    var depth: Float = -0.05

    /// 새 문장이면 아바타의 비셈 큐로.
    func deliver(_ speech: (id: UUID, text: String, duration: Double)?) {
        guard let speech, speech.id != lastSpeechID else { return }
        lastSpeechID = speech.id
        avatar?.speak(text: speech.text, duration: speech.duration)
    }

    func rebuild(manifest: PersonaManifest, image: CGImage, splats: SplatCloud?) {
        let identity = ObjectIdentifier(image)
        let count = splats?.count ?? 0
        let demoCase = manifest.demoAvatarCase
        guard personaID != manifest.id || imageIdentity != identity || splatCount != count || demo != demoCase || avatar == nil else { return }
        avatar?.root.removeFromParent()
        demo = demoCase
        // 7차: 블렌더 흉상 샘플이면 USDZ 흉상(이미 입체, 블렌드셰이프)으로
        let a: any TableAvatar
        if let demoCase {
            guard let bust = try? DemoBustAvatar(avatar: demoCase, name: manifest.name) else { return }
            a = bust
        } else {
            guard let persona = try? PersonaAvatar(manifest: manifest, image: image, splats: splats) else { return }
            a = persona
        }
        #if os(visionOS)
        // 창 크기에 맞게: 카드가 0.8m 라 그대로는 너무 크다 → 0.42 배(스튜디오). 유리면 뒤로 5cm.
        a.root.scale = SIMD3(repeating: scale)
        a.root.position = SIMD3(0, -0.02 * scale / 0.42, depth)
        #else
        // 전용 가상 카메라가 거리를 맞추므로 실제 크기 그대로. 글로우 디스크가 아래로 잘리지 않게 살짝 위로.
        a.root.scale = SIMD3(repeating: 1)
        a.root.position = SIMD3(0, 0.03, 0)
        #endif
        root.addChild(a.root)
        avatar = a
        personaID = manifest.id
        imageIdentity = identity
        splatCount = count
        // 얼굴 리그가 있으면 블렌더 USDZ 눈꺼풀/입술 키트를 비동기로 부착 (카드·스플랫 모두)
        if let persona = a as? PersonaAvatar { Task { await persona.attachFaceKitIfNeeded() } }
    }

    func setName(_ name: String) {
        guard let avatar, avatar.label.name != name else { return }
        avatar.label.name = name
    }

    func step(dt: Double, level: Float, expression: (ArkitWeights, Bool)?, demo: Bool, turntable: Bool, now: Double) {
        guard let avatar else { return }
        avatar.setExpression(expression?.0, includesBlink: expression?.1 ?? false)
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
