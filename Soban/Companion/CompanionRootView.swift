import SwiftUI
#if os(iOS) || os(macOS)
import UniformTypeIdentifiers

/// iPhone / iPad / Mac 에서 실행되는 "소반 캡처" 모드.
/// 각도 안내 촬영 → 페르소나 생성 → 가우시안 스플랫 입체화 → 움직여 보기(얼굴/입술/마이크) → Vision Pro 전송 또는 공유.
struct CompanionRootView: View {
    @State private var camera = CameraCaptureController()
    @State private var sender = PersonaSender()
    @State private var mic = MicLevelMeter()
    #if os(iOS)
    @State private var faceTracker = FaceMouthTracker()
    #endif
    @State private var name = ""
    @State private var package: PersonaPackage?
    @State private var packageImage: CGImage?
    @State private var splats: SplatCloud?
    @State private var progress: PersonaBuilder.Progress?
    @State private var splatProgress: SplatBuilder.Progress?
    @State private var errorText: String?
    @State private var isBuilding = false
    @State private var isSplatting = false
    @State private var exportURL: URL?
    @State private var plyURL: URL?
    @State private var packageURL: URL?
    @State private var show3D = true
    @State private var mouthEnabled = false
    @State private var mouthSource: MouthSourceKind = .none

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    capabilityBanner
                    if package == nil {
                        cameraSection
                    } else {
                        resultSection
                    }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("소반 캡처")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
        .task {
            await camera.start()
            sender.startBrowsing()
        }
        .onDisappear {
            camera.stop()
            sender.stop()
            stopMouth()
        }
    }

    // MARK: - Sections

    private var capabilityBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: camera.capability.systemImage).font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(camera.capability.title).font(.headline)
                Text(camera.capability.detail).font(.footnote).foregroundStyle(.secondary)
                if camera.isRunning && !camera.mouthTrackingMode {
                    Text(camera.depthDeliveryActive ? "깊이 기록 켜짐 — 스플랫이 실제 깊이로 만들어집니다" : "깊이 없음 — 스플랫은 얼굴 리그 부조로 만들어집니다")
                        .font(.caption).foregroundStyle(camera.depthDeliveryActive ? .green : .secondary)
                }
            }
            Spacer()
            if camera.canSwitchCamera && package == nil {
                Button { camera.switchCamera() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera") }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.85))
                if let img = camera.previewImage {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                } else if case .unavailable(let reason) = camera.capability {
                    ContentUnavailableView("카메라 사용 불가", systemImage: "camera.badge.ellipsis", description: Text(reason))
                        .foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
                guideOverlay
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(previewAspect, contentMode: .fit)

            if let err = camera.errorText ?? errorText {
                Label(err, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }

            thumbnails

            HStack {
                TextField("페르소나 이름", text: $name)
                    .textFieldStyle(.roundedBorder)
                Button("다시 촬영") { camera.restart() }
                    .disabled(camera.captures.isEmpty)
                Button("이 단계 건너뛰기") { camera.skipCurrentAngle() }
                    .disabled(camera.guide.current == nil || camera.guide.current == .center)
            }

            Button {
                Task { await build() }
            } label: {
                if isBuilding, let progress {
                    HStack { ProgressView(); Text(progress.message) }
                } else {
                    Label("페르소나 만들기", systemImage: "person.crop.square.badge.camera")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(camera.captures[.center] == nil || isBuilding)

            Text("정면 사진으로 카드를 만들고, 측면·위쪽 사진은 머리 옆면 색을 채우는 데 쓰입니다. 모든 처리는 이 기기 안에서 끝납니다.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// 미리보기 비율: 프레임이 오면 그 비율, 없으면 iPhone 세로 3:4 / Mac 가로 4:3.
    private var previewAspect: CGFloat {
        if let img = camera.previewImage, img.height > 0 { return CGFloat(img.width) / CGFloat(img.height) }
        #if os(macOS)
        return 4 / 3
        #else
        return 3 / 4
        #endif
    }

    private var guideOverlay: some View {
        VStack {
            HStack {
                Text(camera.guide.progressText)
                    .font(.caption.monospacedDigit())
                    .padding(8).background(.ultraThinMaterial, in: Capsule())
                Spacer()
                if let yaw = camera.yawDegrees, let pitch = camera.pitchDegrees {
                    Text(String(format: "yaw %+.0f° · pitch %+.0f°", yaw, pitch))
                        .font(.caption.monospacedDigit())
                        .padding(8).background(.ultraThinMaterial, in: Capsule())
                }
            }
            Spacer()
            ZStack {
                Ellipse()
                    .stroke(camera.faceVisible ? Color.green.opacity(0.9) : Color.white.opacity(0.5),
                            style: StrokeStyle(lineWidth: 3, dash: camera.faceVisible ? [] : [8, 6]))
                    .frame(width: 190, height: 250)
                if case .holding(_, let t) = camera.guide.phase {
                    Ellipse()
                        .trim(from: 0, to: t)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 204, height: 264)
                        .rotationEffect(.degrees(-90))
                }
                if case .capturing = camera.guide.phase {
                    Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.white)
                }
            }
            Spacer()
            VStack(spacing: 4) {
                if camera.guide.phase == .done {
                    Text("촬영 완료").font(.headline)
                    Text("아래에서 이름을 적고 페르소나를 만드세요").font(.footnote)
                } else if let angle = camera.guide.current {
                    Text(angle.title).font(.headline)
                    Text(camera.faceVisible ? angle.instruction : "얼굴이 보이도록 카메라를 맞춰 주세요").font(.footnote)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(14)
    }

    private var thumbnails: some View {
        HStack(spacing: 10) {
            ForEach(CaptureGuide.order, id: \.self) { angle in
                VStack(spacing: 4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(.thinMaterial).frame(width: 64, height: 80)
                        if let frame = camera.captures[angle] {
                            Image(decorative: frame.image, scale: 1).resizable().scaledToFill()
                                .frame(width: 64, height: 80).clipShape(RoundedRectangle(cornerRadius: 10))
                            if frame.depth != nil {
                                Image(systemName: "cube.transparent").font(.caption2).padding(4)
                                    .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white)
                                    .frame(width: 64, height: 80, alignment: .bottomTrailing)
                            }
                        } else if camera.guide.current == angle {
                            Image(systemName: "viewfinder").foregroundStyle(.green)
                        }
                    }
                    Text(angle.title).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Result

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let package, let img = packageImage {
                // 3D / 카드 미리보기
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(package.manifest.name).font(.title2.bold())
                        Spacer()
                        Picker("", selection: $show3D) {
                            Text("카드").tag(false)
                            Text("입체(스플랫)").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                        .disabled(splats == nil)
                    }
                    PersonaPreviewView(manifest: package.manifest, image: img, splats: show3D ? splats : nil,
                                       name: package.manifest.name,
                                       levelSource: { [mic, camera] in
                                           #if os(iOS)
                                           return currentMouthLevel(mic: mic, camera: camera, face: faceTracker)
                                           #else
                                           return currentMouthLevel(mic: mic, camera: camera)
                                           #endif
                                       },
                                       demoMotion: !mouthEnabled, turntable: show3D && splats != nil && !mouthEnabled)
                        .frame(height: 360)
                        .background(
                            LinearGradient(colors: [Color(red: 0.98, green: 0.96, blue: 0.91), Color(red: 0.90, green: 0.84, blue: 0.72)],
                                           startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 18))
                    HStack(spacing: 14) {
                        Label("\(package.manifest.imageWidth)×\(package.manifest.imageHeight)", systemImage: "photo")
                        Label(package.manifest.face == nil ? "얼굴 리그 없음" : "눈·입 리그", systemImage: "face.dashed")
                        Label(package.manifest.hasDepth ? "깊이 보정" : "깊이 없음", systemImage: "cube.transparent")
                        Label("보조 각도 \(package.sideViews.count)장", systemImage: "rectangle.stack")
                        if let splats { Label("스플랫 \(splats.count.formatted())개", systemImage: "sparkles") }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }

                // 스플랫
                VStack(alignment: .leading, spacing: 8) {
                    Text("가우시안 스플랫 입체화").font(.headline)
                    Text(package.manifest.hasDepth
                         ? "깊이 맵으로 3D 점을 만들고 각 점을 가우시안 스플랫으로 초기화합니다. 측면 사진으로 머리 옆면 색을 채웁니다."
                         : "깊이가 없어 얼굴 리그에 맞춘 머리 타원체·몸통 부조로 3D 점을 만듭니다. 측면 사진으로 머리 옆면 색을 채웁니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            Task { await buildSplats() }
                        } label: {
                            if isSplatting, let splatProgress {
                                HStack { ProgressView(); Text(splatProgress.message) }
                            } else {
                                Label(splats == nil ? "입체(스플랫) 만들기" : "다시 만들기", systemImage: "sparkles")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSplatting)
                        if let plyURL {
                            ShareLink(item: plyURL) { Label("3DGS PLY 내보내기", systemImage: "square.and.arrow.up") }
                        }
                    }
                    if let packageURL {
                        ShareLink(item: packageURL) {
                            Label("소반 패키지(.sobanpersona) 공유 — AirDrop 으로 Vision Pro 에서 바로 열기", systemImage: "visionpro.and.arrow.forward")
                        }
                        Text("Vision Pro 에서 받은 뒤 공유 시트에서 '소반' 을 고르면 카드·깊이·측면·스플랫이 한 번에 초안으로 열립니다. PLY 만 보내도 소반이 열어 카드와 얼굴 리그를 다시 만듭니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                // 움직여 보기
                mouthSection

                // 전송
                VStack(alignment: .leading, spacing: 8) {
                    Text("Vision Pro 로 보내기").font(.headline)
                    Text(sender.statusText).font(.footnote).foregroundStyle(.secondary)
                    if sender.receivers.isEmpty {
                        HStack { ProgressView(); Text("Vision Pro 의 소반 앱에서 페르소나 탭 → '기기에서 받기' 를 켜 주세요.").font(.footnote) }
                    }
                    ForEach(sender.receivers) { r in
                        HStack {
                            Image(systemName: "visionpro")
                            Text(r.name)
                            Spacer()
                            Button(sender.isSending ? "전송 중…" : (splats == nil ? "사진만 보내기" : "스플랫 포함 보내기")) {
                                var pkg = package
                                pkg.splats = splats?.encode()
                                pkg.manifest.hasSplats = splats != nil
                                pkg.manifest.splatCount = splats?.count ?? 0
                                sender.send(pkg, to: r)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(sender.isSending)
                        }
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if sender.didSend {
                        Label("전송 완료", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(splats == nil
                         ? "사진만 보내면 Vision Pro 가 받은 다각도 사진으로 직접 스플랫을 만들어 초안으로 띄웁니다."
                         : "스플랫까지 보내면 Vision Pro 는 바로 입체 초안을 띄웁니다. 저장을 누르면 즉시 내 페르소나가 됩니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                HStack {
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("카드 PNG 공유 (AirDrop)", systemImage: "square.and.arrow.up") }
                    }
                    Button("다시 촬영") {
                        stopMouth()
                        self.package = nil
                        packageImage = nil
                        splats = nil
                        plyURL = nil
                        packageURL = nil
                        Task { await camera.start() }
                        camera.restart()
                    }
                }
            }
        }
    }

    private var mouthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("움직여 보기 — 입 모양").font(.headline)
                Spacer()
                Toggle("", isOn: $mouthEnabled).labelsHidden()
                    .onChange(of: mouthEnabled) { _, on in
                        if on { Task { await startMouth() } } else { stopMouth() }
                    }
            }
            HStack(spacing: 10) {
                Image(systemName: mouthSource.systemImage)
                Text(mouthEnabled ? "입 신호: \(mouthSource.title)" : "켜면 이 기기에서 가능한 가장 좋은 입 신호를 고릅니다")
                    .font(.footnote)
                Spacer()
            }
            Text("우선순위: 얼굴 추적(TrueDepth) → 카메라 입술 랜드마크 → 마이크 음량. 미리보기 페르소나의 입이 따라 움직입니다.")
                .font(.caption).foregroundStyle(.secondary)
            if mouthEnabled {
                VoiceLevelBar(level: currentLevel, peak: mic.isRunning ? mic.peak : currentLevel)
                HStack(spacing: 12) {
                    Text("마이크: \(mic.permission)").font(.caption).foregroundStyle(.secondary)
                    if !mic.permissionGranted && mouthSource == .microphone {
                        Button("마이크 허용 요청") { Task { await mic.start() } }.font(.caption)
                    }
                }
                #if os(iOS)
                if let err = faceTracker.errorText { Text(err).font(.caption).foregroundStyle(.orange) }
                #endif
                if let err = mic.errorText { Text(err).font(.caption).foregroundStyle(.orange) }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var currentLevel: Float {
        #if os(iOS)
        return currentMouthLevel(mic: mic, camera: camera, face: faceTracker)
        #else
        return currentMouthLevel(mic: mic, camera: camera)
        #endif
    }

    // MARK: - Mouth sources

    #if os(iOS)
    private func currentMouthLevel(mic: MicLevelMeter, camera: CameraCaptureController, face: FaceMouthTracker) -> Float {
        switch mouthSource {
        case .faceTracking: return face.level
        case .cameraLips: return camera.mouthOpen
        case .microphone: return mic.level
        case .none: return 0
        }
    }
    #else
    private func currentMouthLevel(mic: MicLevelMeter, camera: CameraCaptureController) -> Float {
        switch mouthSource {
        case .cameraLips: return camera.mouthOpen
        case .microphone: return mic.level
        default: return 0
        }
    }
    #endif

    private func startMouth() async {
        mic.refreshPermissionText()
        #if os(iOS)
        if FaceMouthTracker.isSupported {
            camera.stop()
            faceTracker.start()
            mouthSource = .faceTracking
            return
        }
        #endif
        if case .unavailable = camera.capability {
            await mic.start()
            mouthSource = mic.isRunning ? .microphone : .none
            return
        }
        camera.mouthTrackingMode = true
        if !camera.isRunning { await camera.start() }
        mouthSource = camera.isRunning ? .cameraLips : .microphone
        if mouthSource == .microphone { await mic.start() }
    }

    private func stopMouth() {
        #if os(iOS)
        faceTracker.stop()
        #endif
        camera.mouthTrackingMode = false
        if package != nil { camera.stop() }
        mic.stop()
        mouthSource = .none
    }

    // MARK: - Actions

    private func build() async {
        guard let input = camera.makeCaptureInput() else { return }
        isBuilding = true
        errorText = nil
        defer { isBuilding = false }
        let personaName = name.trimmingCharacters(in: .whitespaces).isEmpty ? "내 페르소나" : name
        do {
            let result = try await PersonaBuilder.build(capture: input, name: personaName) { p in
                Task { @MainActor in progress = p }
            }
            package = result
            packageImage = PersonaBuilder.decodeImage(result.bodyPNG)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("소반-\(personaName).png")
            try? result.bodyPNG.write(to: url, options: .atomic)
            exportURL = url
            packageURL = try? PersonaPackageFile.write(result)
            camera.stop()
            await buildSplats()
        } catch {
            errorText = error.localizedDescription
        }
        progress = nil
    }

    private func buildSplats() async {
        guard let package else { return }
        isSplatting = true
        defer { isSplatting = false }
        do {
            let cloud = try await SplatBuilder.build(from: package) { p in
                Task { @MainActor in splatProgress = p }
            }
            splats = cloud
            show3D = true
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("소반-\(package.manifest.name).ply")
            try? cloud.plyData().write(to: url, options: .atomic)
            plyURL = url
            var full = package
            full.splats = cloud.encode()
            full.manifest.hasSplats = true
            full.manifest.splatCount = cloud.count
            packageURL = try? PersonaPackageFile.write(full)
        } catch {
            errorText = "스플랫 생성 실패: \(error.localizedDescription)"
        }
        splatProgress = nil
    }
}
#endif

/// 넓은 세그먼트 레벨미터 + 피크 홀드. 모든 플랫폼.
struct VoiceLevelBar: View {
    let level: Float
    let peak: Float
    var segments = 24

    var body: some View {
        GeometryReader { geo in
            let w = (geo.size.width - CGFloat(segments - 1) * 3) / CGFloat(segments)
            HStack(spacing: 3) {
                ForEach(0..<segments, id: \.self) { i in
                    let t = Float(i) / Float(segments)
                    let on = t < level
                    let isPeak = abs(t - peak) < 1 / Float(segments) && peak > 0.02
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isPeak ? Color.white : (on ? (t > 0.8 ? Color.orange : Color.green) : Color.primary.opacity(0.12)))
                        .frame(width: w)
                }
            }
        }
        .frame(height: 18)
        .accessibilityLabel("입 신호 레벨")
        .accessibilityValue("\(Int(level * 100))퍼센트")
    }
}
