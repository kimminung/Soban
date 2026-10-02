#if os(visionOS)
import Foundation
import AVFAudio
import Observation
import os

/// 마이크 캡처(입 모양 + 음성 전송)와 원격 참가자 음성의 공간 재생을 담당한다.
///
/// - 캡처: 하드웨어 포맷 → 16kHz Int16 모노 PCM 로 다운샘플, 60ms 단위로 묶어 전달
/// - 재생: 참가자마다 `AVAudioPlayerNode` 를 `AVAudioEnvironmentNode` 에 연결, 좌석 위치에 배치
@Observable
final class VoiceEngine {
    nonisolated static let sampleRate: Double = 16_000
    nonisolated static let chunkFrames = 960 // 60ms @ 16k

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var playerFormats: [UUID: AVAudioFormat] = [:]
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: VoiceEngine.sampleRate, channels: 1)!
    private let sink = CaptureSink()

    private(set) var isCapturing = false
    private(set) var isEngineRunning = false
    private(set) var errorText: String?
    /// 0...1 로 정규화된 내 목소리 크기 (틱마다 갱신).
    private(set) var level: Float = 0
    /// 최근 피크(천천히 감쇠) — 레벨미터 표시용.
    private(set) var peak: Float = 0

    var permissionText: String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: "마이크 허용됨"
        case .denied: "마이크 거부됨 — 설정 > 개인정보 보호 > 마이크"
        case .undetermined: "마이크 권한 아직 묻지 않음"
        @unknown default: "마이크 권한 알 수 없음"
        }
    }

    private let log = Logger(subsystem: "com.coulson.Soban", category: "voice")

    // MARK: - Lifecycle

    /// 시뮬레이터의 AURemoteIO 는 초기화 RPC 가 타임아웃되며 abort 하는 일이 잦아 기본적으로 끈다.
    /// 실기기에서는 항상 켜진다.
    var audioAvailable: Bool {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SOBAN_SIM_AUDIO"] == "1"
        #else
        return true
        #endif
    }

    /// 엔진이 입력(마이크)을 포함해 구성되었는지. 출력 전용으로 먼저 시작된 엔진에서 나중에 `inputNode` 를 만지면
    /// 하드웨어 포맷이 0Hz/0ch 로 나와 "사용 가능한 마이크 입력이 없습니다" 가 뜬다 — 그래서 입력은 시작 **전에** 구성한다.
    private var inputConfigured = false
    /// 진단용: 입력 포맷/라우트.
    private(set) var inputStatusText = "입력 미구성"

    func startEngine(withInput: Bool = false) {
        guard !isEngineRunning else { return }
        guard audioAvailable else {
            errorText = "시뮬레이터에서는 오디오(마이크·공간 음향)를 끕니다. 실기기에서 확인하세요."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
            try session.setActive(true)

            if withInput && AVAudioApplication.shared.recordPermission == .granted {
                // 엔진 시작 전에 입력 노드를 생성해 I/O 유닛이 입력을 포함하도록 한다.
                let format = engine.inputNode.outputFormat(forBus: 0)
                inputConfigured = format.sampleRate > 0 && format.channelCount > 0
                let route = session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
                inputStatusText = inputConfigured
                    ? "입력 \(Int(format.sampleRate)) Hz · \(format.channelCount) ch · \(route.isEmpty ? "라우트 없음" : route)"
                    : "입력 포맷 0 — 라우트: \(route.isEmpty ? "없음" : route)"
            } else {
                inputConfigured = false
            }

            if environment.engine == nil {
                engine.attach(environment)
                environment.renderingAlgorithm = .HRTFHQ
                environment.listenerPosition = AVAudio3DPoint(x: 0, y: 1.2, z: 0)
                environment.distanceAttenuationParameters.referenceDistance = 0.8
                environment.distanceAttenuationParameters.maximumDistance = 8
                let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
                try engine.connectNode(environment, to: engine.mainMixerNode, format: stereo)
            }
            engine.prepare()
            try engine.start()
            isEngineRunning = true
            errorText = nil
        } catch {
            errorText = "오디오 엔진 시작 실패: \(error.localizedDescription)"
            log.error("engine start failed: \(error.localizedDescription)")
        }
    }

    /// 엔진을 멈췄다가 입력 포함/미포함으로 다시 시작한다. 플레이어 연결은 유지된다.
    private func restartEngine(withInput: Bool) {
        if isCapturing {
            engine.inputNode.removeTap(onBus: 0)
            isCapturing = false
        }
        for (_, p) in players { p.stop() }
        engine.stop()
        isEngineRunning = false
        startEngine(withInput: withInput)
    }

    func stopEngine() {
        stopCapture()
        for (_, p) in players { p.stop() }
        players.removeAll()
        playerFormats.removeAll()
        engine.stop()
        isEngineRunning = false
        inputConfigured = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Capture

    /// 시스템 마이크 권한 프롬프트를 띄우고(아직 안 물었을 때), 허용되면 입력 포함으로 엔진을 재시작해 캡처를 시작한다.
    @discardableResult
    func requestMicrophoneAccess() async -> Bool {
        guard audioAvailable else {
            errorText = "시뮬레이터에서는 마이크를 쓸 수 없습니다. 실기기에서 확인하세요."
            return false
        }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            errorText = "마이크 권한이 거부되어 있습니다. 설정 > 개인정보 보호 및 보안 > 마이크에서 소반을 켜 주세요."
            return false
        }
        errorText = nil
        if isCapturing { return true }
        restartEngine(withInput: true)
        await startCapture()
        return isCapturing
    }

    func startCapture() async {
        guard !isCapturing else { return }
        guard audioAvailable else {
            errorText = "시뮬레이터에서는 오디오(마이크·공간 음향)를 끕니다. 실기기에서 확인하세요."
            return
        }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            errorText = "마이크 권한이 없어 입 모양과 음성을 보낼 수 없습니다. '마이크 허용 요청' 을 눌러 주세요."
            return
        }
        if !isEngineRunning {
            startEngine(withInput: true)
        } else if !inputConfigured {
            restartEngine(withInput: true)
        }
        guard isEngineRunning else { return }
        let input = engine.inputNode
        var format = input.outputFormat(forBus: 0)
        if format.sampleRate == 0 || format.channelCount == 0 {
            // 한 번 더: 세션 활성화 직후 포맷이 늦게 잡히는 경우
            restartEngine(withInput: true)
            format = engine.inputNode.outputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorText = "사용 가능한 마이크 입력이 없습니다. (\(inputStatusText))"
            return
        }
        sink.configure(inputRate: format.sampleRate)
        do {
            try input.installAudioTap(onBus: 0, bufferSize: 2048, format: format) { [sink] buffer, _ in
                sink.ingest(buffer)
            }
            isCapturing = true
            errorText = nil
        } catch {
            errorText = "마이크 탭 설치 실패: \(error.localizedDescription)"
        }
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        isCapturing = false
        level = 0
    }

    /// 틱마다 호출: 레벨 갱신 + 전송 대기 중인 PCM 청크 반환.
    func drainCapture() -> [Data] {
        let (lvl, chunks) = sink.drain()
        // 부드럽게 감쇠
        level = max(lvl, level * 0.6)
        peak = max(lvl, peak * 0.985)
        return chunks
    }

    // MARK: - Playback

    func setListener(position: SIMD3<Float>, yaw: Float) {
        environment.listenerPosition = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: yaw * 180 / .pi, pitch: 0, roll: 0)
    }

    func setSource(_ id: UUID, position: SIMD3<Float>) {
        guard let player = players[id] else { return }
        player.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
    }

    func removeSource(_ id: UUID) {
        playerFormats[id] = nil
        guard let player = players.removeValue(forKey: id) else { return }
        player.stop()
        engine.detach(player)
    }

    /// 참가자용 플레이어를 가져오거나, 포맷이 다르면 다시 연결해 만든다.
    private func player(for id: UUID, format: AVAudioFormat) -> AVAudioPlayerNode? {
        if let existing = players[id], let f = playerFormats[id],
           f.sampleRate == format.sampleRate, f.channelCount == format.channelCount, f.commonFormat == format.commonFormat {
            return existing
        }
        removeSource(id)
        let player = AVAudioPlayerNode()
        player.renderingAlgorithm = .HRTFHQ
        player.sourceMode = .spatializeIfMono
        engine.attach(player)
        do {
            try engine.connectNode(player, to: environment, format: format)
        } catch {
            log.error("connect player failed: \(error.localizedDescription)")
            engine.detach(player)
            return nil
        }
        players[id] = player
        playerFormats[id] = format
        return player
    }

    /// 이미 디코딩된 PCM 버퍼들(예: TTS)을 한 번에 큐에 넣는다. 공간 위치는 좌석.
    func enqueue(_ id: UUID, buffers: [AVAudioPCMBuffer], position: SIMD3<Float>) {
        guard let first = buffers.first else { return }
        if !isEngineRunning { startEngine() }
        guard isEngineRunning, let player = player(for: id, format: first.format) else { return }
        player.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        for buffer in buffers { player.scheduleBuffer(buffer, completionHandler: nil) }
        if !player.isPlaying { try? player.playAudio(at: nil) }
    }

    /// 16kHz Int16 모노 PCM 을 재생 큐에 넣는다. 반환값은 이 청크의 RMS(0...1).
    @discardableResult
    func enqueue(_ id: UUID, pcm: Data, position: SIMD3<Float>) -> Float {
        if !isEngineRunning { startEngine() }
        guard isEngineRunning else { return 0 }
        guard let player = player(for: id, format: playbackFormat) else { return 0 }
        player.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)

        let frames = pcm.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return 0 }
        buffer.frameLength = AVAudioFrameCount(frames)
        var sum: Float = 0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let v = Float(samples[i]) / 32768
                channel[i] = v
                sum += v * v
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying {
            try? player.playAudio(at: nil)
        }
        let rms = sqrt(sum / Float(frames))
        return min(1, rms * 6)
    }
}

