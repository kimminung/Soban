#if os(iOS) || os(macOS)
import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import Observation
import QuartzCore
import Vision
import os

/// iPhone/iPad/Mac 에서 얼굴을 각도별로 안내 촬영한다. 깊이 카메라가 있으면 깊이 맵을 함께 기록한다.
///
/// - 미리보기: `AVCaptureVideoDataOutput` 프레임을 480px 로 줄여 `previewImage` 로 발행 (전면 카메라는 거울처럼 좌우 반전)
/// - 각도: 3프레임마다 `DetectFaceRectanglesRequest` 의 yaw/pitch
/// - 촬영: `AVCapturePhotoOutput` (+ `isDepthDataDeliveryEnabled`)
@Observable
final class CameraCaptureController {
    nonisolated struct CapturedFrame: Sendable {
        var image: CGImage
        var depth: DepthMap?
    }

    private(set) var capability: CaptureCapability = .unavailable("확인 중")
    private(set) var isRunning = false
    private(set) var previewImage: CGImage?
    private(set) var yawDegrees: Double?
    private(set) var pitchDegrees: Double?
    private(set) var faceVisible = false
    private(set) var guide = CaptureGuide()
    private(set) var captures: [CaptureAngle: CapturedFrame] = [:]
    private(set) var errorText: String?
    private(set) var isCapturingPhoto = false
    private(set) var usingFrontCamera = true
    private(set) var depthDeliveryActive = false
    /// 입술 추적 모드: 프레임마다 입술 랜드마크로 입 벌림(0…1)을 낸다. 촬영 안내는 멈춘다.
    var mouthTrackingMode = false {
        didSet { frameSink?.mouthMode = mouthTrackingMode }
    }
    private(set) var mouthOpen: Float = 0
    /// 8차: Vision 76점 랜드마크에서 추정한 ARKit 미니 세트(jawOpen·eyeBlink·mouthSmile·mouthPucker·browInnerUp). 깜빡임은 거칠다.
    private(set) var faceWeights: ArkitWeights?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.coulson.Soban.capture")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var frameSink: FrameSink?
    private var photoSink: PhotoSink?
    private let log = Logger(subsystem: "com.coulson.Soban", category: "capture")

    var canSwitchCamera: Bool {
        #if os(iOS)
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
            && AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
        #else
        return false
        #endif
    }

    var allCaptured: Bool { guide.phase == .done && captures[.center] != nil }

    // MARK: - Lifecycle

