import Foundation
import RealityKit
import SwiftUI
import CoreGraphics

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#endif

/// RealityKit 에서 페르소나 한 명을 그리는 아바타. 모든 플랫폼에서 컴파일된다(이름표/반응 Attachment 는 visionOS 전용).
///
/// 몸통은 두 가지 모드:
/// - **카드**: 투명 PNG 평면 (2.5D 종이 인형)
/// - **스플랫**: `SplatCloud` 가 있으면 가우시안 스플랫 쿼드 메시 — 고개를 돌릴 때 실제 시차가 생긴다
///
/// 레이어 (앞 → 뒤): 손 · 눈꺼풀 · 벌어진 입 · 몸통(카드 또는 스플랫) · 그림자 카드 · 바닥 글로우
final class PersonaAvatar {
    let manifest: PersonaManifest
    let root = Entity()
    let usesSplats: Bool

    /// 머리 중심을 피벗으로 회전하는 카드 묶음.
    private let card = Entity()
    private let body: Entity
    private let shadow: ModelEntity
    private let mouthOpen: ModelEntity
    private let eyelids: [ModelEntity]
    private let leftHand: ModelEntity
    private let rightHand: ModelEntity
    private let glow: ModelEntity
    private let labelEntity = Entity()
    private let reactionEntity = Entity()

    let label = AvatarLabelState()

    private var pose = PersonaPose.rest
    private var time: Double = 0
    private var nextBlink: Double = 2.5
    private var blinkValue: Float = 0
    private let breathPhase = Float.random(in: 0...(2 * .pi))
    /// 머리 피벗(카드 로컬 좌표).
    private let pivot: SIMD3<Float>
    private let cardSize: SIMD2<Float>

    init(manifest: PersonaManifest, image: CGImage, splats: SplatCloud? = nil) throws {
        self.manifest = manifest
        let h = manifest.cardHeightMeters
        let w = manifest.cardWidthMeters
        cardSize = SIMD2(w, h)
        usesSplats = (splats?.count ?? 0) > 0

        // 얼굴 중심을 피벗으로. 리그가 없으면 카드 위쪽 30% 지점.
        if let face = manifest.face {
            pivot = Self.local(u: face.faceBox.midX, v: face.faceBox.midY, size: cardSize)
        } else {
            pivot = SIMD3(0, h * 0.2, 0)
        }
        // 오버레이가 표면 위에 놓이도록 (스플랫이면 부조 z, 카드면 0)
        func surface(_ u: Double, _ v: Double) -> Float { splats?.surfaceZ(u: u, v: v) ?? 0 }

        let texture = try TextureResource(image: image, options: .init(semantic: .color))
        if let splats, splats.count > 0 {
            body = try SplatMesh.makeEntity(splats)
        } else {
            var bodyMaterial = UnlitMaterial()
            bodyMaterial.color = .init(tint: .white, texture: .init(texture))
            bodyMaterial.blending = .transparent(opacity: .init(floatLiteral: 1))
            body = ModelEntity(mesh: .generatePlane(width: w, height: h), materials: [bodyMaterial])
        }

        var shadowMaterial = UnlitMaterial()
        shadowMaterial.color = .init(tint: PlatformColor(white: 0, alpha: 0.35), texture: .init(texture))
        shadowMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.35))
        shadow = ModelEntity(mesh: .generatePlane(width: w, height: h), materials: [shadowMaterial])

        let face = manifest.face
        let lip = face?.lip ?? .lipDefault
        let skin = face?.skin ?? .skinDefault

        // 벌어진 입
        let mouthRect = face?.mouth.scaled(by: 1.15) ?? NRect(x: 0.42, y: 0.36, width: 0.16, height: 0.07)
        let mouthSize = Self.localSize(mouthRect, size: cardSize)
        mouthOpen = ModelEntity(mesh: .generatePlane(width: mouthSize.x, height: mouthSize.y),
                                materials: [try Self.spriteMaterial(TextureFactory.openMouth(lip: lip))])
        mouthOpen.position = Self.local(u: mouthRect.midX, v: mouthRect.midY, size: cardSize)
            + SIMD3(0, 0, surface(mouthRect.midX, mouthRect.midY) + 0.006)
        mouthOpen.scale = SIMD3(1, 0.01, 1)
        mouthOpen.isEnabled = false

        // 눈꺼풀
        var lids: [ModelEntity] = []
        if let face {
            let lidMaterial = try Self.spriteMaterial(TextureFactory.ellipse(color: skin.darker(0.04)))
            for eye in [face.leftEye, face.rightEye] {
                let r = eye.scaled(by: 1.25)
                let s = Self.localSize(r, size: cardSize)
                let lid = ModelEntity(mesh: .generatePlane(width: s.x, height: s.y), materials: [lidMaterial])
                lid.position = Self.local(u: r.midX, v: r.midY, size: cardSize) + SIMD3(0, 0, surface(r.midX, r.midY) + 0.007)
                lid.scale = SIMD3(1, 0.01, 1)
                lid.isEnabled = false
                lids.append(lid)
            }
        }
        eyelids = lids

        // 손
        let accentColor = PlatformColor(red: manifest.accent.r, green: manifest.accent.g, blue: manifest.accent.b, alpha: 0.55)
        var handMaterial = UnlitMaterial(color: accentColor)
        handMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.55))
        leftHand = ModelEntity(mesh: .generateSphere(radius: 0.045), materials: [handMaterial])
        rightHand = ModelEntity(mesh: .generateSphere(radius: 0.045), materials: [handMaterial])
        leftHand.isEnabled = false
        rightHand.isEnabled = false

        // 바닥 글로우
        glow = ModelEntity(mesh: .generatePlane(width: 0.6, depth: 0.6),
                           materials: [try Self.spriteMaterial(TextureFactory.softDisc(color: manifest.accent))])
        glow.position = SIMD3(0, -h / 2 - 0.08, 0)
        glow.components.set(OpacityComponent(opacity: 0.35))

        // 조립
        body.position = -pivot
        shadow.position = -pivot + SIMD3(0.012, -0.012, usesSplats ? -0.06 : -0.01)
        card.addChild(shadow)
        card.addChild(body)
        card.addChild(mouthOpen)
        for lid in eyelids { card.addChild(lid) }
        mouthOpen.position -= pivot
        for lid in eyelids { lid.position -= pivot }
        card.position = pivot
        root.addChild(card)
        root.addChild(leftHand)
        root.addChild(rightHand)
        root.addChild(glow)

        #if os(visionOS)
        // 이름표 / 반응
        labelEntity.position = SIMD3(0, h / 2 + 0.07, 0.01)
        labelEntity.components.set(ViewAttachmentComponent(rootView: AvatarNameplate(state: label)))
        root.addChild(labelEntity)
        reactionEntity.position = SIMD3(w / 2 + 0.05, h / 2 - 0.1, 0.02)
        reactionEntity.components.set(ViewAttachmentComponent(rootView: AvatarReactionBubble(state: label)))
        root.addChild(reactionEntity)
        #endif

        label.name = manifest.name
    }

    // MARK: - Update

    /// 매 프레임 호출. `target` 은 네트워크/트래커에서 온 최신 포즈, dt 는 초.
    func update(target: PersonaPose, dt: Double, level: Float) {
        time += dt
        pose = pose.blended(toward: target, Float(min(1, dt * 10)))

        // 호흡 + 아주 작은 흔들림
        let breath = 1 + 0.012 * sin(Float(time) * 1.6 + breathPhase)
        let sway = 0.01 * sin(Float(time) * 0.7 + breathPhase)

        let yawGain: Float = usesSplats ? 0.9 : 0.75
        let yaw = simd_quatf(angle: pose.yaw * yawGain, axis: SIMD3(0, 1, 0))
        let pitch = simd_quatf(angle: -pose.pitch * 0.6, axis: SIMD3(1, 0, 0))
        let roll = simd_quatf(angle: pose.roll * 0.5 + sway, axis: SIMD3(0, 0, 1))
        card.orientation = yaw * pitch * roll
        var offset = pose.offset
        offset = simd_clamp(offset, SIMD3(repeating: -0.25), SIMD3(repeating: 0.25))
        card.position = pivot + SIMD3(offset.x, offset.y + 0.006 * sin(Float(time) * 1.6 + breathPhase), offset.z * 0.5)
        card.scale = SIMD3(1, breath, 1)

        // 입
        let mouth = min(1, max(0, pose.mouth, level) * manifest.mouthStrength)
        if mouth > 0.06 {
            mouthOpen.isEnabled = true
            mouthOpen.scale = SIMD3(0.8 + 0.25 * mouth, max(0.05, mouth), 1)
        } else {
            mouthOpen.isEnabled = false
        }

        // 깜빡임
        if time >= nextBlink {
            blinkValue = 1
            nextBlink = time + Double.random(in: 2.2...5.5)
        }
        if blinkValue > 0 {
            blinkValue = max(0, blinkValue - Float(dt) * 7)
            let closed = blinkValue > 0.5 ? (1 - blinkValue) * 2 : blinkValue * 2 // 0→1→0
            for lid in eyelids {
                lid.isEnabled = closed > 0.08
                lid.scale = SIMD3(1, max(0.02, closed), 1)
            }
        } else {
            for lid in eyelids { lid.isEnabled = false }
        }

        // 손: 머리 기준 → 카드 공간 (카드는 +z 가 앞)
        placeHand(leftHand, pose.leftHand)
        placeHand(rightHand, pose.rightHand)

        // 글로우
        let glowOpacity: Float = 0.25 + 0.6 * max(level, pose.speaking ? 0.4 : 0)
        glow.components.set(OpacityComponent(opacity: glowOpacity))
        glow.scale = SIMD3(repeating: 1 + 0.25 * max(level, pose.mouth))

        label.isSpeaking = pose.speaking || level > 0.15
        label.handRaised = pose.handRaised
        if let (_, at) = label.reaction, Date().timeIntervalSince(at) > 2.4 { label.reaction = nil }
    }

    func show(reaction: Reaction) {
        label.reaction = (reaction, Date())
    }

    private func placeHand(_ hand: ModelEntity, _ rel: SIMD3<Float>?) {
        guard let rel else { hand.isEnabled = false; return }
        hand.isEnabled = true
        let clamped = simd_clamp(rel, SIMD3(repeating: -0.7), SIMD3(repeating: 0.7))
        // 머리 좌표계: x 오른쪽, y 위, z 뒤. 카드: +z 앞.
        hand.position = pivot + SIMD3(clamped.x, clamped.y, -clamped.z * 0.6 + 0.03)
    }

    // MARK: - Helpers

    private static func local(u: Double, v: Double, size: SIMD2<Float>) -> SIMD3<Float> {
        SIMD3(Float(u - 0.5) * size.x, Float(0.5 - v) * size.y, 0)
    }

    private static func localSize(_ r: NRect, size: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(max(0.01, Float(r.width) * size.x), max(0.01, Float(r.height) * size.y))
    }

    private static func spriteMaterial(_ image: CGImage) throws -> UnlitMaterial {
        let texture = try TextureResource(image: image, options: .init(semantic: .color))
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        return material
    }
}

