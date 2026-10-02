import Foundation
import AVFAudio
import Observation
import os

/// 입 모양을 움직일 신호의 종류. 우선순위: 얼굴 추적(TrueDepth ARKit) > 카메라 입술 랜드마크 > 마이크 음량.
nonisolated enum MouthSourceKind: String, Sendable {
    case faceTracking   // iPhone/iPad TrueDepth: ARKit jawOpen
    case cameraLips     // 일반 카메라: Vision 입술 랜드마크
    case microphone     // 마이크 RMS
    case none

    var title: String {
        switch self {
        case .faceTracking: "얼굴 추적 (TrueDepth)"
        case .cameraLips: "카메라 입술 추적"
        case .microphone: "마이크 음량"
        case .none: "없음"
        }
    }

    var systemImage: String {
        switch self {
        case .faceTracking: "faceid"
        case .cameraLips: "camera.viewfinder"
        case .microphone: "mic"
        case .none: "mic.slash"
        }
    }
}

/// 마이크 음량만 재는 가벼운 미터. 모든 플랫폼. 음성 전송은 하지 않는다.
///
/// visionOS 에는 입 모양을 보는 내부 카메라/LiDAR 접근이 없으므로 이것이 유일한 입 신호다.
@Observable
final class MicLevelMeter {
    private let engine = AVAudioEngine()
    private(set) var isRunning = false
    private(set) var level: Float = 0
    private(set) var peak: Float = 0
    private(set) var errorText: String?
    private(set) var permission: String = "확인 전"
    private let sink = LevelSink()
    private var pollTask: Task<Void, Never>?

    var permissionGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }

    func refreshPermissionText() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: permission = "허용됨"
        case .denied: permission = "거부됨 — 설정 > 개인정보 보호 > 마이크에서 소반을 켜 주세요"
        case .undetermined: permission = "아직 묻지 않음"
        @unknown default: permission = "알 수 없음"
        }
    }

    /// 권한을 요청하고 캡처를 시작한다.
    func start() async {
        guard !isRunning else { return }
        #if targetEnvironment(simulator) && os(visionOS)
        errorText = "시뮬레이터에서는 마이크를 쓸 수 없습니다. 실기기에서 확인하세요."
        refreshPermissionText()
        return
        #else
        let granted = await AVAudioApplication.requestRecordPermission()
        refreshPermissionText()
        guard granted else {
            errorText = "마이크 권한이 없습니다."
            return
        }
        do {
            #if os(iOS) || os(visionOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setActive(true)
            #endif
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                errorText = "사용 가능한 마이크 입력이 없습니다."
                return
            }
            if #available(iOS 27, macOS 27, visionOS 27, *) {
                try input.installAudioTap(onBus: 0, bufferSize: 2048, format: format) { [sink] buffer, _ in
                    guard case .float(let samples) = buffer.channelData(0) else { return }
                    var sum: Float = 0
                    let n = samples.count
                    for i in 0..<n { let v = samples[i]; sum += v * v }
                    sink.push(sqrt(sum / Float(max(1, n))))
                }
            } else {
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { [sink] buffer, _ in
                    guard let ch = buffer.floatChannelData?[0] else { return }
                    var sum: Float = 0
                    let n = Int(buffer.frameLength)
                    for i in 0..<n { sum += ch[i] * ch[i] }
                    sink.push(sqrt(sum / Float(max(1, n))))
                }
            }
            engine.prepare()
            try engine.start()
            isRunning = true
            errorText = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    let rms = sink.take()
                    let lvl = min(1, max(0, rms * 9 - 0.02))
                    level = max(lvl, level * 0.6)
                    peak = max(lvl, peak * 0.985)
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        } catch {
            errorText = "마이크 시작 실패: \(error.localizedDescription)"
        }
        #endif
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        level = 0
        peak = 0
    }
}

nonisolated final class LevelSink: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var value: Float = 0
    func push(_ rms: Float) { lock.withLock { value = max(value, rms) } }
    func take() -> Float { lock.withLock { let v = value; value = 0; return v } }
}