// MARK: - Capture sink (audio thread → main thread)

/// 오디오 스레드에서 들어오는 버퍼를 16kHz Int16 로 바꿔 쌓아 두는 락 보호 버퍼.
nonisolated final class CaptureSink: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var inputRate: Double = 48_000
    private var pending: [Int16] = []
    private var chunks: [Data] = []
    private var peakLevel: Float = 0
    private var resamplePhase: Double = 0

    func configure(inputRate: Double) {
        lock.withLock {
            self.inputRate = inputRate
            pending.removeAll()
            chunks.removeAll()
            resamplePhase = 0
        }
    }

    func ingest(_ buffer: AVReadOnlyAudioPCMBuffer) {
        guard case .float(let samples) = buffer.channelData(0) else { return }
        let count = samples.count
        guard count > 0 else { return }
        // RMS
        var sum: Float = 0
        for i in 0..<count { let v = samples[i]; sum += v * v }
        let rms = sqrt(sum / Float(count))
        let level = min(1, max(0, (rms * 9) - 0.02))

        // 선형 보간 다운샘플 → Int16
        let ratio = inputRate / VoiceEngine.sampleRate
        var out: [Int16] = []
        out.reserveCapacity(Int(Double(count) / ratio) + 2)
        var phase = lock.withLock { resamplePhase }
        while phase < Double(count - 1) {
            let i = Int(phase)
            let frac = Float(phase - Double(i))
            let v = samples[i] * (1 - frac) + samples[i + 1] * frac
            out.append(Int16(max(-1, min(1, v)) * 32767))
            phase += ratio
        }
        let nextPhase = phase - Double(count)
        let produced = out

        lock.withLock {
            resamplePhase = max(0, nextPhase)
            peakLevel = max(peakLevel, level)
            pending.append(contentsOf: produced)
            while pending.count >= VoiceEngine.chunkFrames {
                let chunk = Array(pending.prefix(VoiceEngine.chunkFrames))
                pending.removeFirst(VoiceEngine.chunkFrames)
                chunks.append(chunk.withUnsafeBufferPointer { Data(buffer: $0) })
            }
            // 네트워크가 막혀도 무한히 쌓이지 않게
            if chunks.count > 40 { chunks.removeFirst(chunks.count - 40) }
        }
    }

    func drain() -> (level: Float, chunks: [Data]) {
        lock.withLock {
            let result = (peakLevel, chunks)
            peakLevel = 0
            chunks = []
            return result
        }
    }
}
#endif
