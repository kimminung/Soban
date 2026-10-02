#if os(visionOS)
import Foundation
import CoreGraphics
import Observation
import QuartzCore
import os

/// 소반 모임의 중심 상태 머신.
///
/// - `solo`     : 나 + 데모 손님. 네트워크 없음.
/// - `hosting`  : 내가 상을 펼치고 알림. 좌석표를 내가 관리.
/// - `browsing` : 근처 상을 찾는 중.
/// - `joined`   : 남의 상에 앉음.
///
/// 30Hz 틱에서 머리/손/목소리를 읽어 내 포즈를 보내고(15Hz), 원격 포즈·음성을 아바타에 반영한다.
@Observable
final class GatheringSession {
    enum Mode: String { case idle, solo, hosting, browsing, joined }

    struct Participant: Identifiable {
        let id: UUID
        var info: ParticipantInfo
        var manifest: PersonaManifest?
        var image: CGImage?
        var splats: SplatCloud?
        var pose = PersonaPose.rest
        var level: Float = 0
        var seat: Int?
        var isLocal = false
        var isBot = false
        var bot: BotBrain?
        var lastPoseAt: Double = 0
        var peer: PeerHandle?
        var isConnected = true
        /// 데모 손님이 마지막으로 한 말.
        var caption: String?

        var displayName: String { info.name }
        var hasPersona: Bool { manifest != nil && image != nil }
    }

    struct FoundRoom: Identifiable, Hashable {
        var id: String { peer.id }
        let peer: PeerHandle
        let roomName: String
        let hostName: String
    }

    // MARK: State

    private(set) var mode: Mode = .idle
    private(set) var participants: [UUID: Participant] = [:]
    private(set) var foundRooms: [FoundRoom] = []
    private(set) var statusText = "상이 아직 펼쳐지지 않았습니다"
    private(set) var lastError: String?
    private(set) var isImmersiveOpen = false
    private(set) var packetsSent = 0
    private(set) var packetsReceived = 0

