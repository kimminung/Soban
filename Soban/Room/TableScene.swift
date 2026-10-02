#if os(visionOS)
import Foundation
import RealityKit
import UIKit

/// 한국식 좌식 두레반 세트를 프로시저럴 메시로 만든다: 돗자리, 옻칠 상판, 다리, 방석 6개, 찻잔, 다관.
enum TableScene {
    static let cushionColors: [UIColor] = [
        UIColor(red: 0.20, green: 0.30, blue: 0.52, alpha: 1), // 쪽빛
        UIColor(red: 0.74, green: 0.46, blue: 0.22, alpha: 1), // 황토
        UIColor(red: 0.32, green: 0.52, blue: 0.42, alpha: 1), // 옥색
        UIColor(red: 0.56, green: 0.30, blue: 0.42, alpha: 1), // 자주
        UIColor(red: 0.78, green: 0.66, blue: 0.36, alpha: 1), // 치자
        UIColor(red: 0.40, green: 0.38, blue: 0.52, alpha: 1), // 보랏빛 회색
    ]

    static func build(layout: TableLayout) -> Entity {
        let root = Entity()
        root.name = "TableScene"

        // 돗자리 느낌의 바닥 빛 웅덩이
        if let discImage = Optional(TextureFactory.softDisc(color: RGB(r: 0.86, g: 0.76, b: 0.58), size: 256)),
           let tex = try? TextureResource(image: discImage, options: .init(semantic: .color)) {
            var mat = UnlitMaterial()
            mat.color = .init(tint: .white, texture: .init(tex))
            mat.blending = .transparent(opacity: .init(floatLiteral: 0.5))
            let mat2 = ModelEntity(mesh: .generatePlane(width: layout.seatRadius * 2 + 1.2, depth: layout.seatRadius * 2 + 1.2),
                                   materials: [mat])
            mat2.position = layout.center + SIMD3(0, 0.003, 0)
            root.addChild(mat2)
        }

        // 상판 (옻칠)
        let lacquer = SimpleMaterial(color: UIColor(red: 0.30, green: 0.17, blue: 0.10, alpha: 1), roughness: 0.22, isMetallic: false)
        let rimColor = SimpleMaterial(color: UIColor(red: 0.20, green: 0.11, blue: 0.07, alpha: 1), roughness: 0.3, isMetallic: false)
        let top = ModelEntity(mesh: .generateCylinder(height: 0.035, radius: layout.tableRadius), materials: [lacquer])
        top.position = layout.center + SIMD3(0, layout.tableHeight, 0)
        root.addChild(top)
        let rim = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: layout.tableRadius + 0.02), materials: [rimColor])
        rim.position = layout.center + SIMD3(0, layout.tableHeight + 0.01, 0)
        root.addChild(rim)
        // 상판 가운데 자개 느낌 원
        let inlay = ModelEntity(mesh: .generateCylinder(height: 0.004, radius: 0.16),
                                materials: [SimpleMaterial(color: UIColor(red: 0.55, green: 0.62, blue: 0.66, alpha: 1), roughness: 0.15, isMetallic: true)])
        inlay.position = layout.center + SIMD3(0, layout.tableHeight + 0.02, 0)
        root.addChild(inlay)

        // 다리 4개 + 가로대
        let legMaterial = SimpleMaterial(color: UIColor(red: 0.24, green: 0.14, blue: 0.09, alpha: 1), roughness: 0.4, isMetallic: false)
        for i in 0..<4 {
            let a = Float(i) * .pi / 2 + .pi / 4
            let leg = ModelEntity(mesh: .generateBox(width: 0.05, height: layout.tableHeight - 0.02, depth: 0.05, cornerRadius: 0.01),
                                  materials: [legMaterial])
            leg.position = layout.center + SIMD3(cos(a) * (layout.tableRadius - 0.14), (layout.tableHeight - 0.02) / 2, sin(a) * (layout.tableRadius - 0.14))
            root.addChild(leg)
        }
        let brace = ModelEntity(mesh: .generateBox(width: layout.tableRadius * 1.3, height: 0.03, depth: 0.03), materials: [legMaterial])
        brace.position = layout.center + SIMD3(0, 0.08, 0)
        root.addChild(brace)
        let brace2 = brace.clone(recursive: false)
        brace2.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        root.addChild(brace2)

        // 방석 6개
        for slot in 0..<TableLayout.seatCount {
            let color = cushionColors[slot % cushionColors.count]
            let cushion = ModelEntity(mesh: .generateCylinder(height: 0.05, radius: layout.cushionRadius),
                                      materials: [SimpleMaterial(color: color, roughness: 0.95, isMetallic: false)])
            cushion.position = layout.seatPosition(slot: slot) + SIMD3(0, 0.025, 0)
            root.addChild(cushion)
            let tuft = ModelEntity(mesh: .generateCylinder(height: 0.006, radius: layout.cushionRadius * 0.55),
                                   materials: [SimpleMaterial(color: color.withAlphaComponent(1).darker(0.18), roughness: 1, isMetallic: false)])
            tuft.position = cushion.position + SIMD3(0, 0.026, 0)
            root.addChild(tuft)

            // 찻잔
            let cupMaterial = SimpleMaterial(color: UIColor(red: 0.92, green: 0.90, blue: 0.84, alpha: 1), roughness: 0.35, isMetallic: false)
            let cup = ModelEntity(mesh: .generateCylinder(height: 0.045, radius: 0.034), materials: [cupMaterial])
            cup.position = layout.cupPosition(slot: slot)
            root.addChild(cup)
            let tea = ModelEntity(mesh: .generateCylinder(height: 0.004, radius: 0.028),
                                  materials: [SimpleMaterial(color: UIColor(red: 0.62, green: 0.68, blue: 0.36, alpha: 1), roughness: 0.1, isMetallic: false)])
            tea.position = cup.position + SIMD3(0, 0.022, 0)
            root.addChild(tea)
        }

        // 다관 (주전자)
        let potMaterial = SimpleMaterial(color: UIColor(red: 0.35, green: 0.33, blue: 0.30, alpha: 1), roughness: 0.5, isMetallic: false)
        let pot = ModelEntity(mesh: .generateSphere(radius: 0.075), materials: [potMaterial])
        pot.position = layout.center + SIMD3(0.18, layout.tableHeight + 0.0175 + 0.07, -0.05)
        pot.scale = SIMD3(1, 0.85, 1)
        root.addChild(pot)
        let lid = ModelEntity(mesh: .generateSphere(radius: 0.016), materials: [potMaterial])
        lid.position = pot.position + SIMD3(0, 0.07, 0)
        root.addChild(lid)
        let spout = ModelEntity(mesh: .generateCylinder(height: 0.09, radius: 0.012), materials: [potMaterial])
        spout.position = pot.position + SIMD3(0.075, 0.02, 0)
        spout.orientation = simd_quatf(angle: -.pi / 3, axis: SIMD3(0, 0, 1))
        root.addChild(spout)
        let handle = ModelEntity(mesh: .generateBox(width: 0.012, height: 0.11, depth: 0.012, cornerRadius: 0.006), materials: [potMaterial])
        handle.position = pot.position + SIMD3(-0.085, 0.01, 0)
        root.addChild(handle)

        // 다과 접시
        let plate = ModelEntity(mesh: .generateCylinder(height: 0.01, radius: 0.11),
                                materials: [SimpleMaterial(color: UIColor(red: 0.88, green: 0.86, blue: 0.80, alpha: 1), roughness: 0.4, isMetallic: false)])
        plate.position = layout.center + SIMD3(-0.2, layout.tableHeight + 0.0175 + 0.005, 0.08)
        root.addChild(plate)
        let sweetColors = [UIColor(red: 0.86, green: 0.45, blue: 0.40, alpha: 1), UIColor(red: 0.95, green: 0.82, blue: 0.50, alpha: 1), UIColor(red: 0.55, green: 0.70, blue: 0.48, alpha: 1)]
        for (i, c) in sweetColors.enumerated() {
            let sweet = ModelEntity(mesh: .generateBox(width: 0.035, height: 0.02, depth: 0.035, cornerRadius: 0.006),
                                    materials: [SimpleMaterial(color: c, roughness: 0.6, isMetallic: false)])
            let a = Float(i) * 2 * .pi / 3
            sweet.position = plate.position + SIMD3(cos(a) * 0.05, 0.015, sin(a) * 0.05)
            root.addChild(sweet)
        }

        return root
    }
}

extension UIColor {
    func darker(_ amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * (1 - amount), green: g * (1 - amount), blue: b * (1 - amount), alpha: a)
    }
}
#endif
