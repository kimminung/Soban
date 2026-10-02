import Foundation
import MultipeerConnectivity
import os

/// 전송 계층이 세션에 노출하는 피어 식별자. 구체 프레임워크 타입(MCPeerID 등)은 전송 계층 안에만 머문다.
nonisolated struct PeerHandle: Hashable, Sendable, Identifiable {
    let id: String
    let displayName: String
}

/// 전송 계층 이벤트.
nonisolated enum TransportEvent: Sendable {
    case connected(PeerHandle)
    case disconnected(PeerHandle)
    case message(SessionMessage, PeerHandle)
    case resource(URL, name: String, PeerHandle)
    case foundRoom(PeerHandle, info: [String: String])
    case lostRoom(PeerHandle)
    case error(String)
}

/// 세션이 기대하는 전송 계층 인터페이스. v1 은 MultipeerConnectivity, v2 는 Network.framework(TN3213) 로 교체 예정.
protocol SessionTransport: AnyObject {
    var onEvent: (@MainActor (TransportEvent) -> Void)? { get set }
    var connectedPeers: [PeerHandle] { get }
    func startHosting(roomName: String, hostName: String)
    func stopHosting()
    func startBrowsing()
    func stopBrowsing()
    func invite(_ peer: PeerHandle)
    func disconnect()
    func send(_ message: SessionMessage, to peers: [PeerHandle]?, reliable: Bool)
    func sendResource(at url: URL, name: String, to peer: PeerHandle)
}

/// MultipeerConnectivity 위의 얇은 전송 계층. 델리게이트 콜백은 임의 스레드에서 오므로 모두 메인 액터로 넘긴다.
///
/// - 개인(무료) 개발자 팀은 Group Activities(SharePlay) 자격을 받을 수 없어 로컬 네트워크 피어투피어를 기본 전송으로 쓴다.
/// - MCSession 은 풀 메시이므로 호스트가 초대만 수락하면 모든 참가자가 서로 직접 연결된다.
/// - visionOS 27 에서 MultipeerConnectivity 는 deprecated(동작은 함). 이 파일 밖으로 MC 타입이 새지 않게 유지한다.
nonisolated final class MultipeerTransport: NSObject, SessionTransport, @unchecked Sendable {
    nonisolated static let tableService = "soban-table"
    nonisolated static let captureService = "soban-capture"

    let serviceType: String
    private let peerID: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private let lock = OSAllocatedUnfairLock()
    private var _onEvent: (@MainActor (TransportEvent) -> Void)?
    private var knownPeers: [String: MCPeerID] = [:]
    private let log = Logger(subsystem: "com.coulson.Soban", category: "transport")

    var onEvent: (@MainActor (TransportEvent) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    init(displayName: String, serviceType: String = MultipeerTransport.tableService) {
        self.serviceType = serviceType
        peerID = MCPeerID(displayName: String(displayName.prefix(60)))
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    var connectedPeers: [PeerHandle] { session.connectedPeers.map(handle) }

    // MARK: - Host / Guest

    func startHosting(roomName: String, hostName: String) {
        stopHosting()
        let adv = MCNearbyServiceAdvertiser(peer: peerID,
                                            discoveryInfo: ["room": String(roomName.prefix(40)), "host": String(hostName.prefix(30))],
                                            serviceType: serviceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv
    }

    func stopHosting() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
    }

    func startBrowsing() {
        stopBrowsing()
        let b = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
    }

    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
    }

    func invite(_ peer: PeerHandle) {
        guard let mc = mcPeer(peer) else { return }
        browser?.invitePeer(mc, to: session, withContext: nil, timeout: 20)
    }

    func disconnect() {
        stopHosting()
        stopBrowsing()
        session.disconnect()
    }

    // MARK: - Sending

    func send(_ message: SessionMessage, to peers: [PeerHandle]?, reliable: Bool) {
        let targets = peers?.compactMap(mcPeer) ?? session.connectedPeers
        guard !targets.isEmpty else { return }
        do {
            let data = try SessionMessage.encode(message)
            try session.send(data, toPeers: targets, with: reliable ? .reliable : .unreliable)
        } catch {
            log.debug("send failed: \(error.localizedDescription)")
        }
    }

    func sendResource(at url: URL, name: String, to peer: PeerHandle) {
        guard let mc = mcPeer(peer) else { return }
        session.sendResource(at: url, withName: name, toPeer: mc) { [log] error in
            if let error { log.error("resource send failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Internals

    private func handle(_ peer: MCPeerID) -> PeerHandle {
        let id = peer.displayName + "#" + String(UInt(bitPattern: peer.hash))
        lock.withLock { knownPeers[id] = peer }
        return PeerHandle(id: id, displayName: peer.displayName)
    }

    private func mcPeer(_ handle: PeerHandle) -> MCPeerID? {
        lock.withLock { knownPeers[handle.id] }
    }

    private func emit(_ event: TransportEvent) {
        guard let handler = onEvent else { return }
        Task { @MainActor in handler(event) }
    }
}

// MARK: - MCSessionDelegate

extension MultipeerTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected: emit(.connected(handle(peerID)))
        case .notConnected: emit(.disconnected(handle(peerID)))
        case .connecting: break
        @unknown default: break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? SessionMessage.decode(data) else { return }
        emit(.message(message, handle(peerID)))
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: (any Error)?) {
        guard let localURL, error == nil else { return }
        // MC 가 준 임시 파일은 콜백 후 삭제될 수 있으므로 우리 임시 폴더로 옮겨 둔다
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("soban-\(UUID().uuidString)-\(resourceName)")
        try? FileManager.default.copyItem(at: localURL, to: dest)
        emit(.resource(dest, name: resourceName, handle(peerID)))
    }
}

// MARK: - Advertiser / Browser

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // 좌석은 6개(호스트 포함). 꽉 찼으면 거절.
        let accept = session.connectedPeers.count < TableLayout.seatCount - 1
        invitationHandler(accept, accept ? session : nil)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        emit(.error("모임을 알릴 수 없습니다: \(error.localizedDescription)"))
    }
}

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        emit(.foundRoom(handle(peerID), info: info ?? [:]))
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        emit(.lostRoom(handle(peerID)))
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        emit(.error("근처 모임을 찾을 수 없습니다: \(error.localizedDescription)"))
    }
}
