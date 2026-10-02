import Foundation
import UniformTypeIdentifiers

/// `.sobanpersona` — 페르소나 패키지 한 묶음(manifest·카드·깊이·측면·스플랫)을 단일 파일로.
/// AirDrop 으로 Vision Pro 에 보내면 소반 앱이 열려 바로 초안이 된다. 바이너리 plist 컨테이너라 외부 라이브러리가 필요 없다.
nonisolated enum PersonaPackageFile {
    static let fileExtension = "sobanpersona"
    static let typeIdentifier = "com.coulson.soban.persona"

    nonisolated enum FileError: LocalizedError {
        case malformed
        var errorDescription: String? { "소반 페르소나 파일 형식이 아닙니다." }
    }

    static func encode(_ package: PersonaPackage) throws -> Data {
        var dict: [String: Any] = [:]
        dict["format"] = "sobanpersona"
        dict["version"] = 1
        dict["manifest"] = try JSONEncoder().encode(package.manifest)
        dict["body"] = package.bodyPNG
        if let d = package.depthPNG { dict["depth"] = d }
        if !package.sideViews.isEmpty { dict["sides"] = package.sideViews }
        if let s = package.splats { dict["splats"] = s }
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    static func decode(_ data: Data) throws -> PersonaPackage {
        guard let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              dict["format"] as? String == "sobanpersona",
              let manifestData = dict["manifest"] as? Data,
              let body = dict["body"] as? Data else { throw FileError.malformed }
        var manifest = try JSONDecoder().decode(PersonaManifest.self, from: manifestData)
        let depth = dict["depth"] as? Data
        let sides = dict["sides"] as? [String: Data] ?? [:]
        let splats = dict["splats"] as? Data
        manifest.hasSplats = splats != nil
        return PersonaPackage(manifest: manifest, bodyPNG: body, depthPNG: depth, sideViews: sides, splats: splats)
    }

    /// 파일로 써서 URL 을 돌려준다 (ShareLink / fileExporter 용).
    static func write(_ package: PersonaPackage, to directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let safeName = package.manifest.name.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("소반-\(safeName).\(fileExtension)")
        try encode(package).write(to: url, options: .atomic)
        return url
    }
}

extension UTType {
    /// 소반 페르소나 패키지. Info.plist 의 UTExportedTypeDeclarations 와 일치해야 한다.
    static var sobanPersona: UTType {
        UTType(exportedAs: PersonaPackageFile.typeIdentifier)
    }

    /// PLY (Polygon File Format). 시스템 선언 UTI 가 있으면 그것을, 없으면 확장자로.
    static var ply: UTType {
        UTType("public.polygon-file-format") ?? UTType(filenameExtension: "ply") ?? .data
    }
}
