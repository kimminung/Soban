#if os(iOS)
import Foundation
import ARKit
import Observation

/// iPhone/iPad TrueDepth: ARKit 얼굴 추적의 `jawOpen` 블렌드셰이프로 입 벌림을 읽는다.
/// 전면 카메라를 독점하므로 캡처 세션(`CameraCaptureController`)이 멈춘 뒤에만 켠다.
@Observable
final class FaceMouthTracker: NSObject, ARSessionDelegate {
    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    private let session = ARSession()
    private(set) var isRunning = false
    private(set) var level: Float = 0
    /// 8차: ARKit 52 블렌드셰이프 전체 (눈 깜빡임 포함) — 미리보기 키트/흉상을 직접 구동한다.
    private(set) var weights = ArkitWeights()
    private(set) var faceVisible = false
    private(set) var errorText: String?

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard Self.isSupported, !isRunning else { return }
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = false
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        errorText = nil
    }

    func stop() {
        guard isRunning else { return }
        session.pause()
        isRunning = false
        level = 0
        weights = ArkitWeights()
        faceVisible = false
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }
        let jaw = face.blendShapes[.jawOpen]?.floatValue ?? 0
        let funnel = face.blendShapes[.mouthFunnel]?.floatValue ?? 0
        let open = min(1, max(0, jaw * 1.6 + funnel * 0.4))
        let tracked = face.isTracked
        var w = ArkitWeights()
        for (loc, num) in face.blendShapes {
            if let shape = ArkitShape(rawValue: loc.rawValue) { w[shape] = num.floatValue }
        }
        Task { @MainActor in
            self.level = open
            self.weights = w
            self.faceVisible = tracked
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: any Error) {
        Task { @MainActor in
            self.errorText = "얼굴 추적 실패: \(error.localizedDescription)"
            self.isRunning = false
        }
    }
}
#endif