// MARK: - Label state & SwiftUI attachments

@Observable
final class AvatarLabelState {
    var name: String = ""
    var isSpeaking = false
    var handRaised = false
    var isMirror = false
    var reaction: (Reaction, Date)?
}

#if os(visionOS)
struct AvatarNameplate: View {
    let state: AvatarLabelState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isSpeaking ? Color.green : Color.white.opacity(0.35))
                .frame(width: 10, height: 10)
            Text(state.isMirror ? "\(state.name) · 거울" : state.name)
                .font(.system(size: 20, weight: .semibold))
            if state.handRaised {
                Text("✋").font(.system(size: 20))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassBackgroundEffect()
    }
}

struct AvatarReactionBubble: View {
    let state: AvatarLabelState

    var body: some View {
        Group {
            if let (reaction, _) = state.reaction {
                Text(reaction.rawValue)
                    .font(.system(size: 56))
                    .padding(10)
                    .glassBackgroundEffect()
                    .transition(.scale.combined(with: .opacity))
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .animation(.spring(duration: 0.35), value: state.reaction?.1)
    }
}
#endif

// MARK: - Procedural sprite textures

nonisolated enum TextureFactory {
    static func ellipse(color: RGB, size: Int = 128) -> CGImage {
        draw(size: size) { g, rect in
            g.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1))
            g.fillEllipse(in: rect.insetBy(dx: 2, dy: 2))
        }
    }

    /// 벌어진 입: 어두운 안쪽 + 입술색 테두리 + 아래 혀 느낌의 붉은 기.
    static func openMouth(lip: RGB, size: Int = 160) -> CGImage {
        draw(size: size) { g, rect in
            let inner = rect.insetBy(dx: 4, dy: 4)
            g.setFillColor(CGColor(srgbRed: lip.r, green: lip.g, blue: lip.b, alpha: 1))
            g.fillEllipse(in: inner)
            g.setFillColor(CGColor(srgbRed: 0.16, green: 0.06, blue: 0.07, alpha: 1))
            g.fillEllipse(in: inner.insetBy(dx: inner.width * 0.12, dy: inner.height * 0.18))
            g.setFillColor(CGColor(srgbRed: 0.72, green: 0.30, blue: 0.33, alpha: 0.9))
            g.fillEllipse(in: CGRect(x: inner.midX - inner.width * 0.22, y: inner.maxY - inner.height * 0.42,
                                     width: inner.width * 0.44, height: inner.height * 0.3))
            // 윗니 살짝
            g.setFillColor(CGColor(srgbRed: 0.97, green: 0.95, blue: 0.92, alpha: 0.95))
            g.fill(CGRect(x: inner.midX - inner.width * 0.2, y: inner.minY + inner.height * 0.16,
                          width: inner.width * 0.4, height: inner.height * 0.12))
        }
    }

    /// 가장자리로 갈수록 투명해지는 디스크.
    static func softDisc(color: RGB, size: Int = 256) -> CGImage {
        draw(size: size) { g, rect in
            let colors = [CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 0.9),
                          CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 0.0)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                let c = CGPoint(x: rect.midX, y: rect.midY)
                g.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: rect.width / 2, options: [])
            }
        }
    }

    private static func draw(size: Int, _ body: (CGContext, CGRect) -> Void) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(rect)
        body(ctx, rect)
        return ctx.makeImage()!
    }
}