    func start() async {
        capability = CaptureAvailability.detect()
        if case .unavailable = capability { return }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
            errorText = "카메라 권한이 없습니다. 설정에서 소반의 카메라 접근을 허용해 주세요."
            return
        }
        weak var weakSelf = self
        let sink = FrameSink { image, yaw, pitch, mouth, weights in
            Task { @MainActor in weakSelf?.handleFrame(image, yaw: yaw, pitch: pitch, mouth: mouth, weights: weights) }
        }
        sink.mouthMode = mouthTrackingMode
        frameSink = sink
        let front = usingFrontCamera
        let result: Result<Bool, any Error> = await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    let depth = try configureSession(front: front, sink: sink)
                    session.startRunning()
                    continuation.resume(returning: .success(depth))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        switch result {
        case .success(let depth):
            isRunning = true
            depthDeliveryActive = depth
            errorText = nil
            guide.start()
        case .failure(let error):
            errorText = "카메라를 시작하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sessionQueue.async { [session] in
            session.stopRunning()
        }
    }

    func switchCamera() {
        guard canSwitchCamera else { return }
        usingFrontCamera.toggle()
        stop()
        Task { await start() }
    }

    func restart() {
        captures.removeAll()
        guide.start()
    }

    func skipCurrentAngle() {
        guide.skipCurrent()
    }

    // MARK: - Session configuration (sessionQueue)

    private nonisolated func configureSession(front: Bool, sink: FrameSink) throws -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.sessionPreset = .photo

        var device: AVCaptureDevice?
        var depthCapable = false
        #if os(iOS)
        if front {
            if let d = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) {
                device = d; depthCapable = true
            } else {
                device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            }
        } else {
            if let d = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) {
                device = d; depthCapable = true
            } else {
                device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            }
        }
        #else
        device = AVCaptureDevice.default(for: .video)
        #endif
        guard let device else { throw CaptureError.noDevice }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "com.coulson.Soban.frames"))
        guard session.canAddOutput(videoOutput) else { throw CaptureError.cannotAddOutput }
        session.addOutput(videoOutput)

        guard session.canAddOutput(photoOutput) else { throw CaptureError.cannotAddOutput }
        session.addOutput(photoOutput)
        var depthOn = false
        #if os(iOS)
        if depthCapable && photoOutput.isDepthDataDeliverySupported {
            photoOutput.isDepthDataDeliveryEnabled = true
            depthOn = true
        }
        #else
        _ = depthCapable
        #endif

        // 세로 방향 + 전면 거울
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 }) {
            #if os(iOS)
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            #endif
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                // 미리보기만 거울처럼. 사진은 남이 보는 모습 그대로 저장한다.
                connection.isVideoMirrored = (connection.output === videoOutput) && front
            }
        }
        return depthOn
    }

    nonisolated enum CaptureError: LocalizedError {
        case noDevice, cannotAddInput, cannotAddOutput, photoFailed
        var errorDescription: String? {
            switch self {
            case .noDevice: "사용할 카메라가 없습니다."
            case .cannotAddInput: "카메라 입력을 추가할 수 없습니다."
            case .cannotAddOutput: "카메라 출력을 추가할 수 없습니다."
            case .photoFailed: "사진 촬영에 실패했습니다."
            }
        }
    }

    // MARK: - Frames

    private func handleFrame(_ image: CGImage, yaw: Double?, pitch: Double?, mouth: Float?, weights: ArkitWeights?) {
        guard isRunning else { return }
        previewImage = image
        if let yaw { yawDegrees = yaw }
        if let pitch { pitchDegrees = pitch }
        faceVisible = yaw != nil
        if mouthTrackingMode {
            if let mouth { mouthOpen = mouthOpen * 0.4 + mouth * 0.6 } else { mouthOpen *= 0.8 }
            if let weights {
                // 랜드마크 지터 완화: 0.5 스무딩
                faceWeights = faceWeights.map { $0.blended(toward: weights, 0.5) } ?? weights
            } else if mouth == nil, faceWeights != nil {
                faceWeights = faceWeights?.blended(toward: .zero, 0.3)
            }
            return
        }
        let now = CACurrentMediaTime()
        if guide.update(yaw: yaw, pitch: pitch, now: now), let angle = guide.current, !isCapturingPhoto {
            capturePhoto(for: angle)
        }
    }

    private func capturePhoto(for angle: CaptureAngle) {
        isCapturingPhoto = true
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA) {
            settings = AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        } else {
            settings = AVCapturePhotoSettings()
        }
        #if os(iOS)
        if depthDeliveryActive && photoOutput.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
            settings.embedsDepthDataInPhoto = false
            settings.isDepthDataFiltered = true
        }
        #endif
        weak var weakSelf = self
        let sink = PhotoSink { result in
            Task { @MainActor in weakSelf?.finishCapture(angle: angle, result: result) }
        }
        photoSink = sink
        photoOutput.capturePhoto(with: settings, delegate: sink)
    }

    private func finishCapture(angle: CaptureAngle, result: Result<CapturedFrame, any Error>) {
        isCapturingPhoto = false
        photoSink = nil
        switch result {
        case .success(let frame):
            captures[angle] = frame
            guide.didCapture(angle)
        case .failure(let error):
            errorText = error.localizedDescription
            guide.captureFailed(angle)
        }
    }

    // MARK: - Build

    func makeCaptureInput() -> PersonaBuilder.CaptureInput? {
        guard let center = captures[.center] else { return nil }
        var sides: [String: CGImage] = [:]
        for (angle, frame) in captures where angle != .center {
            if let key = angle.sideViewKey { sides[key] = frame.image }
        }
        return PersonaBuilder.CaptureInput(frontal: center.image, depth: center.depth, sideViews: sides,
                                           source: capability.captureSource, deviceName: CaptureAvailability.deviceName)
    }
}

