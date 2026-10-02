#if os(visionOS)
import SwiftUI
import PhotosUI

/// 스튜디오 상태. 뷰 구조체가 아니라 클래스에 두어 미리보기 레벨 클로저가 항상 최신 값을 읽게 한다.
@Observable
final class StudioModel {
    var draft: PersonaPackage?
    var draftImage: CGImage?
    var draftSplats: SplatCloud?
    var draftName = ""
    var draftSource: String?
    var progress: PersonaBuilder.Progress?
    var splatProgress: SplatBuilder.Progress?
    var errorText: String?
    var infoText: String?
    var isBuilding = false
    var isSplatting = false
    var previewMic = false
    var fakeTalk = false
    var fakeLevel: Float = 0
    var show3D = true
    var showPicker = false
    var showCaptureSheet = false
    var showFileImporter = false
    var isImporting = false
    var importProgress: PersonaImporter.Progress?
    /// PLY 에서 불러온 초안: 원본 클라우드와 뒤집기 상태 (위아래가 뒤집혀 보일 때 재적용)
    var importedCloud: SplatCloud?
    var importedName = ""
    var importedFlipY = false
    var pickerItem: PhotosPickerItem?
    let receiver = PersonaReceiver()
    /// 저장된(활성) 페르소나의 스플랫 캐시
    var activeSplats: SplatCloud?
    var activeSplatsID: UUID?

    /// 미리보기 입 벌림 레벨: 시뮬레이션 > 마이크 > 0
    func currentLevel(voice: VoiceEngine) -> Float {
        if fakeTalk { return fakeLevel }
        if previewMic { return voice.level }
        return 0
    }

    func setDraft(_ package: PersonaPackage, source: String?) {
        draft = package
        draftImage = PersonaBuilder.decodeImage(package.bodyPNG)
        draftSplats = package.splats.flatMap { SplatCloud(data: $0) }
        draftName = package.manifest.name
        draftSource = source
        show3D = draftSplats != nil
        errorText = nil
        if source?.hasPrefix("PLY") != true { importedCloud = nil }
    }

    func clearDraft() {
        draft = nil
        draftImage = nil
        draftSplats = nil
        draftName = ""
        draftSource = nil
    }
}

/// 페르소나 스튜디오: 모습 수집 → 분석 → 입체화 → 다듬기 → 움직여 보기 → 저장.
struct StudioView: View {
    @Environment(AppModel.self) private var app
    @State private var model = StudioModel()

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .top, spacing: 24) {
            leftColumn
                .frame(width: 420)
            rightColumn
        }
        .padding(28)
        .photosPicker(isPresented: $model.showPicker, selection: $model.pickerItem, matching: .images)
        .fileImporter(isPresented: $model.showFileImporter, allowedContentTypes: [.sobanPersona, .ply, .data]) { result in
            if case .success(let url) = result { Task { await importFile(url) } }
        }
        .task(id: app.pendingImportURL) {
            guard let url = app.pendingImportURL else { return }
            app.pendingImportURL = nil
            await importFile(url)
        }
        .sheet(isPresented: $model.showCaptureSheet) {
            CaptureOptionsSheet(model: model, onReceive: receive)
        }
        .task(id: model.pickerItem) { await loadPickedPhoto() }
        .task(id: model.fakeTalk) {
            guard model.fakeTalk else { model.fakeLevel = 0; return }
            var t: Float = 0
            while !Task.isCancelled && model.fakeTalk {
                t += 0.033
                model.fakeLevel = max(0, sin(t * 11)) * (0.55 + 0.45 * sin(t * 2.3))
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        .task(id: model.previewMic) {
            if model.previewMic {
                await app.session.voice.startCapture()
            } else if !app.session.isImmersiveOpen {
                app.session.voice.stopCapture()
            }
        }
        .task(id: app.store.active?.id) { loadActiveSplats() }
        .onDisappear {
            model.receiver.stop()
        }
    }

    // MARK: Left: 단계

    private var leftColumn: some View {
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("페르소나 스튜디오").font(.largeTitle.bold())
                Text("처음부터 끝까지 기기 안에서 처리됩니다. 사진은 어디에도 올라가지 않아요.")
                    .foregroundStyle(.secondary)

                StepCard(number: 1, title: "모습 수집", done: model.draft != nil) {
                    Text("상반신이 보이는 정면 사진이 가장 좋아요. 배경은 알아서 지웁니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button { model.showPicker = true } label: {
                            Label("사진 보관함", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBuilding)
                        Button { useSample() } label: {
                            Label("샘플로 체험", systemImage: "face.smiling")
                        }
                        .disabled(model.isBuilding)
                    }
                    HStack {
                        Button { model.showCaptureSheet = true } label: {
                            Label("카메라로 촬영", systemImage: "camera.viewfinder")
                        }
                        Button {
                            if model.receiver.isListening { model.receiver.stop() } else { model.receiver.start(onReceive: receive) }
                        } label: {
                            Label(model.receiver.isListening ? "받기 중지" : "기기에서 받기",
                                  systemImage: model.receiver.isListening ? "antenna.radiowaves.left.and.right.slash" : "iphone.and.arrow.forward")
                        }
                    }
                    HStack {
                        Button { model.showFileImporter = true } label: {
                            Label("파일에서 불러오기 (.sobanpersona · .ply)", systemImage: "folder")
                        }
                        .disabled(model.isImporting)
                        if model.isImporting, let p = model.importProgress {
                            ProgressView().controlSize(.small)
                            Text(p.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("AirDrop 으로 받은 .sobanpersona / .ply 는 공유 시트에서 '소반' 을 고르면 바로 여기 초안으로 열립니다.")
                        .font(.caption).foregroundStyle(.tertiary)
                    if model.receiver.isListening {
                        Label(model.receiver.statusText, systemImage: "dot.radiowaves.left.and.right")
                            .font(.footnote).foregroundStyle(.green)
                        if let p = model.receiver.progressText { Text(p).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let progress = model.progress {
                        ProgressView(value: Double(progress.step), total: Double(progress.total)) {
                            Text(progress.message).font(.footnote)
                        }
                    }
                    if let info = model.infoText {
                        Label(info, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.green)
                    }
                    if let errorText = model.errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }

                StepCard(number: 2, title: "입체화 — 가우시안 스플랫", done: (model.draft != nil && model.draftSplats != nil) || (model.draft == nil && model.activeSplats != nil)) {
                    Text(splatExplanation)
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            Task { await buildSplats() }
                        } label: {
                            if model.isSplatting, let p = model.splatProgress {
                                HStack { ProgressView(); Text(p.message) }
                            } else {
                                Label(currentSplats == nil ? "입체(스플랫) 만들기" : "다시 만들기", systemImage: "sparkles")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSplatting || (model.draft == nil && app.store.active == nil))
                        Picker("", selection: $model.show3D) {
                            Text("카드").tag(false)
                            Text("입체").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                        .disabled(currentSplats == nil)
                    }
                    if let s = currentSplats {
                        Text("스플랫 \(s.count.formatted())개 · 고개를 돌리면 실제 시차가 생깁니다. 상에서는 입체로 보입니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.importedCloud != nil {
                        Toggle("위아래 뒤집기 (PLY 가 거꾸로 보일 때)", isOn: $model.importedFlipY)
                            .onChange(of: model.importedFlipY) { _, _ in Task { await reapplyImportedFlip() } }
                            .disabled(model.isImporting)
                    }
                }

                StepCard(number: 3, title: "다듬기", done: !model.draftName.isEmpty && model.draft != nil) {
                    HStack {
                        TextField("이름", text: $model.draftName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { applyName() }
                        Button("이름 적용") { applyName() }
                            .disabled(model.draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let d = model.draft {
                        HStack(spacing: 14) {
                            ColorSwatch(color: d.manifest.face?.skin ?? .skinDefault, label: "피부")
                            ColorSwatch(color: d.manifest.face?.lip ?? .lipDefault, label: "입술")
                            ColorSwatch(color: d.manifest.accent, label: "포인트")
                            Spacer()
                            Text(sourceLabel(d.manifest)).font(.caption).foregroundStyle(.secondary)
                        }
                        LabeledContent("입 벌림 강도") {
                            Slider(value: mouthStrengthBinding, in: 0.4...1.8).frame(width: 160)
                        }
                        LabeledContent("카드 높이") {
                            Slider(value: cardHeightBinding, in: 0.55...1.0).frame(width: 160)
                        }
                        Text(d.manifest.face == nil
                             ? "얼굴을 찾지 못해 눈 깜빡임과 입 모양은 꺼집니다. 고개 움직임만 전달돼요."
                             : "눈·입 리그를 찾았어요. 말하면 입이 벌어지고 가끔 눈을 깜빡입니다.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                StepCard(number: 4, title: "움직여 보기 — 입 모양", done: false) {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.badge.ellipsis")
                        Text("내부 카메라·LiDAR 입 추적: 사용 불가 (visionOS 는 서드파티 앱에 열어 주지 않습니다)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("마이크 음량으로 입 움직이기", isOn: $model.previewMic)
                    Toggle("말하기 시뮬레이션", isOn: $model.fakeTalk)
                    VoiceLevelBar(level: model.currentLevel(voice: app.session.voice),
                                  peak: model.previewMic ? app.session.voice.peak : model.currentLevel(voice: app.session.voice))
                    HStack(spacing: 12) {
                        Text(app.session.voice.permissionText).font(.caption).foregroundStyle(.secondary)
                        if !app.session.voice.isCapturing {
                            Button("마이크 허용 요청 · 다시 연결") {
                                Task {
                                    model.previewMic = true
                                    let ok = await app.session.voice.requestMicrophoneAccess()
                                    model.infoText = ok ? "마이크 수음을 시작했어요. 말하면 레벨미터와 입이 움직입니다." : nil
                                }
                            }
                            .font(.caption)
                        }
                        Spacer()
                        Text(model.previewMic ? (app.session.voice.isCapturing ? "수음 중" : "수음 대기") : (model.fakeTalk ? "시뮬레이션" : "꺼짐"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(app.session.voice.inputStatusText).font(.caption2).foregroundStyle(.tertiary)
                    if let err = app.session.voice.errorText {
                        Text(err).font(.footnote).foregroundStyle(.orange)
                    }
                    Text("iPhone·iPad 의 소반 캡처에서는 TrueDepth 얼굴 추적으로, Mac 에서는 카메라 입술 추적으로 입 모양을 확인할 수 있습니다.")
                        .font(.caption).foregroundStyle(.tertiary)
                }

                StepCard(number: 5, title: "저장", done: false) {
                    Button { save() } label: {
                        Label("내 페르소나로 저장 (바로 사용)", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.draft == nil || model.draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                    if model.draft != nil {
                        Text("저장하면 즉시 활성 페르소나가 되어 모임에서 바로 쓰입니다. 스플랫이 있으면 함께 저장됩니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                library
            }
        }
    }

    private var splatExplanation: String {
        let m = model.draft?.manifest ?? app.store.active
        if let m, m.hasDepth {
            return "깊이 맵으로 3D 점을 만들고 각 점을 색·불투명도·크기를 가진 가우시안 스플랫으로 초기화합니다. 측면 사진이 있으면 머리 옆면 색을 채웁니다."
        }
        return "깊이가 없으면 얼굴 리그에 맞춘 머리 타원체·몸통 부조로 3D 점을 만듭니다. 측면 사진이 있으면 머리 옆면 색을 채웁니다."
    }

    private var currentSplats: SplatCloud? {
        model.draft != nil ? model.draftSplats : model.activeSplats
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("저장된 페르소나").font(.headline)
            if app.store.personas.isEmpty {
                Text("아직 없음").foregroundStyle(.tertiary)
            }
            ForEach(app.store.personas) { p in
                HStack {
                    if let img = app.store.image(for: p.id) {
                        Image(decorative: img, scale: 1).resizable().scaledToFit().frame(width: 36, height: 44)
                    }
                    VStack(alignment: .leading) {
                        HStack(spacing: 6) {
                            Text(p.name)
                            if p.hasSplats { Image(systemName: "sparkles").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text("\(sourceLabel(p)) · \(p.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if app.store.active?.id == p.id {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("사용") {
                            app.store.activeID = p.id
                            app.session.refreshLocalPersona()
                        }
                    }
                    Button(role: .destructive) {
                        app.store.delete(p.id)
                        app.session.refreshLocalPersona()
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(.top, 8)
    }

    // MARK: Right: 미리보기

    private var previewVisible: Bool { !model.showPicker && !model.showCaptureSheet }

    private var rightColumn: some View {
        VStack(spacing: 14) {
            if let d = model.draft, let img = model.draftImage {
                PersonaPreviewView(manifest: d.manifest, image: img, splats: model.show3D ? model.draftSplats : nil,
                                   name: previewName(d.manifest.name),
                                   levelSource: { [model, voice = app.session.voice] in model.currentLevel(voice: voice) },
                                   demoMotion: true, turntable: model.show3D && model.draftSplats != nil && !model.previewMic && !model.fakeTalk,
                                   visible: previewVisible)
                    .frame(minHeight: 420)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
                HStack(spacing: 16) {
                    Label("초안" + (model.draftSource.map { " · \($0)" } ?? ""), systemImage: "doc.badge.ellipsis")
                    Label("\(d.manifest.imageWidth)×\(d.manifest.imageHeight)", systemImage: "photo")
                    Label(d.manifest.face == nil ? "얼굴 리그 없음" : "눈 2 · 입 1 · 코 1", systemImage: "face.dashed")
                    if d.manifest.hasDepth { Label("깊이", systemImage: "cube.transparent") }
                    if !d.sideViews.isEmpty { Label("측면 \(d.sideViews.count)", systemImage: "rectangle.stack") }
                    if let s = model.draftSplats { Label("스플랫 \(s.count.formatted())", systemImage: "sparkles") }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if let active = app.store.active, let img = app.store.image(for: active.id) {
                PersonaPreviewView(manifest: active, image: img, splats: model.show3D ? model.activeSplats : nil,
                                   name: previewName(active.name),
                                   levelSource: { [model, voice = app.session.voice] in model.currentLevel(voice: voice) },
                                   demoMotion: true, turntable: model.show3D && model.activeSplats != nil && !model.previewMic && !model.fakeTalk,
                                   visible: previewVisible)
                    .frame(minHeight: 420)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
                Text("현재 페르소나 '\(active.name)'\(active.hasSplats ? " · 스플랫 \(active.splatCount.formatted())개" : ""). 새 사진을 고르거나 기기에서 받으면 여기에 초안이 뜹니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("미리보기", systemImage: "person.crop.square.badge.camera",
                                       description: Text("사진을 고르거나 샘플로 체험해 보세요."))
                    .frame(minHeight: 420)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
            }
        }
    }

    private func previewName(_ saved: String) -> String {
        let typed = model.draftName.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? saved : typed
    }

    private func sourceLabel(_ m: PersonaManifest) -> String {
        switch m.captureSource {
        case .photoLibrary: "사진 보관함"
        case .depthCamera: "깊이 카메라" + (m.capturedOn.map { " · \($0)" } ?? "")
        case .camera: "카메라" + (m.capturedOn.map { " · \($0)" } ?? "")
        case .generated: "샘플"
        case .importedFile: "파일" + (m.capturedOn.map { " · \($0)" } ?? "")
        }
    }

    // MARK: Bindings

    private var mouthStrengthBinding: Binding<Float> {
        Binding(get: { model.draft?.manifest.mouthStrength ?? 1 }, set: { model.draft?.manifest.mouthStrength = $0 })
    }

    private var cardHeightBinding: Binding<Float> {
        Binding(get: { model.draft?.manifest.cardHeightMeters ?? 0.8 }, set: { model.draft?.manifest.cardHeightMeters = $0 })
    }

    // MARK: Actions

    private func loadActiveSplats() {
        guard let active = app.store.active else { model.activeSplats = nil; model.activeSplatsID = nil; return }
        guard model.activeSplatsID != active.id else { return }
        model.activeSplatsID = active.id
        model.activeSplats = app.store.splatData(for: active.id).flatMap { SplatCloud(data: $0) }
    }

    private func applyName() {
        let name = model.draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if model.draft != nil {
            model.draft?.manifest.name = name
            model.infoText = "초안 이름을 '\(name)' 으로 바꿨어요. 저장하면 확정됩니다."
        } else if var active = app.store.active {
            active.name = name
            do {
                try app.store.update(active)
                app.session.refreshLocalPersona()
                model.infoText = "현재 페르소나 이름을 '\(name)' 으로 바꿨어요."
            } catch {
                model.errorText = "이름 저장 실패: \(error.localizedDescription)"
            }
        }
    }

    private func loadPickedPhoto() async {
        guard let item = model.pickerItem else { return }
        model.isBuilding = true
        model.errorText = nil
        model.infoText = nil
        defer { model.isBuilding = false; model.pickerItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                model.errorText = "사진을 불러오지 못했습니다."
                return
            }
            let name = model.draftName.isEmpty ? (app.session.displayName == "나" ? "내 페르소나" : app.session.displayName) : model.draftName
            let package = try await PersonaBuilder.build(from: data, name: name) { p in
                Task { @MainActor in model.progress = p }
            }
            model.setDraft(package, source: "사진 보관함")
            model.progress = nil
        } catch {
            model.errorText = error.localizedDescription
            model.progress = nil
        }
    }

    private func useSample() {
        let styles = PlaceholderPersona.palette
        let style = styles[Int.random(in: 0..<styles.count)]
        let package = PlaceholderPersona.make(name: model.draftName.isEmpty ? "샘플" : model.draftName, style: style)
        model.setDraft(package, source: "샘플")
        model.infoText = nil
    }

    /// 파일(.sobanpersona / .ply) → 초안. PLY 는 스플랫에서 카드와 얼굴 리그를 다시 만든다.
    private func importFile(_ url: URL) async {
        model.isImporting = true
        model.errorText = nil
        model.infoText = nil
        defer { model.isImporting = false; model.importProgress = nil }
        do {
            let package = try await PersonaImporter.importFile(at: url, flipY: false) { p in
                Task { @MainActor in model.importProgress = p }
            }
            let isPLY = url.pathExtension.lowercased() == "ply"
            model.setDraft(package, source: isPLY ? "PLY · \(url.lastPathComponent)" : "파일 · \(url.lastPathComponent)")
            if isPLY, let data = package.splats, let cloud = SplatCloud(data: data) {
                model.importedCloud = cloud
                model.importedName = package.manifest.name
                model.importedFlipY = false
            } else {
                model.importedCloud = nil
            }
            model.infoText = "'\(package.manifest.name)' 을 파일에서 불러왔어요"
                + (package.manifest.face == nil && isPLY ? " (얼굴 리그를 찾지 못해 입·눈은 움직이지 않습니다)" : "")
                + ". 확인 후 '내 페르소나로 저장' 을 누르면 바로 쓰입니다."
            if model.draftSplats == nil { await buildSplats() }
        } catch {
            model.errorText = error.localizedDescription
        }
    }

    private func reapplyImportedFlip() async {
        guard let cloud = model.importedCloud else { return }
        model.isImporting = true
        defer { model.isImporting = false; model.importProgress = nil }
        do {
            let package = try await PersonaImporter.package(from: cloud, name: model.importedName, flipY: model.importedFlipY) { p in
                Task { @MainActor in model.importProgress = p }
            }
            let source = model.draftSource
            model.setDraft(package, source: source)
        } catch {
            model.errorText = error.localizedDescription
        }
    }

    /// 캡처 기기에서 받은 패키지 → 초안. 스플랫이 없으면 받은 다각도 사진으로 여기서 만든다.
    private func receive(_ package: PersonaPackage, from sender: String) {
        model.setDraft(package, source: sender)
        model.infoText = "'\(package.manifest.name)' 을 \(sender) 에서 받았어요. 확인 후 '내 페르소나로 저장' 을 누르면 바로 쓰입니다."
        if model.draftSplats == nil {
            Task { await buildSplats() }
        }
    }

    private func buildSplats() async {
        model.isSplatting = true
        model.errorText = nil
        defer { model.isSplatting = false; model.splatProgress = nil }
        do {
            if let draft = model.draft {
                let cloud = try await SplatBuilder.build(from: draft) { p in Task { @MainActor in model.splatProgress = p } }
                model.draftSplats = cloud
                model.draft?.splats = cloud.encode()
                model.draft?.manifest.hasSplats = true
                model.draft?.manifest.splatCount = cloud.count
                model.show3D = true
            } else if let active = app.store.active, let pkg = app.store.package(for: active.id) {
                let cloud = try await SplatBuilder.build(from: pkg) { p in Task { @MainActor in model.splatProgress = p } }
                try app.store.saveSplats(cloud.encode(), count: cloud.count, for: active.id)
                model.activeSplats = cloud
                model.activeSplatsID = active.id
                model.show3D = true
                app.session.refreshLocalPersona()
            }
        } catch {
            model.errorText = "스플랫 생성 실패: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard var package = model.draft else { return }
        package.manifest.name = model.draftName.trimmingCharacters(in: .whitespaces)
        if let cloud = model.draftSplats {
            package.splats = cloud.encode()
            package.manifest.hasSplats = true
            package.manifest.splatCount = cloud.count
        }
        do {
            try app.store.save(package)          // 저장 즉시 활성 페르소나
            app.session.refreshLocalPersona()   // 모임에 바로 반영
            model.activeSplats = model.draftSplats
            model.activeSplatsID = package.manifest.id
            model.clearDraft()
            model.infoText = "'\(package.manifest.name)' 을 저장했고 지금부터 모임에서 쓰입니다."
        } catch {
            model.errorText = "저장 실패: \(error.localizedDescription)"
        }
    }
}

// MARK: - Capture options sheet

/// "카메라로 촬영" 을 눌렀을 때. Vision Pro 는 서드파티 카메라 접근이 없으므로 그 사실과 대안(캡처 기기)을 안내한다.
struct CaptureOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: StudioModel
    let onReceive: (PersonaPackage, String) -> Void
    private let capability = CaptureAvailability.detect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: capability.systemImage).font(.largeTitle)
                VStack(alignment: .leading) {
                    Text("이 기기에서 촬영").font(.title2.bold())
                    Text(capability.title).foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기") { dismiss() }
            }
            Text(capability.detail)
                .font(.callout)
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

            Text("대신 이렇게 하세요").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                Label("iPhone · iPad(TrueDepth/LiDAR 깊이 카메라) 또는 Mac(일반 카메라)에 같은 '소반' 앱을 설치합니다.", systemImage: "1.circle")
                Label("그 기기에서 앱을 열면 '소반 캡처' 가 바로 뜹니다. 정면 → 한쪽 → 반대쪽 → 위 순서로 안내에 따라 고개를 돌리면 자동 촬영됩니다.", systemImage: "2.circle")
                Label("'페르소나 만들기' → 가우시안 스플랫이 만들어집니다. 아래 '기기에서 받기' 를 켠 이 Vision Pro 를 골라 보냅니다(스플랫 포함 또는 사진만).", systemImage: "3.circle")
                Label("받은 결과는 초안으로 뜹니다. 사진만 받았다면 이 Vision Pro 가 스플랫을 만듭니다. '내 페르소나로 저장' 을 누르면 바로 쓰입니다.", systemImage: "4.circle")
            }
            .font(.callout)

            HStack {
                Button {
                    if model.receiver.isListening { model.receiver.stop() } else { model.receiver.start(onReceive: onReceive) }
                } label: {
                    Label(model.receiver.isListening ? "받기 중지" : "기기에서 받기 켜기",
                          systemImage: model.receiver.isListening ? "antenna.radiowaves.left.and.right.slash" : "iphone.and.arrow.forward")
                }
                .buttonStyle(.borderedProminent)
                Text(model.receiver.statusText).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(28)
        .frame(minWidth: 680, minHeight: 500)
    }
}

// MARK: - Small components

struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(done ? Color.green : Color.white.opacity(0.15)).frame(width: 28, height: 28)
                    Text("\(number)").font(.footnote.bold())
                }
                Text(title).font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct ColorSwatch: View {
    let color: RGB
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(Color(red: color.r, green: color.g, blue: color.b))
                .frame(width: 28, height: 28)
                .overlay(Circle().stroke(.white.opacity(0.4)))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Float(i) / 8 < level ? Color.green : Color.white.opacity(0.2))
                    .frame(width: 4, height: 6 + CGFloat(i) * 1.5)
            }
        }
        .accessibilityLabel("목소리 크기")
    }
}
#endif
