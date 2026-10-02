import Foundation
import CoreGraphics

/// 사진 없이도 체험할 수 있도록 앱이 직접 그리는 "종이 인형" 페르소나.
/// 시뮬레이터 데모 손님과 스튜디오의 "샘플로 체험" 버튼이 사용한다. 순수 CoreGraphics 라 모든 플랫폼에서 동작.
nonisolated enum PlaceholderPersona {

    nonisolated struct Style: Sendable {
        var skin: RGB
        var hair: RGB
        var cloth: RGB
        var lip: RGB = RGB(r: 0.68, g: 0.32, b: 0.34)
        var hairLong: Bool
        var glasses: Bool
    }

    static let palette: [Style] = [
        Style(skin: RGB(r: 0.95, g: 0.82, b: 0.72), hair: RGB(r: 0.16, g: 0.12, b: 0.11), cloth: RGB(r: 0.19, g: 0.33, b: 0.52), hairLong: false, glasses: false),
        Style(skin: RGB(r: 0.90, g: 0.74, b: 0.62), hair: RGB(r: 0.30, g: 0.18, b: 0.12), cloth: RGB(r: 0.72, g: 0.42, b: 0.26), hairLong: true, glasses: false),
        Style(skin: RGB(r: 0.97, g: 0.86, b: 0.78), hair: RGB(r: 0.12, g: 0.12, b: 0.14), cloth: RGB(r: 0.30, g: 0.52, b: 0.42), hairLong: true, glasses: true),
        Style(skin: RGB(r: 0.86, g: 0.66, b: 0.54), hair: RGB(r: 0.22, g: 0.16, b: 0.14), cloth: RGB(r: 0.55, g: 0.30, b: 0.50), hairLong: false, glasses: true),
        Style(skin: RGB(r: 0.93, g: 0.78, b: 0.70), hair: RGB(r: 0.42, g: 0.30, b: 0.20), cloth: RGB(r: 0.78, g: 0.62, b: 0.28), hairLong: false, glasses: false),
    ]

    static let guestNames = ["하늘", "바다", "들꽃", "별빛", "소나무"]

    /// 인덱스로 스타일/이름이 결정되는 데모 손님.
    static func guest(index: Int) -> PersonaPackage {
        let style = palette[index % palette.count]
        let name = guestNames[index % guestNames.count]
        return make(name: name, style: style)
    }

    /// 7차 "샘플로 체험": 블렌더 USDZ 데모 흉상 4종 중 하나. 카드 PNG 는 자리 카드·목록 썸네일용으로 비슷한 색의 만화 카드를 함께 그린다.
    /// 매니페스트 `demoAvatar` 가 저장되므로 창을 오가거나 재실행해도 같은 흉상이 유지된다.
    static func makeDemoBust(_ avatar: DemoAvatar, name: String? = nil) -> PersonaPackage {
        let style: Style
        switch avatar {
        case .ethan:  style = Style(skin: RGB(r: 0.95, g: 0.82, b: 0.72), hair: RGB(r: 0.36, g: 0.24, b: 0.16), cloth: avatar.accent, hairLong: false, glasses: false)
        case .olivia: style = Style(skin: RGB(r: 0.97, g: 0.86, b: 0.78), hair: RGB(r: 0.86, g: 0.72, b: 0.42), cloth: avatar.accent, hairLong: true, glasses: false)
        case .lucas:  style = Style(skin: RGB(r: 0.90, g: 0.74, b: 0.62), hair: RGB(r: 0.22, g: 0.14, b: 0.10), cloth: avatar.accent, hairLong: false, glasses: true)
        case .emma:   style = Style(skin: RGB(r: 0.96, g: 0.84, b: 0.76), hair: RGB(r: 0.52, g: 0.24, b: 0.16), cloth: avatar.accent, hairLong: false, glasses: false)
        }
        var package = make(name: name ?? avatar.displayName, style: style)
        package.manifest.demoAvatar = avatar.rawValue
        package.manifest.faceKit = avatar.sex.rawValue
        package.manifest.accent = avatar.accent
        return package
    }

    /// 4종 중 랜덤.
    static func randomDemoBust(name: String? = nil) -> PersonaPackage {
        makeDemoBust(DemoAvatar.allCases.randomElement() ?? .ethan, name: name)
    }

    static func make(name: String, style: Style) -> PersonaPackage {
        let size = CGSize(width: 640, height: 800)
        let w = Int(size.width), h = Int(size.height)

        // 얼굴 기하 (픽셀, 좌상단 원점)
        let headCenter = CGPoint(x: 320, y: 250)
        let headRadius: CGFloat = 150
        let eyeY = headCenter.y - 10
        let leftEyeRect = CGRect(x: headCenter.x - 78, y: eyeY - 18, width: 50, height: 36)
        let rightEyeRect = CGRect(x: headCenter.x + 28, y: eyeY - 18, width: 50, height: 36)
        let mouthRect = CGRect(x: headCenter.x - 42, y: headCenter.y + 62, width: 84, height: 34)

        guard let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Placeholder persona context failed")
        }
        // 좌상단 원점으로 뒤집기
        g.translateBy(x: 0, y: size.height)
        g.scaleBy(x: 1, y: -1)
        g.setAllowsAntialiasing(true)
        g.interpolationQuality = .high

        func color(_ c: RGB, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: a)
        }

        // 몸통 (어깨 둥근 사다리꼴)
        let torso = CGMutablePath()
        torso.move(to: CGPoint(x: 120, y: 800))
        torso.addLine(to: CGPoint(x: 120, y: 560))
        torso.addQuadCurve(to: CGPoint(x: 250, y: 440), control: CGPoint(x: 130, y: 460))
        torso.addLine(to: CGPoint(x: 390, y: 440))
        torso.addQuadCurve(to: CGPoint(x: 520, y: 560), control: CGPoint(x: 510, y: 460))
        torso.addLine(to: CGPoint(x: 520, y: 800))
        torso.closeSubpath()
        g.setFillColor(color(style.cloth))
        g.addPath(torso)
        g.fillPath()
        // 옷깃 음영
        g.setFillColor(color(style.cloth.darker(0.25)))
        let collar = CGMutablePath()
        collar.move(to: CGPoint(x: 250, y: 440))
        collar.addLine(to: CGPoint(x: 320, y: 530))
        collar.addLine(to: CGPoint(x: 390, y: 440))
        collar.closeSubpath()
        g.addPath(collar)
        g.fillPath()

        // 목
        g.setFillColor(color(style.skin.darker(0.08)))
        g.fill(CGRect(x: headCenter.x - 42, y: headCenter.y + headRadius - 40, width: 84, height: 90))

        // 긴 머리 뒷부분
        if style.hairLong {
            g.setFillColor(color(style.hair))
            g.fillEllipse(in: CGRect(x: headCenter.x - headRadius - 18, y: headCenter.y - headRadius - 10,
                                     width: (headRadius + 18) * 2, height: headRadius * 2 + 230))
        }

        // 얼굴
        g.setFillColor(color(style.skin))
        g.fillEllipse(in: CGRect(x: headCenter.x - headRadius, y: headCenter.y - headRadius,
                                 width: headRadius * 2, height: headRadius * 2 + 20))

        // 앞머리
        g.setFillColor(color(style.hair))
        let bang = CGMutablePath()
        bang.move(to: CGPoint(x: headCenter.x - headRadius, y: headCenter.y - 20))
        bang.addQuadCurve(to: CGPoint(x: headCenter.x + headRadius, y: headCenter.y - 20),
                          control: CGPoint(x: headCenter.x, y: headCenter.y - headRadius - 70))
        bang.addQuadCurve(to: CGPoint(x: headCenter.x + 40, y: headCenter.y - 70),
                          control: CGPoint(x: headCenter.x + 120, y: headCenter.y - 60))
        bang.addQuadCurve(to: CGPoint(x: headCenter.x - headRadius, y: headCenter.y - 20),
                          control: CGPoint(x: headCenter.x - 60, y: headCenter.y - 110))
        bang.closeSubpath()
        g.addPath(bang)
        g.fillPath()

        // 귀
        g.setFillColor(color(style.skin.darker(0.05)))
        g.fillEllipse(in: CGRect(x: headCenter.x - headRadius - 14, y: headCenter.y - 10, width: 30, height: 44))
        g.fillEllipse(in: CGRect(x: headCenter.x + headRadius - 16, y: headCenter.y - 10, width: 30, height: 44))

        // 눈
        for eye in [leftEyeRect, rightEyeRect] {
            g.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            g.fillEllipse(in: eye)
            g.setFillColor(CGColor(srgbRed: 0.12, green: 0.1, blue: 0.1, alpha: 1))
            g.fillEllipse(in: CGRect(x: eye.midX - 9, y: eye.midY - 9, width: 18, height: 18))
            g.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
            g.fillEllipse(in: CGRect(x: eye.midX - 1, y: eye.midY - 6, width: 5, height: 5))
        }
        // 눈썹
        g.setStrokeColor(color(style.hair))
        g.setLineWidth(6)
        g.setLineCap(.round)
        g.move(to: CGPoint(x: leftEyeRect.minX, y: leftEyeRect.minY - 18))
        g.addQuadCurve(to: CGPoint(x: leftEyeRect.maxX, y: leftEyeRect.minY - 20), control: CGPoint(x: leftEyeRect.midX, y: leftEyeRect.minY - 30))
        g.strokePath()
        g.move(to: CGPoint(x: rightEyeRect.minX, y: rightEyeRect.minY - 20))
        g.addQuadCurve(to: CGPoint(x: rightEyeRect.maxX, y: rightEyeRect.minY - 18), control: CGPoint(x: rightEyeRect.midX, y: rightEyeRect.minY - 30))
        g.strokePath()

        // 안경
        if style.glasses {
            g.setStrokeColor(CGColor(srgbRed: 0.15, green: 0.15, blue: 0.18, alpha: 0.9))
            g.setLineWidth(4)
            g.strokeEllipse(in: leftEyeRect.insetBy(dx: -10, dy: -14))
            g.strokeEllipse(in: rightEyeRect.insetBy(dx: -10, dy: -14))
            g.move(to: CGPoint(x: leftEyeRect.maxX + 10, y: eyeY))
            g.addLine(to: CGPoint(x: rightEyeRect.minX - 10, y: eyeY))
            g.strokePath()
        }

        // 코
        g.setStrokeColor(color(style.skin.darker(0.25)))
        g.setLineWidth(4)
        g.move(to: CGPoint(x: headCenter.x - 4, y: headCenter.y + 5))
        g.addQuadCurve(to: CGPoint(x: headCenter.x + 12, y: headCenter.y + 38), control: CGPoint(x: headCenter.x - 10, y: headCenter.y + 40))
        g.strokePath()

        // 입 (다문 미소)
        g.setStrokeColor(color(style.lip))
        g.setLineWidth(6)
        g.move(to: CGPoint(x: mouthRect.minX, y: mouthRect.midY - 4))
        g.addQuadCurve(to: CGPoint(x: mouthRect.maxX, y: mouthRect.midY - 4), control: CGPoint(x: mouthRect.midX, y: mouthRect.maxY + 6))
        g.strokePath()
        // 볼터치
        g.setFillColor(CGColor(srgbRed: 0.95, green: 0.45, blue: 0.45, alpha: 0.22))
        g.fillEllipse(in: CGRect(x: headCenter.x - 125, y: headCenter.y + 30, width: 56, height: 30))
        g.fillEllipse(in: CGRect(x: headCenter.x + 69, y: headCenter.y + 30, width: 56, height: 30))

        guard let cg = g.makeImage(), let png = try? PersonaBuilder.encodePNG(cg) else {
            fatalError("Placeholder persona rendering failed")
        }
        let rig = FaceRig(
            faceBox: NRect(pixelRect: CGRect(x: headCenter.x - headRadius, y: headCenter.y - headRadius,
                                             width: headRadius * 2, height: headRadius * 2 + 20), in: size),
            leftEye: NRect(pixelRect: leftEyeRect.insetBy(dx: -6, dy: -6), in: size),
            rightEye: NRect(pixelRect: rightEyeRect.insetBy(dx: -6, dy: -6), in: size),
            mouth: NRect(pixelRect: mouthRect, in: size),
            noseTip: NPoint(x: headCenter.x / size.width, y: (headCenter.y + 30) / size.height),
            skin: style.skin, lip: style.lip,
            leftBrow: NRect(pixelRect: CGRect(x: leftEyeRect.minX, y: leftEyeRect.minY - 34, width: leftEyeRect.width, height: 20), in: size),
            rightBrow: NRect(pixelRect: CGRect(x: rightEyeRect.minX, y: rightEyeRect.minY - 34, width: rightEyeRect.width, height: 20), in: size),
            contour: (0...12).map { i -> NPoint in
                // 턱 아래 → 관자놀이: 얼굴 타원의 아래 반원
                let t = Double(i) / 12 * Double.pi
                return NPoint(x: (headCenter.x - headRadius * cos(t)) / size.width,
                              y: (headCenter.y + 10 + (headRadius + 10) * sin(t)) / size.height)
            },
            hair: style.hair)
        let manifest = PersonaManifest(name: name, kind: .placeholder, imageWidth: cg.width, imageHeight: cg.height,
                                       face: rig, accent: style.cloth, captureSource: .generated)
        return PersonaPackage(manifest: manifest, bodyPNG: png)
    }
}
