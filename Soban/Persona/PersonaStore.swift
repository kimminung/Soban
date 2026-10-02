import Foundation
import CoreGraphics
import Observation

/// `Documents/Personas/<id>/{manifest.json, body.png}` 에 페르소나를 저장/로드한다.
@Observable
final class PersonaStore {
    private(set) var personas: [PersonaManifest] = []
    var activeID: UUID? {
        didSet { UserDefaults.standard.set(activeID?.uuidString, forKey: "soban.activePersona") }
    }

    private var imageCache: [UUID: CGImage] = [:]
    private var pngCache: [UUID: Data] = [:]
    private var splatCache: [UUID: Data] = [:]

    var active: PersonaManifest? {
        guard let activeID else { return personas.first }
        return personas.first { $0.id == activeID } ?? personas.first
    }

    nonisolated static var rootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Personas", isDirectory: true)
    }

    init() {
        if let s = UserDefaults.standard.string(forKey: "soban.activePersona") { activeID = UUID(uuidString: s) }
        load()
    }

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.rootURL, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: Self.rootURL, includingPropertiesForKeys: nil)) ?? []
        var found: [PersonaManifest] = []
        for dir in dirs {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(PersonaManifest.self, from: data) {
                found.append(manifest)
            }
        }
        personas = found.sorted { $0.createdAt > $1.createdAt }
        if activeID == nil { activeID = personas.first?.id }
    }

    @discardableResult
    func save(_ package: PersonaPackage) throws -> PersonaManifest {
        let dir = Self.rootURL.appendingPathComponent(package.manifest.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try package.bodyPNG.write(to: dir.appendingPathComponent("body.png"), options: .atomic)
        if let depth = package.depthPNG {
            try depth.write(to: dir.appendingPathComponent("depth.png"), options: .atomic)
        }
        for (key, data) in package.sideViews {
            try data.write(to: dir.appendingPathComponent("side-\(key).png"), options: .atomic)
        }
        if let splats = package.splats {
            try splats.write(to: dir.appendingPathComponent("splats.bin"), options: .atomic)
            splatCache[package.manifest.id] = splats
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(package.manifest).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        pngCache[package.manifest.id] = package.bodyPNG
        imageCache[package.manifest.id] = nil
        personas.removeAll { $0.id == package.manifest.id }
        personas.insert(package.manifest, at: 0)
        activeID = package.manifest.id
        return package.manifest
    }

    func update(_ manifest: PersonaManifest) throws {
        let dir = Self.rootURL.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        if let i = personas.firstIndex(where: { $0.id == manifest.id }) { personas[i] = manifest }
    }

    func delete(_ id: UUID) {
        let dir = Self.rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        personas.removeAll { $0.id == id }
        imageCache[id] = nil
        pngCache[id] = nil
        splatCache[id] = nil
        if activeID == id { activeID = personas.first?.id }
    }

    func pngData(for id: UUID) -> Data? {
        if let d = pngCache[id] { return d }
        let url = Self.rootURL.appendingPathComponent(id.uuidString).appendingPathComponent("body.png")
        let d = try? Data(contentsOf: url)
        pngCache[id] = d
        return d
    }

    func image(for id: UUID) -> CGImage? {
        if let img = imageCache[id] { return img }
        guard let data = pngData(for: id), let img = PersonaBuilder.decodeImage(data) else { return nil }
        imageCache[id] = img
        return img
    }

    func package(for id: UUID) -> PersonaPackage? {
        guard let manifest = personas.first(where: { $0.id == id }), let png = pngData(for: id) else { return nil }
        return PersonaPackage(manifest: manifest, bodyPNG: png, depthPNG: depthData(for: id),
                              sideViews: sideViews(for: id), splats: splatData(for: id))
    }

    private func dir(_ id: UUID) -> URL { Self.rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }

    func depthData(for id: UUID) -> Data? {
        try? Data(contentsOf: dir(id).appendingPathComponent("depth.png"))
    }

    func sideViews(for id: UUID) -> [String: Data] {
        var out: [String: Data] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir(id), includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix("side-") && f.pathExtension == "png" {
            let key = f.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "side-", with: "")
            if let d = try? Data(contentsOf: f) { out[key] = d }
        }
        return out
    }

    func splatData(for id: UUID) -> Data? {
        if let d = splatCache[id] { return d }
        let d = try? Data(contentsOf: dir(id).appendingPathComponent("splats.bin"))
        if let d { splatCache[id] = d }
        return d
    }

    /// 스플랫 클라우드를 저장하고 매니페스트를 갱신한다.
    func saveSplats(_ data: Data, count: Int, for id: UUID) throws {
        try data.write(to: dir(id).appendingPathComponent("splats.bin"), options: .atomic)
        splatCache[id] = data
        if var m = personas.first(where: { $0.id == id }) {
            m.hasSplats = true
            m.splatCount = count
            try update(m)
        }
    }
}