// MARK: - Frame sink (video queue)

nonisolated final class FrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let handler: @Sendable (CGImage, Double?, Double?, Float?, ArkitWeights?) -> Void
    private var frameIndex = 0
    private var lastYaw: Double?
    private var lastPitch: Double?
    private var lastFaceFrame = -10
    private let lock = OSAllocatedUnfairLock()
    private var _mouthMode = false
    var mouthMode: Bool {
        get { lock.withLock { _mouthMode } }
        set { lock.withLock { _mouthMode = newValue } }
    }

    init(handler: @escaping @Sendable (CGImage, Double?, Double?, Float?, ArkitWeights?) -> Void) {
        self.handler = handler
    }

    /// 입술·눈·눈썹 랜드마크 → 입 벌림 + ARKit 미니 세트.
    /// 입 벌림: 안쪽 입술 높이 / 얼굴 높이, 다문 상태(≈0.02) 를 0, 0.09 를 1 로.
    private func faceSignals(_ cg: CGImage) -> (open: Float, weights: ArkitWeights)? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let lm = face.landmarks, let inner = lm.innerLips else { return nil }
        let pts = inner.normalizedPoints
        guard pts.count >= 4 else { return nil }
        let faceH = Float(max(0.001, face.boundingBox.height))
        func span(_ r: VNFaceLandmarkRegion2D?, _ key: KeyPath<CGPoint, CGFloat>) -> Float? {
            guard let p = r?.normalizedPoints, !p.isEmpty else { return nil }
            let v = p.map { Float($0[keyPath: key]) }
            return v.max()! - v.min()!
        }
        let lipHeight = span(inner, \.y) ?? 0
        let open = min(1, max(0, (lipHeight - 0.02) / 0.07))

        var w = ArkitWeights()
        w[.jawOpen] = open * 0.7
        w[.mouthFunnel] = open * 0.2
        // 눈 개방도(높이/폭): 0.32 이상 열림, 0.14 이하 감김. Vision 의 leftEye 는 피사체 기준 왼쪽.
        func blink(_ eye: VNFaceLandmarkRegion2D?) -> Float {
            guard let h = span(eye, \.y), let wdt = span(eye, \.x), wdt > 0.001 else { return 0 }
            let ratio = h / wdt
            return min(1, max(0, (0.32 - ratio) / 0.18))
        }
        w[.eyeBlinkLeft] = blink(lm.leftEye)
        w[.eyeBlinkRight] = blink(lm.rightEye)
        // 미소: 바깥 입술 양끝이 입 중심보다 위(이미지 정규화, y 위가 +)
        if let outer = lm.outerLips?.normalizedPoints, outer.count >= 6 {
            let xs = outer.map { Float($0.x) }, ys = outer.map { Float($0.y) }
            let midY = (ys.max()! + ys.min()!) / 2
            let li = xs.firstIndex(of: xs.min()!)!, ri = xs.firstIndex(of: xs.max()!)!
            let lift = ((ys[li] + ys[ri]) / 2 - midY) / max(0.001, ys.max()! - ys.min()!)
            let smile = min(1, max(0, (lift - 0.05) / 0.3))
            w[.mouthSmileLeft] = smile; w[.mouthSmileRight] = smile
            // 오므림: 입 폭 / 얼굴 폭이 작으면
            let mouthW = (xs.max()! - xs.min()!) * Float(face.boundingBox.width)
            let ratio = mouthW / max(0.001, Float(face.boundingBox.width))
            w[.mouthPucker] = min(1, max(0, (0.34 - ratio) / 0.12))
            w[.mouthStretchLeft] = min(1, max(0, (ratio - 0.46) / 0.1)); w[.mouthStretchRight] = w[.mouthStretchLeft]
        }
        // 눈썹 올림: 눈썹–눈 거리 / 얼굴 높이
        if let brow = lm.leftEyebrow?.normalizedPoints, let eye = lm.leftEye?.normalizedPoints, !brow.isEmpty, !eye.isEmpty {
            let browY = brow.map { Float($0.y) }.reduce(0, +) / Float(brow.count)
            let eyeY = eye.map { Float($0.y) }.reduce(0, +) / Float(eye.count)
            let gap = (browY - eyeY) / max(0.001, faceH / Float(face.boundingBox.height))
            w[.browInnerUp] = min(1, max(0, (gap - 0.11) / 0.06))
        }
        _ = faceH
        return (open, w)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameIndex += 1
        // 미리보기 축소 (12fps 정도로 제한)
        guard frameIndex % 2 == 0 else { return }
        var ci = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = 480 / max(ci.extent.width, ci.extent.height)
        if scale < 1 { ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }

        if mouthMode {
            // 입술 추적: 3프레임마다 랜드마크
            if frameIndex % 3 == 0 {
                let signals = faceSignals(cg)
                handler(cg, signals == nil ? nil : (lastYaw ?? 0), signals == nil ? nil : (lastPitch ?? 0), signals?.open, signals?.weights)
            } else {
                handler(cg, lastYaw, lastPitch, nil, nil)
            }
            return
        }
        if frameIndex % 6 == 0 {
            // 델리게이트는 동기 콜백이라 레거시(동기) Vision API 를 쓴다. yaw/pitch 는 라디안 NSNumber.
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            if (try? handler.perform([request])) != nil,
               let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
                lastYaw = face.yaw.map { $0.doubleValue * 180 / .pi }
                lastPitch = face.pitch.map { $0.doubleValue * 180 / .pi } ?? 0
                lastFaceFrame = frameIndex
            } else {
                lastYaw = nil
                lastPitch = nil
            }
        }
        let recent = frameIndex - lastFaceFrame < 12
        handler(cg, recent ? lastYaw : nil, recent ? lastPitch : nil, nil, nil)
    }
}