    var roomName: String {
        didSet { UserDefaults.standard.set(roomName, forKey: "soban.roomName") }
    }
    var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: "soban.displayName") }
    }
    var micEnabled = true {
        didSet { Task { await applyMicState() } }
    }
    /// 3인칭 "내 모습 보기" 거울.
    var showSelfMirror: Bool {
        didSet { UserDefaults.standard.set(showSelfMirror, forKey: "soban.showSelfMirror") }
    }
    /// 데모 손님이 TTS 로 말하기.
    var botsSpeak: Bool {
        didSet { UserDefaults.standard.set(botsSpeak, forKey: "soban.botsSpeak") }
    }
    var tableDistance: Float {
        didSet {
            UserDefaults.standard.set(tableDistance, forKey: "soban.tableDistance")
            renderer.setDistance(tableDistance)
        }
    }

    let localID: UUID
    let tracker = HeadHandTracker()
    let voice = VoiceEngine()
    let renderer: TableRenderer
    private let botSpeech = BotSpeech()
    private unowned let store: PersonaStore

    private var transport: (any SessionTransport)?
    private var peerToParticipant: [PeerHandle: UUID] = [:]
    private var receivedPNG: [UUID: Data] = [:] // personaID → png
    private var receivedSplats: [UUID: SplatCloud] = [:] // personaID → splats
    private var hostID: UUID?
    private var tickTask: Task<Void, Never>?
    private var tickCount = 0
    private var voiceSeq: UInt32 = 0
    private var pendingReactions: [(UUID, Reaction)] = []
    private var nextBotTurnAt: Double = 0
    private var botTurnPending = false
    private let log = Logger(subsystem: "com.coulson.Soban", category: "session")

    // MARK: Init

    init(store: PersonaStore) {
        self.store = store
        let defaults = UserDefaults.standard
        if let s = defaults.string(forKey: "soban.participantID"), let id = UUID(uuidString: s) {
            localID = id
        } else {
            localID = UUID()
            defaults.set(localID.uuidString, forKey: "soban.participantID")
        }
        roomName = defaults.string(forKey: "soban.roomName") ?? "우리 소반"
        displayName = defaults.string(forKey: "soban.displayName") ?? "나"
        showSelfMirror = defaults.object(forKey: "soban.showSelfMirror") as? Bool ?? true
        botsSpeak = defaults.object(forKey: "soban.botsSpeak") as? Bool ?? true
        let d = defaults.object(forKey: "soban.tableDistance") as? Float ?? 1.05
        tableDistance = d
        renderer = TableRenderer(distance: d)
    }

    // MARK: Derived

    var isHost: Bool { mode == .solo || mode == .hosting }
    var isActive: Bool { mode != .idle && mode != .browsing }
    var mySeat: Int { participants[localID]?.seat ?? 0 }
    var localParticipant: Participant? { participants[localID] }
    var botVoiceAvailable: Bool { botSpeech.voiceAvailable && voice.audioAvailable }

    /// 좌석 순서대로 정렬된 참가자(나 포함).
    var seatedParticipants: [Participant] {
        participants.values
            .filter { $0.seat != nil }
            .sorted { ($0.seat ?? 0) < ($1.seat ?? 0) }
    }

    var remoteCount: Int { participants.values.filter { !$0.isLocal }.count }
    var connectedPeerCount: Int { transport?.connectedPeers.count ?? 0 }

    // MARK: - Mode transitions

    func startSolo(guests: Int = 3) {
        leave(keepImmersive: true)
        mode = .solo
        hostID = localID
        insertLocalParticipant(seat: 0)
        for _ in 0..<min(guests, TableLayout.seatCount - 1) { addDemoGuest() }
        statusText = "혼자 펼친 소반 · 데모 손님 \(remoteCount)명"
        startTicking()
    }

    func addDemoGuest() {
        let used = Set(participants.values.compactMap(\.seat))
        guard let seat = (0..<TableLayout.seatCount).first(where: { !used.contains($0) }) else { return }
        let index = participants.values.filter(\.isBot).count
        let package = PlaceholderPersona.guest(index: index)
        var p = Participant(id: UUID(), info: ParticipantInfo(id: UUID(), name: package.manifest.name, personaID: package.manifest.id))
        p.manifest = package.manifest
        p.image = PersonaBuilder.decodeImage(package.bodyPNG)
        p.seat = seat
        p.isBot = true
        p.bot = BotBrain(index: index, now: CACurrentMediaTime())
        participants[p.id] = p
        if LaunchOptions.current.splats {
            let botID = p.id
            Task { [weak self] in
                guard let cloud = try? await SplatBuilder.build(from: package, progress: { _ in }) else { return }
                guard let self, var bot = participants[botID] else { return }
                bot.splats = cloud
                participants[botID] = bot
            }
        }
        if mode == .idle { startSolo(guests: 0) }
        statusText = mode == .solo ? "혼자 펼친 소반 · 데모 손님 \(remoteCount)명" : statusText
        if isHost { broadcastRoster() }
    }

    func removeDemoGuests() {
        for (id, p) in participants where p.isBot {
            participants[id] = nil
            voice.removeSource(id)
        }
        if isHost { broadcastRoster() }
    }

    func startHosting() {
        leave(keepImmersive: true)
        mode = .hosting
        hostID = localID
        insertLocalParticipant(seat: 0)
        let t = makeTransport()
        t.startHosting(roomName: roomName, hostName: displayName)
        statusText = "'\(roomName)' 을 알리는 중 · 같은 Wi‑Fi 의 Vision Pro 에서 참여할 수 있어요"
        startTicking()
    }

    func startBrowsing() {
        leave(keepImmersive: true)
        mode = .browsing
        foundRooms = []
        let t = makeTransport()
        t.startBrowsing()
        statusText = "근처의 소반을 찾는 중…"
    }

    func join(_ room: FoundRoom) {
        guard let transport else { return }
        hostID = nil
        insertLocalParticipant(seat: nil)
        transport.invite(room.peer)
        statusText = "'\(room.roomName)' 에 앉는 중…"
    }

    func leave(keepImmersive: Bool = false) {
        if let transport {
            transport.send(.bye(localID), to: nil, reliable: true)
            transport.disconnect()
            transport.onEvent = nil
        }
        transport = nil
        peerToParticipant.removeAll()
        for (id, _) in participants { voice.removeSource(id) }
        participants.removeAll()
        renderer.removeAll()
        foundRooms = []
        hostID = nil
        botTurnPending = false
        mode = .idle
        statusText = "상이 아직 펼쳐지지 않았습니다"
        if !keepImmersive { stopTicking() }
    }

    func send(reaction: Reaction) {
        pendingReactions.append((localID, reaction))
        transport?.send(.reaction(localID, reaction), to: nil, reliable: true)
    }

    /// 내 페르소나가 바뀌었을 때 호출: 피어들에게 다시 알린다.
    func refreshLocalPersona() {
        guard var me = participants[localID] else { return }
        let manifest = store.active
        me.info.personaID = manifest?.id
        me.manifest = manifest
        me.image = manifest.flatMap { store.image(for: $0.id) }
        me.splats = manifest.flatMap { store.splatData(for: $0.id) }.flatMap { SplatCloud(data: $0) }
        participants[localID] = me
        if let transport {
            for peer in transport.connectedPeers { sendIdentity(to: peer, via: transport) }
        }
    }

    // MARK: - Immersive lifecycle

    func immersiveOpened() async {
        isImmersiveOpen = true
        if mode == .idle { startSolo(guests: 0) }
        startTicking()
        // ARKit 세션 시작은 시뮬레이터에서 오래 걸릴 수 있어 따로 돌린다. 머리 자세가 들어오는 순간 자동 캘리브레이션된다.
        Task { [tracker] in await tracker.start() }
        // 오디오 엔진은 마이크가 켜져 있을 때(또는 첫 원격 음성이 올 때) 느리게 시작한다.
        await applyMicState()
    }

    func immersiveClosed() {
        isImmersiveOpen = false
        tracker.stop()
        voice.stopCapture()
        for (id, _) in participants { voice.removeSource(id) }
        stopTicking()
    }

    func recalibrate() {
        tracker.calibrate()
    }

    private func applyMicState() async {
        guard isImmersiveOpen else { return }
        if micEnabled { await voice.startCapture() } else { voice.stopCapture() }
    }

    // MARK: - Participants

    private func insertLocalParticipant(seat: Int?) {
        let manifest = store.active
        var me = Participant(id: localID, info: ParticipantInfo(id: localID, name: displayName, personaID: manifest?.id))
        me.manifest = manifest
        me.image = manifest.flatMap { store.image(for: $0.id) }
        me.splats = manifest.flatMap { store.splatData(for: $0.id) }.flatMap { SplatCloud(data: $0) }
        me.seat = seat
        me.isLocal = true
        participants[localID] = me
    }

    private func assignSeat(to id: UUID) {
        guard isHost, var p = participants[id], p.seat == nil else { return }
        let used = Set(participants.values.compactMap(\.seat))
        p.seat = (0..<TableLayout.seatCount).first { !used.contains($0) }
        participants[id] = p
    }

    private func broadcastRoster() {
        guard isHost, let transport else { return }
        let roster = participants.values.compactMap { p in p.seat.map { SeatAssignment(participantID: p.id, seat: $0) } }
        transport.send(.roster(roster, hostID: localID), to: nil, reliable: true)
    }

    // MARK: - Transport

    private func makeTransport() -> any SessionTransport {
        let t: any SessionTransport = MultipeerTransport(displayName: "\(displayName)·\(localID.uuidString.prefix(4))")
        t.onEvent = { [weak self] event in self?.handle(event) }
        transport = t
        return t
    }

    private func sendIdentity(to peer: PeerHandle, via transport: any SessionTransport) {
        guard let me = participants[localID] else { return }
        transport.send(.hello(me.info, me.manifest), to: [peer], reliable: true)
        if let manifest = me.manifest, let png = store.pngData(for: manifest.id) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(TransferResource.body(manifest.id))
            if (try? png.write(to: url, options: .atomic)) != nil {
                transport.sendResource(at: url, name: TransferResource.body(manifest.id), to: peer)
            }
            if let splats = store.splatData(for: manifest.id) {
                let surl = FileManager.default.temporaryDirectory.appendingPathComponent(TransferResource.splats(manifest.id))
                if (try? splats.write(to: surl, options: .atomic)) != nil {
                    transport.sendResource(at: surl, name: TransferResource.splats(manifest.id), to: peer)
                }
            }
        }
    }

    private func handle(_ event: TransportEvent) {
        guard let transport else { return }
        switch event {
        case .connected(let peer):
            sendIdentity(to: peer, via: transport)
            if mode == .browsing {
                mode = .joined
                statusText = "상에 앉았습니다 · 좌석표를 기다리는 중"
                startTicking()
            } else if mode == .hosting {
                statusText = "'\(roomName)' · \(transport.connectedPeers.count)명 연결됨"
            }

        case .disconnected(let peer):
            if let id = peerToParticipant.removeValue(forKey: peer) {
                participants[id] = nil
                voice.removeSource(id)
                if id == hostID {
                    statusText = "호스트가 상을 접었습니다"
                    leave(keepImmersive: true)
                    return
                }
                if isHost { broadcastRoster() }
            }
            if mode == .joined && transport.connectedPeers.isEmpty {
                statusText = "연결이 끊어졌습니다"
                leave(keepImmersive: true)
            } else if mode == .hosting {
                statusText = "'\(roomName)' · \(transport.connectedPeers.count)명 연결됨"
            }

        case .message(let message, let peer):
            packetsReceived += 1
            handle(message, from: peer)

        case .resource(let url, let name, _):
            guard let parsed = TransferResource.parse(name), let data = try? Data(contentsOf: url) else { return }
            try? FileManager.default.removeItem(at: url)
            switch parsed.kind {
            case "persona": receivedPNG[parsed.id] = data
            case "splats": if let cloud = SplatCloud(data: data) { receivedSplats[parsed.id] = cloud }
            default: break
            }
            attachImages()

        case .foundRoom(let peer, let info):
            let room = FoundRoom(peer: peer, roomName: info["room"] ?? peer.displayName, hostName: info["host"] ?? "")
            if !foundRooms.contains(where: { $0.id == room.id }) { foundRooms.append(room) }
            statusText = "근처 소반 \(foundRooms.count)개"

        case .lostRoom(let peer):
            foundRooms.removeAll { $0.peer == peer }

        case .error(let text):
            lastError = text
        }
    }

    private func handle(_ message: SessionMessage, from peer: PeerHandle) {
        switch message {
        case .hello(let info, let manifest):
            var p = participants[info.id] ?? Participant(id: info.id, info: info)
            p.info = info
            p.peer = peer
            p.manifest = manifest
            if let manifest, let png = receivedPNG[manifest.id] { p.image = PersonaBuilder.decodeImage(png) }
            if let manifest { p.splats = receivedSplats[manifest.id] }
            participants[info.id] = p
            peerToParticipant[peer] = info.id
            if isHost {
                assignSeat(to: info.id)
                broadcastRoster()
            }
            if mode == .hosting { statusText = "'\(roomName)' · \(remoteCount)명 함께" }

        case .roster(let roster, let host):
            hostID = host
            for entry in roster {
                if var p = participants[entry.participantID] {
                    p.seat = entry.seat
                    participants[entry.participantID] = p
                } else if entry.participantID != localID {
                    // hello 보다 roster 가 먼저 온 경우: 자리만 만들어 둔다
                    var p = Participant(id: entry.participantID, info: ParticipantInfo(id: entry.participantID, name: "…", personaID: nil))
                    p.seat = entry.seat
                    participants[entry.participantID] = p
                }
            }
            if mode == .joined { statusText = "상에 앉았습니다 · \(remoteCount)명 함께" }

        case .pose(let id, let pose):
            guard var p = participants[id] else { return }
            p.pose = pose
            p.lastPoseAt = CACurrentMediaTime()
            participants[id] = p

        case .voice(let id, _, let pcm):
            guard var p = participants[id] else { return }
            let slot = TableLayout.slot(forSeat: p.seat ?? 0, mySeat: mySeat)
            let position = renderer.worldPosition(forSlot: slot)
            let lvl = voice.enqueue(id, pcm: pcm, position: position)
            p.level = max(p.level, lvl)
            participants[id] = p

        case .reaction(let id, let reaction):
            pendingReactions.append((id, reaction))

        case .bye(let id):
            participants[id] = nil
            voice.removeSource(id)
            peerToParticipant[peer] = nil
            if isHost { broadcastRoster() }

        case .personaTransfer, .personaTransferComplete, .personaReceived:
            break // 캡처 전송 서비스 전용 메시지
        }
    }

    private func attachImages() {
        for (id, var p) in participants {
            guard let manifest = p.manifest else { continue }
            var changed = false
            if p.image == nil, let png = receivedPNG[manifest.id] {
                p.image = PersonaBuilder.decodeImage(png)
                changed = true
            }
            if p.splats == nil, let cloud = receivedSplats[manifest.id] {
                p.splats = cloud
                changed = true
            }
            if changed { participants[id] = p }
        }
    }

    // MARK: - Demo guests

    private func scheduleBotTurn(now: Double) {
        guard now >= nextBotTurnAt, !botTurnPending else { return }
        let bots = participants.values.filter(\.isBot).map(\.id).shuffled()
        guard let speakerID = bots.first else { return }
        botTurnPending = true
        nextBotTurnAt = now + 30 // 렌더링이 끝나면 실제 길이로 다시 설정
        Task { await beginBotTurn(speakerID) }
    }

    private func beginBotTurn(_ id: UUID) async {
        defer { botTurnPending = false }
        guard let brain = participants[id]?.bot else { return }
        let line = BotSpeech.lines.randomElement() ?? "…"
        var rendered: BotSpeech.Rendered?
        if botsSpeak && voice.audioAvailable {
            rendered = await botSpeech.render(line, pitch: brain.pitch)
        }
        guard var p = participants[id], var updated = p.bot else { return }
        let now = CACurrentMediaTime()
        let duration: Double
        if let r = rendered {
            duration = r.duration
            updated.beginTurn(now: now, duration: r.duration, envelope: r.envelope, hop: r.hop)
            let slot = TableLayout.slot(forSeat: p.seat ?? 0, mySeat: mySeat)
            voice.enqueue(id, buffers: r.buffers, position: renderer.worldPosition(forSlot: slot))
        } else {
            duration = Double.random(in: 2.5...6.0)
            updated.beginTurn(now: now, duration: duration)
        }
        p.bot = updated
        p.caption = line
        participants[id] = p
        nextBotTurnAt = now + duration + Double.random(in: 0.8...2.2)
    }

    // MARK: - Tick

    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        tickCount += 1

        // 1. 내 상태
        tracker.poll()
        let chunks = voice.drainCapture()
        let myLevel = voice.level
        if var me = participants[localID] {
            var pose = tracker.currentPose(mouth: myLevel, speaking: myLevel > 0.12) ?? PersonaPose(mouth: myLevel, speaking: myLevel > 0.12)
            pose.mouth = myLevel
            me.pose = pose
            me.level = myLevel
            participants[localID] = me

            if let transport, !transport.connectedPeers.isEmpty {
                if tickCount % 2 == 0 {
                    transport.send(.pose(localID, pose), to: nil, reliable: false)
                    packetsSent += 1
                }
                if micEnabled {
                    for chunk in chunks {
                        voiceSeq &+= 1
                        transport.send(.voice(localID, voiceSeq, chunk), to: nil, reliable: false)
                        packetsSent += 1
                    }
                }
            }
        }

        // 2. 데모 손님
        if participants.values.contains(where: \.isBot) {
            scheduleBotTurn(now: now)
            for (id, var p) in participants where p.isBot {
                guard var brain = p.bot else { continue }
                let (pose, level) = brain.pose(at: now)
                if let reaction = brain.maybeReaction(at: now) { pendingReactions.append((id, reaction)) }
                p.bot = brain
                p.pose = pose
                p.level = level
                p.lastPoseAt = now
                if !brain.isSpeaking && now - brain.turnStart > 8 { p.caption = nil }
                participants[id] = p
            }
        }

        // 3. 원격 참가자 감쇠/타임아웃
        for (id, var p) in participants where !p.isLocal && !p.isBot {
            p.level *= 0.82
            if now - p.lastPoseAt > 3 { p.pose = PersonaPose(mouth: 0) }
            participants[id] = p
        }

        // 4. 렌더링 + 공간 음향 리스너
        if let head = tracker.headPosition {
            renderer.viewerPosition = head
            if let t = tracker.headTransform {
                voice.setListener(position: head, yaw: HeadHandTracker.yaw(of: t))
            }
        }
        let renderables = participants.values.compactMap { p -> RenderableParticipant? in
            guard !p.isLocal, let seat = p.seat else { return nil }
            return RenderableParticipant(id: p.id, slot: TableLayout.slot(forSeat: seat, mySeat: mySeat),
                                         manifest: p.manifest, image: p.image, splats: p.splats, pose: p.pose, level: p.level)
        }
        var selfRenderable: RenderableParticipant?
        if showSelfMirror, let me = participants[localID] {
            selfRenderable = RenderableParticipant(id: me.id, slot: 0, manifest: me.manifest, image: me.image,
                                                   splats: me.splats, pose: me.pose, level: me.level)
        }
        let reactions = pendingReactions
        pendingReactions.removeAll()
        renderer.sync(renderables, selfParticipant: selfRenderable,
                      reactions: reactions.filter { $0.0 != localID || showSelfMirror }, now: now)
    }
}
#endif
