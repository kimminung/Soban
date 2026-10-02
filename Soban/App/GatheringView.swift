#if os(visionOS)
import SwiftUI

/// 모임 탭: 소반 펼치기/열기/참여, 참가자, 반응, 마이크, 테이블 거리.
struct GatheringView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        @Bindable var session = app.session
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                statusBanner
                modeControls(session: session)
                if session.mode == .browsing { roomList }
                if session.isActive { seats }
                if session.isActive { reactions }
                settings(session: session)
            }
            .padding(28)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("모임").font(.largeTitle.bold())
            Text("좌식 두레반에 여섯 자리. 나는 항상 가까운 자리, 나머지는 시계 반대 방향으로 앉습니다.")
                .foregroundStyle(.secondary)
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: iconForMode)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.session.statusText).font(.headline)
                HStack(spacing: 14) {
                    Text(app.session.tracker.statusText)
                    if app.session.connectedPeerCount > 0 {
                        Text("피어 \(app.session.connectedPeerCount) · 보냄 \(app.session.packetsSent) · 받음 \(app.session.packetsReceived)")
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            switch app.immersiveState {
            case .closed:
                Button("소반 펼치기") { Task { await openSpace() } }
                    .buttonStyle(.borderedProminent)
            case .opening:
                ProgressView()
            case .open:
                Button("상 접기") { Task { await app.closeTable(dismissImmersiveSpace) } }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(alignment: .bottomLeading) {
            if let err = app.openError {
                Text(err).font(.footnote).foregroundStyle(.orange).padding(.horizontal, 18).offset(y: 22)
            }
        }
    }

    private var iconForMode: String {
        switch app.session.mode {
        case .idle: "table.furniture"
        case .solo: "person.3.sequence"
        case .hosting: "antenna.radiowaves.left.and.right"
        case .browsing: "magnifyingglass"
        case .joined: "person.2.wave.2"
        }
    }

    private func modeControls(session: GatheringSession) -> some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    session.startSolo(guests: 3)
                    await openSpace()
                }
            } label: { Label("데모 손님과", systemImage: "person.3.sequence") }
            Button {
                Task {
                    session.startHosting()
                    await openSpace()
                }
            } label: { Label("모임 열기", systemImage: "antenna.radiowaves.left.and.right") }
            Button {
                session.startBrowsing()
            } label: { Label("모임 참여", systemImage: "magnifyingglass") }
            if session.mode != .idle {
                Button(role: .destructive) {
                    session.leave(keepImmersive: true)
                } label: { Label("나가기", systemImage: "rectangle.portrait.and.arrow.right") }
            }
            Spacer()
            if session.isHost {
                Button {
                    session.addDemoGuest()
                } label: { Label("손님 추가", systemImage: "person.badge.plus") }
                .disabled(session.participants.count >= TableLayout.seatCount)
            }
        }
    }

    private var roomList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("근처 소반").font(.headline)
            if app.session.foundRooms.isEmpty {
                HStack { ProgressView(); Text("같은 Wi‑Fi 에서 '모임 열기' 한 Vision Pro 를 찾는 중…").foregroundStyle(.secondary) }
            }
            ForEach(app.session.foundRooms) { room in
                HStack {
                    Image(systemName: "table.furniture")
                    VStack(alignment: .leading) {
                        Text(room.roomName).font(.headline)
                        Text(room.hostName.isEmpty ? room.peer.displayName : "호스트 \(room.hostName)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("앉기") {
                        Task {
                            app.session.join(room)
                            await openSpace()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            if let err = app.session.lastError {
                Text(err).font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private var seats: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("자리").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                ForEach(0..<TableLayout.seatCount, id: \.self) { seat in
                    let p = app.session.seatedParticipants.first { $0.seat == seat }
                    SeatCell(seat: seat, participant: p, slot: TableLayout.slot(forSeat: seat, mySeat: app.session.mySeat))
                }
            }
        }
    }

    private var reactions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("반응").font(.headline)
            HStack(spacing: 10) {
                ForEach(Reaction.allCases, id: \.self) { r in
                    Button {
                        app.session.send(reaction: r)
                    } label: {
                        VStack(spacing: 2) {
                            Text(r.rawValue).font(.system(size: 28))
                            Text(r.label).font(.caption2)
                        }
                        .frame(width: 72, height: 64)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func settings(session: GatheringSession) -> some View {
        @Bindable var session = session
        return VStack(alignment: .leading, spacing: 14) {
            Text("설정").font(.headline)
            Toggle(isOn: $session.micEnabled) {
                Label("마이크 — 입 모양 + 음성 전송", systemImage: session.micEnabled ? "mic" : "mic.slash")
            }
            Toggle(isOn: $session.showSelfMirror) {
                Label("내 모습 보기 — 내 자리 오른쪽 위에 거울처럼 띄우기", systemImage: "person.crop.rectangle.badge.plus")
            }
            Toggle(isOn: $session.botsSpeak) {
                Label(session.botVoiceAvailable ? "데모 손님 목소리 (한국어 TTS, 좌석 위치에서 재생)" : "데모 손님 목소리 — 이 환경에서는 사용 불가",
                      systemImage: "speaker.wave.2")
            }
            .disabled(!session.botVoiceAvailable)
            HStack {
                Label("테이블 거리", systemImage: "arrow.left.and.right")
                Slider(value: $session.tableDistance, in: 0.8...2.2)
                Text(String(format: "%.2f m", session.tableDistance)).monospacedDigit().frame(width: 70)
            }
            HStack {
                TextField("내 이름", text: $session.displayName).textFieldStyle(.roundedBorder).frame(width: 160)
                TextField("모임 이름", text: $session.roomName).textFieldStyle(.roundedBorder).frame(width: 220)
                Button("정면 다시 맞추기") { session.recalibrate() }
                    .disabled(!session.isImmersiveOpen)
            }
            if let err = session.voice.errorText {
                Text(err).font(.footnote).foregroundStyle(.orange)
            }
            Text("개인 개발자 팀에서는 SharePlay(Group Activities) 자격을 받을 수 없어, 같은 로컬 네트워크의 Vision Pro 끼리 MultipeerConnectivity 로 직접 연결합니다.")
                .font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func openSpace() async {
        await app.openTable(openImmersiveSpace)
    }
}

struct SeatCell: View {
    @Environment(AppModel.self) private var app
    let seat: Int
    let participant: GatheringSession.Participant?
    let slot: Int

    var body: some View {
        HStack(spacing: 10) {
            if let p = participant {
                if let img = p.image {
                    Image(decorative: img, scale: 1).resizable().scaledToFit().frame(width: 40, height: 50)
                } else {
                    Image(systemName: "person.crop.rectangle").font(.title).frame(width: 40, height: 50)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.isLocal ? "\(p.displayName) (나)" : p.displayName).font(.subheadline.bold())
                    Text(p.isBot ? (p.caption.map { "“\($0)”" } ?? "데모 손님") : (p.isLocal ? "내 자리" : (p.hasPersona ? "연결됨" : "페르소나 받는 중…")))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    LevelMeter(level: p.level)
                }
            } else {
                Image(systemName: "circle.dashed").font(.title).frame(width: 40, height: 50).foregroundStyle(.tertiary)
                Text("빈 방석").foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(slot)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
#endif
