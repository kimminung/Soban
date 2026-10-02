import Foundation
import RealityKit
import CoreGraphics
import Metal
import simd
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 스플랫 클라우드를 RealityKit 엔티티로 만든다.
///
/// - **OS 27 (visionOS·iOS·macOS 27)**: RealityKit 기본 스플랫 렌더러 `GaussianSplatComponent`. 위치·스케일·회전·불투명도·SH0 를
///   인터리브한 `LowLevelBuffer` 하나에 담고(14 float/스플랫), 정렬·타원체 투영은 프레임워크가 맡는다. 프레임워크는 버퍼를
///   **복사하지 않고 참조**하므로 위치를 다시 쓰면 스플랫이 움직인다 → `SplatJawDeformer` 가 jawOpen 에 따라 턱 영역을 내린다.
/// - **그 이전 OS / `quadsplats` 플래그**: 각 스플랫을 작은 사각형(쿼드)으로 그리고 색 × 가우시안 알파를 구운 타일 아틀라스 텍스처를
///   UnlitMaterial 로 알파 블렌딩한다(6차까지의 방식). 클라우드는 뒤→앞 정렬되어 있다.
enum SplatMesh {
    static let tile = 8

    /// DEBUG 실행 인자 `quadsplats` 로 구형 경로를 강제 (비교 검증용).
    static var forceQuads: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("quadsplats")
        #else
        return false
        #endif
    }

    /// 몸통 엔티티 + (네이티브일 때) 턱 변형기.
    /// 시뮬레이터 SDK(xrsimulator/iphonesimulator 27.0)에는 `GaussianSplatResource` 가 없다 → 시뮬레이터는 항상 쿼드.
    static func makeBody(_ cloud: SplatCloud, rig: FaceRig?, cardSize: SIMD2<Float>) throws -> SplatBody {
        #if !targetEnvironment(simulator)
        if #available(visionOS 27, iOS 27, macOS 27, *), !forceQuads {
            do {
                return try makeNative(cloud, rig: rig, cardSize: cardSize)
            } catch {
                // 스플랫 상한 초과·GPU 미지원 등 → 쿼드 폴백
            }
        }
        #endif
        return SplatBody(entity: try makeEntity(cloud), deformerBox: nil, isNative: false)
    }

    /// 이 빌드/기기에서 네이티브 스플랫 렌더러를 쓰는지 (UI 표시용).
    static var nativeAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(visionOS 27, iOS 27, macOS 27, *) { return !forceQuads }
        return false
        #endif
    }

    // MARK: - Native (RealityKit 27)
    #if !targetEnvironment(simulator)

    /// 스플랫당 float 14개: pos3 · scale3 · rot4(w,x,y,z) · opacity1 · sh0 3
    static let nativeStride = 14 * MemoryLayout<Float>.size
    static let sh0: Float = 0.28209479177387814

    @available(visionOS 27, iOS 27, macOS 27, *)
    static func makeNative(_ cloud: SplatCloud, rig: FaceRig?, cardSize: SIMD2<Float>) throws -> SplatBody {
        let count = min(cloud.splats.count, SplatBuilder.maxCount)
        guard count > 0 else { return SplatBody(entity: Entity(), deformerBox: nil, isNative: true) }
        let byteCount = count * nativeStride
        let buffer = try LowLevelBuffer(descriptor: .init(capacity: (byteCount + 15) & ~0xF, sizeMultiple: 16))
        buffer.withUnsafeMutableBytes { raw in
            let f = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            for i in 0..<count {
                let s = cloud.splats[i]
                let o = i * 14
                f[o] = s.position.x; f[o + 1] = s.position.y; f[o + 2] = s.position.z
                // 납작한 원반(얼굴 +Z 를 보는 가우시안). 쿼드 반지름 1.4·scale 와 비슷한 커버리지가 되도록 σ = 0.7·scale
                let sc = s.scale * 0.7
                f[o + 3] = sc; f[o + 4] = sc; f[o + 5] = sc * 0.3
                f[o + 6] = 1; f[o + 7] = 0; f[o + 8] = 0; f[o + 9] = 0
                f[o + 10] = Float(s.a) / 255
                // 3DGS 관례: color = 0.5 + C0 · f_dc
                f[o + 11] = (Float(s.r) / 255 - 0.5) / sh0
                f[o + 12] = (Float(s.g) / 255 - 0.5) / sh0
                f[o + 13] = (Float(s.b) / 255 - 0.5) / sh0
            }
        }
        let fs = MemoryLayout<Float>.size
        let position = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float3, stride: nativeStride, offset: 0)
        let scale = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float3, stride: nativeStride, offset: fs * 3)
        let rotation = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float4, stride: nativeStride, offset: fs * 6)
        let opacity = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float, stride: nativeStride, offset: fs * 10)
        let sh = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float3, stride: nativeStride, offset: fs * 11)
        let bufferResource = try GaussianSplatResource.BufferResource(count: count, position: position, scale: scale,
                                                                       rotation: rotation, opacity: opacity, sphericalHarmonics: (sh, .zero))
        let resource = GaussianSplatResource(bufferResource)
        resource.opacityActivation = .identity
        resource.scaleActivation = .identity
        let entity = Entity()
        entity.name = "SplatCloud"
        entity.components.set(GaussianSplatComponent(resource))

        let deformer = rig.map { SplatJawDeformer(buffer: buffer, cloud: cloud, count: count, rig: $0, cardSize: cardSize) }
        return SplatBody(entity: entity, deformerBox: deformer, isNative: true)
    }
    #endif

    // MARK: - Quad atlas (fallback)

    static func makeEntity(_ cloud: SplatCloud) throws -> ModelEntity {
        let count = min(cloud.splats.count, SplatBuilder.maxCount)
        guard count > 0 else { return ModelEntity() }
        let grid = Int(Double(count).squareRoot().rounded(.up))
        let texSize = grid * tile

        // 아틀라스: premultiplied RGBA, 타일마다 색 × 가우시안
        var pixels = [UInt8](repeating: 0, count: texSize * texSize * 4)
        var gauss = [Float](repeating: 0, count: tile * tile)
        for ty in 0..<tile {
            for tx in 0..<tile {
                let dx = (Float(tx) + 0.5) / Float(tile) * 2 - 1
                let dy = (Float(ty) + 0.5) / Float(tile) * 2 - 1
                let r2 = dx * dx + dy * dy
                gauss[ty * tile + tx] = exp(-r2 * 2.6) * (r2 < 1 ? 1 : max(0, 1 - (r2 - 1) * 4))
            }
        }
        for i in 0..<count {
            let s = cloud.splats[i]
            let gx = (i % grid) * tile, gy = (i / grid) * tile
            let a = Float(s.a) / 255
            for ty in 0..<tile {
                for tx in 0..<tile {
                    let w = gauss[ty * tile + tx] * a
                    let o = ((gy + ty) * texSize + gx + tx) * 4
                    pixels[o] = UInt8(Float(s.r) * w)
                    pixels[o + 1] = UInt8(Float(s.g) * w)
                    pixels[o + 2] = UInt8(Float(s.b) * w)
                    pixels[o + 3] = UInt8(255 * w)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let atlas = CGImage(width: texSize, height: texSize, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: texSize * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return ModelEntity()
        }
        let texture = try TextureResource(image: atlas, options: .init(semantic: .color))

        // 쿼드 메시
        var positions = [SIMD3<Float>](); positions.reserveCapacity(count * 4)
        var uvs = [SIMD2<Float>](); uvs.reserveCapacity(count * 4)
        var indices = [UInt32](); indices.reserveCapacity(count * 6)
        let inset = 0.5 / Float(texSize)
        for i in 0..<count {
            let s = cloud.splats[i]
            let r = s.scale * 1.4
            let p = s.position
            let base = UInt32(positions.count)
            positions.append(p + SIMD3(-r, -r, 0))
            positions.append(p + SIMD3( r, -r, 0))
            positions.append(p + SIMD3( r,  r, 0))
            positions.append(p + SIMD3(-r,  r, 0))
            let gx = Float((i % grid) * tile) / Float(texSize), gy = Float((i / grid) * tile) / Float(texSize)
            let tw = Float(tile) / Float(texSize)
            // RealityKit UV 원점은 좌하단 → v 뒤집기
            let u0 = gx + inset, u1 = gx + tw - inset
            let v0 = 1 - (gy + tw - inset), v1 = 1 - (gy + inset)
            uvs.append(SIMD2(u0, v0)); uvs.append(SIMD2(u1, v0)); uvs.append(SIMD2(u1, v1)); uvs.append(SIMD2(u0, v1))
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        var descriptor = MeshDescriptor(name: "splats")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        let mesh = try MeshResource.generate(from: [descriptor])

        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        material.faceCulling = .none
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "SplatCloud"
        return entity
    }
}

/// 스플랫 몸통 엔티티 + 턱 변형기(네이티브 경로에서만).
@MainActor
final class SplatBody {
    let entity: Entity
    private let deformerBox: Any?
    let isNative: Bool

    init(entity: Entity, deformerBox: Any?, isNative: Bool) {
        self.entity = entity
        self.deformerBox = deformerBox
        self.isNative = isNative
    }

    var hasDeformer: Bool { deformerBox != nil }

    /// 0…1 턱 벌림 → 턱 영역 스플랫 위치 재기록.
    func setJawOpen(_ value: Float) {
        #if !targetEnvironment(simulator)
        if #available(visionOS 27, iOS 27, macOS 27, *) {
            (deformerBox as? SplatJawDeformer)?.setJawOpen(value)
        }
        #endif
    }
}

#if !targetEnvironment(simulator)
/// jawOpen 에 연동한 간단한 턱 LBS: 윗입술 아래 ~ 턱 끝 스플랫을 귀 높이의 턱관절 축으로 회전(아래·뒤로).
/// 눈꺼풀·입술 키트와 같은 ARKit `jawOpen` 값을 받으므로 메시와 스플랫이 어긋나지 않는다.
@available(visionOS 27, iOS 27, macOS 27, *)
@MainActor
final class SplatJawDeformer {
    private let buffer: LowLevelBuffer
    private let indices: [Int32]
    private let weights: [Float]
    private let base: [SIMD3<Float>]
    private let pivot: SIMD3<Float>
    private var lastValue: Float = -1
    static let maxAngle: Float = 0.22   // rad ≈ 12.6°

    init(buffer: LowLevelBuffer, cloud: SplatCloud, count: Int, rig: FaceRig, cardSize: SIMD2<Float>) {
        self.buffer = buffer
        let cardW = cardSize.x, cardH = cardSize.y
        func local(_ u: Double, _ v: Double) -> SIMD2<Float> { SIMD2(Float(u - 0.5) * cardW, Float(0.5 - v) * cardH) }
        let mouth = local(rig.mouth.midX, rig.mouth.midY)
        let eyeY = (local(rig.leftEye.midX, rig.leftEye.midY).y + local(rig.rightEye.midX, rig.rightEye.midY).y) / 2
        let faceHalfW = Float(rig.faceBox.width) * cardW * 0.5
        let chinY = Float(0.5 - (rig.faceBox.y + rig.faceBox.height)) * cardH
        let upperLipY = mouth.y + Float(rig.mouth.height) * cardH * 0.2
        let span = max(0.02, upperLipY - chinY)
        // 턱관절: 눈 높이보다 조금 아래, 얼굴 뒤 6 cm
        pivot = SIMD3(mouth.x, eyeY - (eyeY - mouth.y) * 0.25, -0.06)
        var idx: [Int32] = [], w: [Float] = [], b: [SIMD3<Float>] = []
        for i in 0..<count {
            let p = cloud.splats[i].position
            guard p.y < upperLipY, p.y > chinY - span * 0.6, abs(p.x - mouth.x) < faceHalfW * 0.95, p.z > -0.08 else { continue }
            // 윗입술(0) → 턱 끝(1), 턱 아래로는 1 유지. 옆으로 갈수록 약하게
            let t = min(1, (upperLipY - p.y) / span)
            let lateral = 1 - pow(abs(p.x - mouth.x) / (faceHalfW * 0.95), 2)
            let weight = t * t * (3 - 2 * t) * max(0, lateral)
            guard weight > 0.02 else { continue }
            idx.append(Int32(i)); w.append(weight); b.append(p)
        }
        indices = idx; weights = w; base = b
    }

    func setJawOpen(_ value: Float) {
        let v = max(0, min(1, value))
        guard abs(v - lastValue) > 0.008, !indices.isEmpty else { return }
        lastValue = v
        let angle = -v * Self.maxAngle
        let rot = simd_quatf(angle: angle, axis: SIMD3(1, 0, 0))
        buffer.withUnsafeMutableBytes { raw in
            let f = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            for k in indices.indices {
                let i = Int(indices[k])
                let rel = base[k] - pivot
                let rotated = rot.act(rel)
                let p = pivot + rel + (rotated - rel) * weights[k]
                let o = i * 14
                f[o] = p.x; f[o + 1] = p.y; f[o + 2] = p.z
            }
        }
    }
}
#endif
