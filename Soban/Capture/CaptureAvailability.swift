import Foundation
#if os(iOS) || os(macOS)
import AVFoundation
#endif

/// 이 기기에서 얼굴 촬영이 어떤 방식으로 가능한지.
///
/// - Vision Pro: 서드파티 앱은 어떤 카메라에도 접근할 수 없다(Enterprise 라이선스 + 전용 엔타이틀먼트가 있어야 메인 카메라만).
///   시스템 Persona 등록처럼 "기기를 벗고 EyeSight 안내에 따라 촬영"하는 기능은 Apple 전용이므로 **항상 `.unavailable`**.
/// - iPhone/iPad: 전면 TrueDepth → `.depthFront`, 후면 LiDAR → `.depthRear`, 그 외 카메라 → `.cameraOnly`.
/// - Mac: FaceTime 카메라 → `.cameraOnly`.
nonisolated enum CaptureCapability: Sendable, Equatable {
    case depthFront
    case depthRear
    case cameraOnly
    case unavailable(String)

    var usesDepth: Bool {
        switch self {
        case .depthFront, .depthRear: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .depthFront: "TrueDepth 깊이 카메라"
        case .depthRear: "LiDAR 깊이 카메라"
        case .cameraOnly: "일반 카메라"
        case .unavailable: "카메라 사용 불가"
        }
    }

    var detail: String {
        switch self {
        case .depthFront: "전면 깊이 센서로 얼굴 윤곽을 함께 기록합니다. 가장자리가 더 깔끔하게 잘립니다."
        case .depthRear: "후면 LiDAR 로 깊이를 기록합니다. 거울을 보거나 다른 사람이 찍어 주세요."
        case .cameraOnly: "깊이 없이 사진만 찍습니다. Vision 인물 분리만으로 카드를 만듭니다."
        case .unavailable(let reason): reason
        }
    }

    var systemImage: String {
        switch self {
        case .depthFront: "faceid"
        case .depthRear: "camera.metering.matrix"
        case .cameraOnly: "camera"
        case .unavailable: "camera.badge.ellipsis"
        }
    }

    var captureSource: PersonaManifest.CaptureSource {
        usesDepth ? .depthCamera : .camera
    }
}

enum CaptureAvailability {
    nonisolated static let visionOSReason =
        "visionOS 는 서드파티 앱에 카메라를 열어 주지 않습니다. Apple Persona 등록처럼 Vision Pro 를 벗고 촬영하는 기능은 시스템 전용이라 소반에서는 쓸 수 없습니다. 대신 iPhone·iPad(깊이 카메라) 또는 Mac 에서 '소반' 앱으로 촬영한 뒤 이 기기로 보내 주세요."

    static func detect() -> CaptureCapability {
        #if os(visionOS)
        return .unavailable(visionOSReason)
        #elseif os(iOS)
        if AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) != nil { return .depthFront }
        if AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil { return .depthRear }
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
            || AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil { return .cameraOnly }
        return .unavailable("이 기기에서 사용할 수 있는 카메라를 찾지 못했습니다.")
        #elseif os(macOS)
        if AVCaptureDevice.default(for: .video) != nil { return .cameraOnly }
        return .unavailable("연결된 카메라가 없습니다. FaceTime 카메라 또는 iPhone 연속성 카메라를 사용해 주세요.")
        #else
        return .unavailable("지원하지 않는 플랫폼입니다.")
        #endif
    }

    /// 사용자에게 보여 줄 기기 이름.
    static var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #else
        return "기기"
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif
