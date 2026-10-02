#if os(iOS) || os(macOS)
import Foundation
import CoreGraphics
import Observation
import Combine

/// 소반 캡처(iPhone/iPad/Mac)의 데이터 상태. 7차: 뷰가 아니라 **앱이 소유**해 창/씬을 오가도 유지되고,
/// Combine 디바운스 파이프라인으로 디스크에 저장해 재실행해도 마지막 페르소나·설정이 복원된다.
/// (카메라·마이크·전송 컨트롤러 같은 하드웨어 세션은 뷰에 남긴다.)
@Observable
final class CompanionModel {
    var name = "" { didSet { settingChanges.send() } }
    var package: PersonaPackage? { didSet { packageChanges.send() } }
    var packageImage: CGImage?
    var splats: SplatCloud?
    var progress: PersonaBuilder.Progress?
    var splatProgress: SplatBuilder.Progress?
    var errorText: String?
    var isBuilding = false
    var isSplatting = false
    var exportURL: URL?
    var plyURL: URL?
    var packageURL: URL?
    var show3D = true { didSet { settingChanges.send() } }
    var faceKit = "Male" { didSet { settingChanges.send() } }
    var mouthEnabled = false { didSet { settingChanges.send() } }
    var mouthSource: MouthSourceKind = .none
    var infoText: String?

    @ObservationIgnored private let settingChanges = PassthroughSubject<Void, Never>()
    @ObservationIgnored private let packageChanges = PassthroughSubject<Void, Never>()
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var restoring = false

    nonisolated struct Settings: Codable {
        var name = ""
        var show3D = true
        var faceKit = "Male"
        var mouthEnabled = false
    }

    private static let settingsKey = "soban.companion.settings"
    nonisolated static var packageURLOnDisk: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CompanionPersona.sobanpersona")
    }

    init() {
        restore()
        settingChanges
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.persistSettings() }
            .store(in: &cancellables)
        packageChanges
            .debounce(for: .milliseconds(1500), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.persistPackage() }
            .store(in: &cancellables)
    }

    /// 완성된 패키지(+스플랫)를 상태에 넣고 공유용 임시 파일을 만든다.
    func apply(package: PersonaPackage, splats: SplatCloud?) {
        self.package = package
        packageImage = PersonaBuilder.decodeImage(package.bodyPNG)
        self.splats = splats
        faceKit = package.manifest.faceKit ?? "Male"
        refreshShareFiles()
    }

    func refreshShareFiles() {
        guard let package else { exportURL = nil; plyURL = nil; packageURL = nil; return }
        let tmp = FileManager.default.temporaryDirectory
        let png = tmp.appendingPathComponent("소반-\(package.manifest.name).png")
        if (try? package.bodyPNG.write(to: png, options: .atomic)) != nil { exportURL = png }
        var full = package
        if let splats {
            let ply = tmp.appendingPathComponent("소반-\(package.manifest.name).ply")
            if (try? splats.plyData().write(to: ply, options: .atomic)) != nil { plyURL = ply }
            full.splats = splats.encode()
            full.manifest.hasSplats = true
            full.manifest.splatCount = splats.count
        }
        packageURL = try? PersonaPackageFile.write(full)
    }

    func clear() {
        package = nil
        packageImage = nil
        splats = nil
        exportURL = nil
        plyURL = nil
        packageURL = nil
        infoText = nil
    }

    private func persistSettings() {
        guard !restoring else { return }
        let s = Settings(name: name, show3D: show3D, faceKit: faceKit, mouthEnabled: mouthEnabled)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
    }

    private func persistPackage() {
        guard !restoring else { return }
        let url = Self.packageURLOnDisk
        guard var package else { try? FileManager.default.removeItem(at: url); return }
        if let splats {
            package.splats = splats.encode()
            package.manifest.hasSplats = true
            package.manifest.splatCount = splats.count
        }
        let snapshot = package
        Task.detached(priority: .utility) {
            if let data = try? PersonaPackageFile.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func restore() {
        restoring = true
        defer { restoring = false }
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey), let s = try? JSONDecoder().decode(Settings.self, from: data) {
            name = s.name; show3D = s.show3D; faceKit = s.faceKit; mouthEnabled = false   // 마이크/카메라는 자동 시작하지 않는다
            _ = s.mouthEnabled
        }
        if let data = try? Data(contentsOf: Self.packageURLOnDisk), let pkg = try? PersonaPackageFile.decode(data) {
            apply(package: pkg, splats: pkg.splats.flatMap { SplatCloud(data: $0) })
            infoText = "이전 페르소나 '\(pkg.manifest.name)' 을 복원했어요."
        }
    }
}
#endif
