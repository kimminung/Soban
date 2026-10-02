#if os(visionOS)
import Foundation
import AVFAudio
import os

/// 데모 손님의 목소리. `AVSpeechSynthesizer.write` 로 한국어 TTS 를 PCM 버퍼로 뽑아
/// 좌석 위치에서 공간 재생하고, 50ms 단위 RMS 엔벨로프로 입 모양을 맞춘다.
final class BotSpeech {
    nonisolated struct Rendered: @unchecked Sendable {
        var buffers: [AVAudioPCMBuffer]
        /// 50ms 마다의 0…1 레벨
        var envelope: [Float]
        var hop: Double
        var duration: Double
    }

    static let lines: [String] = [
        "오늘 하루 어떠셨어요?",
        "차가 아직 따뜻하네요. 한 잔 더 드릴까요?",
        "이 상에 둘러앉으니 옛날 생각이 나요.",
        "요즘 뭐가 제일 재미있으세요?",
        "다음에는 다 같이 전을 부쳐 먹어요.",
        "밖에 바람이 좀 차던데, 여긴 참 아늑하네요.",
        "제가 어제 본 영화 이야기 해도 될까요?",
        "그 이야기 더 자세히 듣고 싶어요.",
        "다과 좀 드세요. 유과가 바삭해요.",
        "다음 모임은 누가 상을 차릴까요?",
        "오늘 목소리가 유난히 밝으시네요.",
        "잠깐만요, 할 말이 있어요.",
        "소반이 작아도 마음은 넉넉하죠.",
        "그럼 건배 대신 찻잔 한 번 들어 볼까요?",
    ]

    private let synthesizer = AVSpeechSynthesizer()
    private let log = Logger(subsystem: "com.coulson.Soban", category: "botspeech")
    private(set) var voiceAvailable: Bool = AVSpeechSynthesisVoice(language: "ko-KR") != nil

    /// 텍스트를 PCM 으로 렌더링한다. 음성이 없거나 실패하면 nil.
    func render(_ text: String, pitch: Float, rate: Float = AVSpeechUtteranceDefaultSpeechRate * 0.95) async -> Rendered? {
        guard let voice = AVSpeechSynthesisVoice(language: "ko-KR") else { return nil }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.pitchMultiplier = max(0.5, min(2.0, pitch))
        utterance.rate = rate
        utterance.volume = 1

        let box = BufferBox()
        let synthesizer = self.synthesizer
        let ok: Bool = await withCheckedContinuation { continuation in
            box.onFinish = { continuation.resume(returning: true) }
            synthesizer.write(utterance) { buffer in
                box.append(buffer)
            }
            // 안전장치: 12초 안에 끝나지 않으면 포기
            box.armTimeout(seconds: 12)
        }
        guard ok else { return nil }
        let buffers = box.drain()
        guard !buffers.isEmpty else { return nil }

        var envelope: [Float] = []
        var totalFrames: Double = 0
        let sampleRate = buffers[0].format.sampleRate
        let hopFrames = Int(sampleRate * 0.05)
        var window: [Float] = []
        for buffer in buffers {
            totalFrames += Double(buffer.frameLength)
            guard let channel = buffer.floatChannelData?[0] else { continue }
            for i in 0..<Int(buffer.frameLength) {
                window.append(channel[i])
                if window.count >= hopFrames {
                    envelope.append(Self.level(window))
                    window.removeAll(keepingCapacity: true)
                }
            }
        }
        if !window.isEmpty { envelope.append(Self.level(window)) }
        // 살짝 평활
        if envelope.count > 2 {
            for i in 1..<(envelope.count - 1) { envelope[i] = max(envelope[i], (envelope[i - 1] + envelope[i + 1]) / 2 * 0.9) }
        }
        return Rendered(buffers: buffers, envelope: envelope, hop: 0.05, duration: totalFrames / sampleRate)
    }

    private nonisolated static func level(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for v in samples { sum += v * v }
        let rms = sqrt(sum / Float(max(1, samples.count)))
        return min(1, rms * 7)
    }
}

/// write 콜백은 임의 스레드에서 오므로 락으로 모은다. 길이 0 버퍼가 끝 신호.
nonisolated final class BufferBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var finished = false
    var onFinish: (@Sendable () -> Void)?

    func append(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        let done: Bool = lock.withLock {
            if finished { return false }
            if pcm.frameLength == 0 {
                finished = true
                return true
            }
            // Float32 모노가 아니면 변환해 둔다 (환경 노드가 모노만 공간화)
            buffers.append(Self.normalize(pcm))
            return false
        }
        if done { onFinish?() }
    }

    func armTimeout(seconds: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            let fire: Bool = self.lock.withLock {
                if self.finished { return false }
                self.finished = true
                return true
            }
            if fire { self.onFinish?() }
        }
    }

    func drain() -> [AVAudioPCMBuffer] {
        lock.withLock { buffers }
    }

    private static func normalize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let format = buffer.format
        if format.commonFormat == .pcmFormatFloat32 && format.channelCount == 1 && !format.isInterleaved { return buffer }
        guard let target = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: format, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength) else { return buffer }
        var error: NSError?
        var consumed = false
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : buffer
    }
}
#endif