// MARK: - Photo sink

nonisolated final class PhotoSink: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Result<CameraCaptureController.CapturedFrame, any Error>) -> Void
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(completion: @escaping @Sendable (Result<CameraCaptureController.CapturedFrame, any Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        if let error { completion(.failure(error)); return }
        guard let cg = photo.cgImageRepresentation() else {
            completion(.failure(CameraCaptureController.CaptureError.photoFailed)); return
        }
        #if os(iOS)
        let orientationRaw = (photo.metadata[kCGImagePropertyOrientation as String] as? UInt32) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up
        #else
        let orientation = CGImagePropertyOrientation.up
        #endif

        let oriented = CIImage(cgImage: cg).oriented(orientation)
        guard let image = ciContext.createCGImage(oriented, from: oriented.extent) else {
            completion(.failure(CameraCaptureController.CaptureError.photoFailed)); return
        }

        var depthMap: DepthMap?
        #if os(iOS)
        if let depthData = photo.depthData {
            let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            let depthCI = CIImage(cvPixelBuffer: converted.depthDataMap).oriented(orientation)
            let w = Int(depthCI.extent.width), h = Int(depthCI.extent.height)
            if w > 0, h > 0 {
                var values = [Float](repeating: .nan, count: w * h)
                values.withUnsafeMutableBytes { raw in
                    ciContext.render(depthCI, toBitmap: raw.baseAddress!, rowBytes: w * MemoryLayout<Float>.size,
                                     bounds: depthCI.extent, format: .Rf, colorSpace: nil)
                }
                // 깊이(미터). 0 이하/비정상은 NaN
                for i in 0..<values.count where !(values[i] > 0.05 && values[i] < 20) { values[i] = .nan }
                depthMap = DepthMap(width: w, height: h, meters: values)
            }
        }
        #endif
        completion(.success(CameraCaptureController.CapturedFrame(image: image, depth: depthMap)))
    }
}
#endif
