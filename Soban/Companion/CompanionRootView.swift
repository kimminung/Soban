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
    /// 앱이 소유하는 데이터 상태 (창을 오가도 유지, Combine 디바운스 저장).
    @Bindable var model: CompanionModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    capabilityBanner
                    if model.package == nil {
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
            #if DEBUG
            // 검증용: `sample` 인자로 실행하면 Vision Pro 와 같은 샘플 페르소나를 바로 완성 상태로 띄운다
            if CommandLine.arguments.contains("sample"), model.package == nil {
                let sample = PlaceholderPersona.make(name: "콜슨", style: PlaceholderPersona.palette[0])
                model.package = sample
                model.packageImage = PersonaBuilder.decodeImage(sample.bodyPNG)
                await buildSplats()
                return
            }
            #endif
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
            if camera.canSwitchCamera && model.package == nil {
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

            if let err = camera.errorText ?? model.errorText {
                Label(err, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }

            thumbnails

            HStack {
                TextField("페르소나 이름", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                Button("다시 촬영") { camera.restart() }
                    .disabled(camera.captures.isEmpty)
                Button("이 단계 건너뛰기") { camera.skipCurrentAngle() }
                    .disabled(camera.guide.current == nil || camera.guide.current == .center)
            }

            Button {
                Task { await build() }
            } label: {
                if model.isBuilding, let p = model.progress {
                    HStack { ProgressView(); Text(p.message) }
                } else {
                    Label("페르소나 만들기", systemImage: "person.crop.square.badge.camera")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(camera.captures[.center] == nil || model.isBuilding)

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
            if let package = model.package, let img = model.packageImage {
                // 3D / 카드 미리보기
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(package.manifest.name).font(.title2.bold())
                        Spacer()
                        Picker("", selection: $model.show3D) {
                            Text("카드").tag(false)
                            Text("입체(스플랫)").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                        .disabled(model.splats == nil)
                    }
                    PersonaPreviewView(manifest: package.manifest, image: img, splats: model.show3D ? model.splats : nil,
                                       name: package.manifest.name,
                                       levelSource: { [mic, camera] in
                                           #if os(iOS)
                                           return currentMouthLevel(mic: mic, camera: camera, face: faceTracker)
                                           #else
                                           return currentMouthLevel(mic: mic, camera: camera)
                                           #endif
                                       },
                                       expressionSource: { [camera] in
                                           // 8차: iPhone TrueDepth 는 ARKit 52 전체(깜빡임 포함), 카메라 입술 모드는 랜드마크 미니 세트
                                           #if os(iOS)
                                           if model.mouthSource == .faceTracking, faceTracker.isRunning { return (faceTracker.weights, true) }
                                           #endif
                                           if model.mouthSource == .cameraLips, let w = camera.faceWeights { return (w, false) }
                                           return nil
                                       },
                                       demoMotion: !model.mouthEnabled, turntable: model.show3D && model.splats != nil && !model.mouthEnabled)
                        .frame(height: 360)
                        .background(
                            LinearGradient(colors: [Color(red: 0.98, green: 0.96, blue: 0.91), Color(red: 0.90, green: 0.84, blue: 0.72)],
                                           startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 18))
                    if let info = model.infoText {
                        Label(info, systemImage: "arrow.counterclockwise.circle").font(.footnote).foregroundStyle(.green)
                    }
                    HStack(spacing: 14) {
                        Label("\(package.manifest.imageWidth)×\(package.manifest.imageHeight)", systemImage: "photo")
                        Label(package.manifest.face == nil ? "얼굴 리그 없음" : "눈·입 리그", systemImage: "face.dashed")
                        Label(package.manifest.hasDepth ? "깊이 보정" : "깊이 없음", systemImage: "cube.transparent")
                        Label("보조 각도 \(package.sideViews.count)장", systemImage: "rectangle.stack")
                        if let s = model.splats { Label("스플랫 \(s.count.formatted())개", systemImage: "sparkles") }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }

                // 스플랫
                VStack(alignment: .leading, spacing: 8) {
                    Text("가우시안 스플랫 입체화").font(.headline)
                    HStack {
                        Text("얼굴 키트").font(.subheadline)
                        Picker("", selection: $model.faceKit) {
                            Text("남성형").tag("Male")
                            Text("여성형").tag("Female")
                            Text("끄기").tag("none")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                        .onChange(of: model.faceKit) { _, v in model.package?.manifest.faceKit = v }
                    }
                    Text("블렌더 USDZ 눈·입 키트가 스플랫 얼굴 위에 붙어 깜빡임과 입 모양을 블렌드셰이프로 움직입니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(package.manifest.hasDepth
                         ? "깊이 맵으로 3D 점을 만들고 각 점을 가우시안 스플랫으로 초기화합니다. 측면 사진으로 머리 옆면 색을 채웁니다."
                         : "깊이가 없어 흉상 템플릿을 Vision 76점 랜드마크에 TPS 로 휘고, 목·어깨·머리카락은 인물 실루엣 폭에 맞춥니다. 측면 사진으로 머리 옆면 색을 채웁니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let hints = package.manifest.appearance {
                        Label("외형 힌트: \(hints.summary)", systemImage: "sparkle.magnifyingglass")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button {
                            Task { await buildSplats() }
                        } label: {
                            if model.isSplatting, let p = model.splatProgress {
                                HStack { ProgressView(); Text(p.message) }
                            } else {
                                Label(model.splats == nil ? "입체(스플랫) 만들기" : "다시 만들기", systemImage: "sparkles")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSplatting)
                        if let url = model.plyURL {
                            ShareLink(item: url) { Label("3DGS PLY 내보내기", systemImage: "square.and.arrow.up") }
                        }
                    }
                    if let url = model.packageURL {
                        ShareLink(item: url) {
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
                            Button(sender.isSending ? "전송 중…" : (model.splats == nil ? "사진만 보내기" : "스플랫 포함 보내기")) {
                                var pkg = package
                                pkg.splats = model.splats?.encode()
                                pkg.manifest.hasSplats = model.splats != nil
                                pkg.manifest.splatCount = model.splats?.count ?? 0
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
                    Text(model.splats == nil
                         ? "사진만 보내면 Vision Pro 가 받은 다각도 사진으로 직접 스플랫을 만들어 초안으로 띄웁니다."
                         : "스플랫까지 보내면 Vision Pro 는 바로 입체 초안을 띄웁니다. 저장을 누르면 즉시 내 페르소나가 됩니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                HStack {
                    if let url = model.exportURL {
                        ShareLink(item: url) { Label("카드 PNG 공유 (AirDrop)", systemImage: "square.and.arrow.up") }
                    }
                    Button("다시 촬영") {
                        stopMouth()
                        model.clear()
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
                Toggle("", isOn: $model.mouthEnabled).labelsHidden()
                    .onChange(of: model.mouthEnabled) { _, on in
                        if on { Task { await startMouth() } } else { stopMouth() }
                    }
            }
            HStack(spacing: 10) {
                Image(systemName: model.mouthSource.systemImage)
                Text(model.mouthEnabled ? "입 신호: \(model.mouthSource.title)" : "켜면 이 기기에서 가능한 가장 좋은 입 신호를 고릅니다")
                    .font(.footnote)
                Spacer()
            }
            Text("우선순위: 얼굴 추적(TrueDepth) → 카메라 입술 랜드마크 → 마이크 음량. 미리보기 페르소나의 입이 따라 움직입니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("TrueDepth 는 ARKit 52 전체(깜빡임 포함), 카메라는 랜드마크 미니 세트(턱·깜빡임·미소·오므림·눈썹)로 키트를 직접 구동합니다. 셰이프키: \(FaceRigSystem.lastNamingDescription) · 스플랫 렌더: \(SplatMesh.nativeAvailable ? "RealityKit 27 네이티브(턱 변형)" : "쿼드 아틀라스")")
                .font(.caption2).foregroundStyle(.tertiary)
            if model.mouthEnabled {
                VoiceLevelBar(level: currentLevel, peak: mic.isRunning ? mic.peak : currentLevel)
                HStack(spacing: 12) {
                    Text("마이크: \(mic.permission)").font(.caption).foregroundStyle(.secondary)
                    if !mic.permissionGranted && model.mouthSource == .microphone {
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
        switch model.mouthSource {
        case .faceTracking: return face.level
        case .cameraLips: return camera.mouthOpen
        case .microphone: return mic.level
        case .none: return 0
        }
    }
    #else
    private func currentMouthLevel(mic: MicLevelMeter, camera: CameraCaptureController) -> Float {
        switch model.mouthSource {
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
            model.mouthSource = .faceTracking
            return
        }
        #endif
        if case .unavailable = camera.capability {
            await mic.start()
            model.mouthSource = mic.isRunning ? .microphone : .none
            return
        }
        camera.mouthTrackingMode = true
        if !camera.isRunning { await camera.start() }
        model.mouthSource = camera.isRunning ? .cameraLips : .microphone
        if model.mouthSource == .microphone { await mic.start() }
    }

    private func stopMouth() {
        #if os(iOS)
        faceTracker.stop()
        #endif
        camera.mouthTrackingMode = false
        if model.package != nil { camera.stop() }
        mic.stop()
        model.mouthSource = .none
    }

    // MARK: - Actions

    private func build() async {
        guard let input = camera.makeCaptureInput() else { return }
        model.isBuilding = true
        model.errorText = nil
        defer { model.isBuilding = false }
        let personaName = model.name.trimmingCharacters(in: .whitespaces).isEmpty ? "내 페르소나" : model.name
        do {
            let result = try await PersonaBuilder.build(capture: input, name: personaName) { p in
                Task { @MainActor in model.progress = p }
            }
            model.package = result
            model.packageImage = PersonaBuilder.decodeImage(result.bodyPNG)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("소반-\(personaName).png")
            try? result.bodyPNG.write(to: url, options: .atomic)
            model.exportURL = url
            model.packageURL = try? PersonaPackageFile.write(result)
            camera.stop()
            await buildSplats()
        } catch {
            model.errorText = error.localizedDescription
        }
        model.progress = nil
    }

    private func buildSplats() async {
        guard let package = model.package else { return }
        model.isSplatting = true
        defer { model.isSplatting = false }
        do {
            // Vision Pro 와 같은 파이프라인: 흉상 템플릿 TPS 변형 + 실루엣 폭 맞춤 + 외형 힌트 + 머리카락 볼륨
            let template = await BustTemplateLoader.load()
            var package = package
            if let img = model.packageImage {
                model.splatProgress = SplatBuilder.Progress(step: 0, total: 5, message: AppearanceAnalyzer.isModelAvailable ? "Apple Intelligence 로 외형 힌트 읽는 중" : "외형 힌트(휴리스틱) 읽는 중")
                package.manifest.appearance = await AppearanceAnalyzer.analyze(image: img, rig: package.manifest.face)
                model.package?.manifest.appearance = package.manifest.appearance
            }
            let cloud = try await SplatBuilder.build(from: package, template: template, hints: package.manifest.appearance) { p in
                Task { @MainActor in model.splatProgress = p }
            }
            model.splats = cloud
            model.show3D = true
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("소반-\(package.manifest.name).ply")
            try? cloud.plyData().write(to: url, options: .atomic)
            model.plyURL = url
            var full = package
            full.splats = cloud.encode()
            full.manifest.hasSplats = true
            full.manifest.splatCount = cloud.count
            model.packageURL = try? PersonaPackageFile.write(full)
        } catch {
            model.errorText = "스플랫 생성 실패: \(error.localizedDescription)"
        }
        model.splatProgress = nil
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
