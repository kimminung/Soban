import Foundation
import RealityKit
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 스플랫 클라우드를 RealityKit 엔티티로 만든다.
///
/// RealityKit(visionOS)에는 커스텀 셰이더가 없으므로 각 스플랫을 **작은 사각형(쿼드)** 으로 그리고,
/// 색 × 가우시안 알파를 구운 **타일 아틀라스 텍스처**(스플랫당 8×8 px)를 UnlitMaterial 로 알파 블렌딩한다.
/// 클라우드는 이미 뒤→앞으로 정렬되어 있어 한 메시 안에서도 블렌딩 순서가 대체로 맞는다(루트는 뷰어 방향 빌보딩).
enum SplatMesh {
    static let tile = 8

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
