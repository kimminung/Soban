#if os(visionOS)
import Foundation
import ARKit
import QuartzCore
import simd
import Observation

/// Vision Pro 의 머리 자세(WorldTrackingProvider)와 손목 위치(HandTrackingProvider)를 읽어
/// 내 페르소나의 `PersonaPose` 로 바꾼다. 이머시브 공간이 열려 있을 때만 데이터가 들어온다.
///
/// ARKit 세션과 데이터 프로바이더는 `stop()` 이후 재사용할 수 없으므로(상태가 `.stopped` 로 고정)
/// `start()` 마다 새로 만든다. 상을 접었다 다시 펼칠 때 추적이 죽어 있던 원인.
@Observable
final class HeadHandTracker {
    private var session = ARKitSession()
    private var world = WorldTrackingProvider()
    private var hands = HandTrackingProvider()

    private(set) var isRunning = false
    private(set) var statusText = "대기"
    private(set) var headTransform: simd_float4x4?
    private(set) var leftWrist: SIMD3<Float>?
    private(set) var rightWrist: SIMD3<Float>?

    private var referenceYaw: Float?
    private var referencePosition: SIMD3<Float>?
    private var handTask: Task<Void, Never>?
    private var generation = 0

    var headPosition: SIMD3<Float>? { headTransform.map { SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) } }

    func start() async {
        guard !isRunning else { return }
        generation += 1
        let myGeneration = generation
        session = ARKitSession()
        world = WorldTrackingProvider()
        hands = HandTrackingProvider()
        referenceYaw = nil
        referencePosition = nil

        var providers: [any DataProvider] = []
        if WorldTrackingProvider.isSupported { providers.append(world) }
        if HandTrackingProvider.isSupported { providers.append(hands) }
        guard !providers.isEmpty else {
            statusText = "이 환경에서는 머리/손 추적을 지원하지 않습니다"
            return
        }
        statusText = "추적 시작 중…"
        do {
            try await session.run(providers)
            guard myGeneration == generation else { return } // 그 사이 stop() 됨
            isRunning = true
            statusText = HandTrackingProvider.isSupported ? "머리 + 손 추적 중" : "머리 추적 중"
            if HandTrackingProvider.isSupported {
                let hands = self.hands
                handTask = Task { [weak self] in
                    for await update in hands.anchorUpdates {
                        if Task.isCancelled { break }
                        guard let self else { break }
                        let anchor = update.anchor
                        guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
                            if anchor.chirality == .left { leftWrist = nil } else { rightWrist = nil }
                            continue
                        }
                        let wrist = anchor.originFromAnchorTransform * skeleton.joint(.wrist).anchorFromJointTransform
                        let p = SIMD3(wrist.columns.3.x, wrist.columns.3.y, wrist.columns.3.z)
                        if anchor.chirality == .left { leftWrist = p } else { rightWrist = p }
                    }
                }
            }
        } catch {
            statusText = "추적 시작 실패: \(error.localizedDescription)"
        }
    }

    func stop() {
        generation += 1
        handTask?.cancel()
        handTask = nil
        let session = self.session
        // 동기 stop 이 메인 스레드를 잡지 않도록 분리
        Task.detached { session.stop() }
        isRunning = false
        headTransform = nil
        leftWrist = nil
        rightWrist = nil
        referenceYaw = nil
        referencePosition = nil
        statusText = "대기"
    }

    /// 현재 바라보는 방향을 "정면"으로 삼는다.
    func calibrate() {
        poll()
        calibrateFromCurrent()
    }

    /// 최신 디바이스 앵커를 읽는다. 30Hz 틱마다 호출.
    func poll() {
        guard isRunning, WorldTrackingProvider.isSupported else { return }
        if let anchor = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), anchor.isTracked {
            headTransform = anchor.originFromAnchorTransform
            if referenceYaw == nil { calibrateFromCurrent() }
        }
    }

    private func calibrateFromCurrent() {
        guard let t = headTransform else { return }
        referenceYaw = Self.yaw(of: t)
        referencePosition = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }

    /// 머리/손 데이터를 페르소나 포즈로 변환. 추적이 없으면 nil.
    func currentPose(mouth: Float, speaking: Bool) -> PersonaPose? {
        guard let t = headTransform else { return nil }
        var pose = PersonaPose()
        let yaw = Self.yaw(of: t)
        pose.yaw = Self.wrap(yaw - (referenceYaw ?? yaw))
        let forward = -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        pose.pitch = asin(max(-1, min(1, forward.y)))
        let right = SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z)
        pose.roll = asin(max(-1, min(1, right.y)))
        let position = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        if let ref = referencePosition {
            // 좌석 정면 기준으로 회전시켜 "내 자리에서의" 이동량으로
            let d = position - ref
            let ry = referenceYaw ?? 0
            let rotated = SIMD3(cos(ry) * d.x - sin(ry) * d.z, d.y, sin(ry) * d.x + cos(ry) * d.z)
            pose.offset = rotated
        }
        pose.mouth = mouth
        pose.speaking = speaking

        let inverse = t.inverse
        func relative(_ world: SIMD3<Float>?) -> SIMD3<Float>? {
            guard let world else { return nil }
            let p = inverse * SIMD4(world, 1)
            return SIMD3(p.x, p.y, p.z)
        }
        pose.leftHand = relative(leftWrist)
        pose.rightHand = relative(rightWrist)
        // 손목이 눈높이보다 8cm 이상 위 → 손들기
        pose.handRaised = [pose.leftHand, pose.rightHand].compactMap { $0 }.contains { $0.y > 0.08 }
        return pose
    }

    // MARK: - Math

    nonisolated static func yaw(of t: simd_float4x4) -> Float {
        let forward = -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        return atan2(-forward.x, -forward.z)
    }

    nonisolated static func wrap(_ angle: Float) -> Float {
        var a = angle
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }
}
#endif
