import Foundation
import Observation

/// 전송 리소스 이름 규칙. 패키지 하나가 여러 파일로 나뉘어 간다.
nonisolated enum TransferResource {
    static func body(_ id: UUID) -> String { "persona-\(id.uuidString).png" }
    static func depth(_ id: UUID) -> String { "depth-\(id.uuidString).png" }
    static func side(_ id: UUID, _ key: String) -> String { "side-\(id.uuidString)-\(key).png" }
    static func splats(_ id: UUID) -> String { "splats-\(id.uuidString).bin" }

    /// 이름 → (종류, 페르소나 id, 측면 키)
    static func parse(_ name: String) -> (kind: String, id: UUID, key: String?)? {
        let stem = (name as NSString).deletingPathExtension
        let parts = stem.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let kind = parts[0]
        // uuid 는 36자
        let rest = parts[1]
        guard rest.count >= 36, let id = UUID(uuidString: String(rest.prefix(36))) else { return nil }
        var key: String?
        if rest.count > 37 { key = String(rest.dropFirst(37)) }
        return (kind, id, key)
    }

    /// 패키지의 모든 리소스를 임시 파일로 써서 (이름, URL) 목록을 돌려준다.
    static func stage(_ package: PersonaPackage) throws -> [(name: String, url: URL)] {
        let id = package.manifest.id
        let tmp = FileManager.default.temporaryDirectory
        var out: [(String, URL)] = []
        func write(_ data: Data, _ name: String) throws {
            let url = tmp.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            out.append((name, url))
        }
        try write(package.bodyPNG, body(id))
        if let d = package.depthPNG { try write(d, depth(id)) }
        for (key, d) in package.sideViews { try write(d, side(id, key)) }
        if let s = package.splats { try write(s, splats(id)) }
        return out
    }
}

/// 수신 중인 패키지 조립.
nonisolated struct IncomingPackage: Sendable {
    var manifest: PersonaManifest?
    var body: Data?
    var depth: Data?
    var sides: [String: Data] = [:]
    var splats: Data?
    var expected: [String]?
    var received: Set<String> = []
    var senderName = ""

    var isComplete: Bool {
        guard manifest != nil, body != nil else { return false }
        if let expected { return Set(expected).isSubset(of: received) }
        return false
    }

    func package() -> PersonaPackage? {
        guard let manifest, let body else { return nil }
        return PersonaPackage(manifest: manifest, bodyPNG: body, depthPNG: depth, sideViews: sides, splats: splats)
    }
}

/// Vision Pro 쪽: "기기에서 받기" 를 누르면 `soban-capture` 서비스를 알리고, 캡처 기기가 보낸 패키지를 조립해 넘긴다.
/// 받은 패키지는 **초안**으로 넘어가고(스튜디오), 사용자가 '내 페르소나로 저장' 을 누르면 바로 활성화된다.
@Observable
final class PersonaReceiver {
    private(set) var isListening = false
    private(set) var statusText = "대기"
    private(set) var connectedSender: String?
    private(set) var lastReceived: PersonaManifest?
    private(set) var progressText: String?
    private var transport: MultipeerTransport?
    private var incoming: [UUID: IncomingPackage] = [:]
    private var onReceive: ((PersonaPackage, String) -> Void)?

    var deviceName: String { CaptureAvailability.deviceName }

    func start(onReceive: @escaping (PersonaPackage, String) -> Void) {
        guard !isListening else { return }
        self.onReceive = onReceive
        let t = MultipeerTransport(displayName: deviceName, serviceType: MultipeerTransport.captureService)
        t.onEvent = { [weak self] event in self?.handle(event) }
        t.startHosting(roomName: "capture", hostName: deviceName)
        transport = t
        isListening = true
        statusText = "'\(deviceName)' 으로 받을 준비가 되었습니다. 캡처 기기에서 이 이름을 선택하세요."
    }

    func stop() {
        transport?.disconnect()
        transport?.onEvent = nil
        transport = nil
        isListening = false
        connectedSender = nil
        progressText = nil
        statusText = "대기"
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .connected(let peer):
            connectedSender = peer.displayName
            statusText = "\(peer.displayName) 연결됨 · 페르소나를 기다리는 중"
        case .disconnected(let peer):
            if connectedSender == peer.displayName { connectedSender = nil }
            if isListening { statusText = "'\(deviceName)' 으로 받을 준비가 되었습니다." }
        case .message(let message, let peer):
            switch message {
            case .personaTransfer(let manifest, let sender):
                var pkg = incoming[manifest.id] ?? IncomingPackage()
                pkg.manifest = manifest
                pkg.senderName = sender
                incoming[manifest.id] = pkg
                statusText = "\(sender) 에서 '\(manifest.name)' 수신 중…"
                tryComplete(manifest.id, replyTo: peer)
            case .personaTransferComplete(let id, let resources):
                var pkg = incoming[id] ?? IncomingPackage()
                pkg.expected = resources
                incoming[id] = pkg
                tryComplete(id, replyTo: peer)
            default:
                break
            }
        case .resource(let url, let name, let peer):
            guard let parsed = TransferResource.parse(name), let data = try? Data(contentsOf: url) else { return }
            try? FileManager.default.removeItem(at: url)
            var pkg = incoming[parsed.id] ?? IncomingPackage()
            switch parsed.kind {
            case "persona": pkg.body = data
            case "depth": pkg.depth = data
            case "side": if let key = parsed.key { pkg.sides[key] = data }
            case "splats": pkg.splats = data
            default: break
            }
            pkg.received.insert(name)
            incoming[parsed.id] = pkg
            progressText = "받은 파일 \(pkg.received.count)\(pkg.expected.map { " / \($0.count)" } ?? "")"
            tryComplete(parsed.id, replyTo: peer)
        case .error(let text):
            statusText = text
        default:
            break
        }
    }

    private func tryComplete(_ id: UUID, replyTo peer: PeerHandle) {
        guard let pkg = incoming[id], pkg.isComplete, let package = pkg.package() else { return }
        incoming[id] = nil
        onReceive?(package, pkg.senderName)
        lastReceived = package.manifest
        progressText = nil
        statusText = "'\(package.manifest.name)' 을 받았습니다. 초안을 확인하고 저장하세요."
        transport?.send(.personaReceived(id), to: [peer], reliable: true)
    }
}

#if os(iOS) || os(macOS)
/// 캡처 기기 쪽: 근처 Vision Pro(수신 대기 중)를 찾아 페르소나 패키지(카드·깊이·측면·스플랫)를 보낸다.
@Observable
final class PersonaSender {
    struct Receiver: Identifiable, Hashable {
        var id: String { peer.id }
        let peer: PeerHandle
        let name: String
    }

    private(set) var receivers: [Receiver] = []
    private(set) var isBrowsing = false
    private(set) var statusText = "대기"
    private(set) var isSending = false
    private(set) var didSend = false
    private var transport: MultipeerTransport?
    private var pendingPackage: PersonaPackage?
    private var target: PeerHandle?

    func startBrowsing() {
        guard !isBrowsing else { return }
        let t = MultipeerTransport(displayName: CaptureAvailability.deviceName, serviceType: MultipeerTransport.captureService)
        t.onEvent = { [weak self] event in self?.handle(event) }
        t.startBrowsing()
        transport = t
        isBrowsing = true
        statusText = "받을 준비가 된 Vision Pro 를 찾는 중… (Vision Pro 의 소반 앱 → 페르소나 → 기기에서 받기)"
    }

    func stop() {
        transport?.disconnect()
        transport?.onEvent = nil
        transport = nil
        isBrowsing = false
        receivers = []
        isSending = false
        statusText = "대기"
    }

    func send(_ package: PersonaPackage, to receiver: Receiver) {
        guard let transport else { return }
        pendingPackage = package
        target = receiver.peer
        isSending = true
        didSend = false
        statusText = "\(receiver.name) 에 연결하는 중…"
        transport.invite(receiver.peer)
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .foundRoom(let peer, let info):
            let name = info["host"] ?? peer.displayName
            if !receivers.contains(where: { $0.id == peer.id }) {
                receivers.append(Receiver(peer: peer, name: name))
            }
            statusText = "Vision Pro \(receivers.count)대 발견"
        case .lostRoom(let peer):
            receivers.removeAll { $0.peer == peer }
        case .connected(let peer):
            guard let package = pendingPackage, peer == target, let transport else { return }
            do {
                let staged = try TransferResource.stage(package)
                transport.send(.personaTransfer(package.manifest, senderName: CaptureAvailability.deviceName), to: [peer], reliable: true)
                for (name, url) in staged { transport.sendResource(at: url, name: name, to: peer) }
                transport.send(.personaTransferComplete(package.manifest.id, resources: staged.map(\.name)), to: [peer], reliable: true)
                let total = staged.reduce(0) { $0 + ((try? Data(contentsOf: $1.url).count) ?? 0) }
                statusText = "'\(package.manifest.name)' 전송 중… 파일 \(staged.count)개, \(total / 1024) KB"
            } catch {
                statusText = "전송 준비 실패: \(error.localizedDescription)"
                isSending = false
            }
        case .message(let message, _):
            if case .personaReceived = message {
                isSending = false
                didSend = true
                statusText = "Vision Pro 가 받았습니다. 소반 스튜디오에 초안으로 떠 있으니 '내 페르소나로 저장' 을 누르세요."
                transport?.disconnect()
            }
        case .disconnected:
            if isSending {
                isSending = false
                statusText = "연결이 끊어졌습니다. 다시 시도해 주세요."
            }
        case .error(let text):
            statusText = text
        default:
            break
        }
    }
}
#endif
