#if os(visionOS)
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                personaCard
                actionGrid
                howItWorks
            }
            .padding(32)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("소반")
                .font(.system(size: 44, weight: .bold))
            Text("내 모습으로 만든 페르소나를 허공에 띄우고, 좌식 상에 둘러앉아 이야기하기")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    /// 홈 카드의 3D 미리보기용 스플랫 (스튜디오가 이미 읽었으면 그것, 아니면 저장소에서)
    @State private var homeSplats: SplatCloud?
    @State private var homeSplatsKey = ""

    private var personaCard: some View {
        HStack(spacing: 20) {
            if let p = app.store.active, let img = app.store.image(for: p.id) {
                // 9차: 썸네일 PNG 대신 스튜디오와 같은 살아 있는 미리보기(흉상 샘플·스플랫·얼굴 키트)
                PersonaPreviewView(manifest: p, image: img, splats: homeSplats, name: p.name,
                                   levelSource: { 0 }, previewScale: 0.19, demoMotion: true, turntable: false)
                    .frame(width: 260, height: 290)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .task(id: "\(p.id.uuidString)-\(p.splatCount)") {
                        let key = "\(p.id.uuidString)-\(p.splatCount)"
                        guard homeSplatsKey != key else { return }
                        homeSplatsKey = key
                        if app.studio.activeSplatsID == p.id, let s = app.studio.activeSplats {
                            homeSplats = s
                        } else {
                            homeSplats = app.store.splatData(for: p.id).flatMap { SplatCloud(data: $0) }
                        }
                    }
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.name).font(.title2.bold())
                    Text(p.demoAvatarCase.map { "블렌더 흉상 샘플 · \($0.displayName)" }
                         ?? (p.kind == .photo ? "사진으로 만든 페르소나" : "샘플 페르소나"))
                        .foregroundStyle(.secondary)
                    Text(p.demoAvatar != nil
                         ? "USDZ 흉상 · ARKit 52 블렌드셰이프"
                         : "\(p.imageWidth)×\(p.imageHeight) · \(p.face == nil ? "얼굴 리그 없음" : "눈·입 리그 있음")\(p.hasSplats ? " · 스플랫 \(p.splatCount.formatted())개" : "")")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                    Button("스튜디오에서 다듬기") { app.selectedTab = .studio }
                        .padding(.top, 4)
                }
            } else {
                Image(systemName: "person.crop.rectangle.badge.plus")
                    .font(.system(size: 54))
                    .frame(width: 120, height: 150)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 8) {
                    Text("아직 페르소나가 없어요").font(.title2.bold())
                    Text("상반신이 보이는 정면 사진 한 장이면 충분합니다.")
                        .foregroundStyle(.secondary)
                    Button("페르소나 만들기") { app.selectedTab = .studio }
                        .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            ActionTile(title: app.immersiveState == .open ? "상 접기" : "소반 펼치기",
                       subtitle: app.openError ?? (app.immersiveState == .open ? "이머시브 공간을 닫습니다" : "내 방에 좌식 상을 놓습니다"),
                       systemImage: app.immersiveState == .open ? "xmark.circle" : "table.furniture") {
                Task { await toggleImmersive() }
            }
            ActionTile(title: "데모 손님과 앉기", subtitle: "데모 손님 3명이 번갈아 이야기해요", systemImage: "person.3.sequence") {
                Task {
                    app.session.startSolo(guests: 3)
                    app.selectedTab = .gathering
                    if app.immersiveState == .closed { await toggleImmersive() }
                }
            }
            ActionTile(title: "모임 열기", subtitle: "같은 Wi‑Fi 의 Vision Pro 를 초대", systemImage: "antenna.radiowaves.left.and.right") {
                Task {
                    app.session.startHosting()
                    app.selectedTab = .gathering
                    if app.immersiveState == .closed { await toggleImmersive() }
                }
            }
            ActionTile(title: "모임 참여", subtitle: "근처에서 펼쳐진 소반 찾기", systemImage: "magnifyingglass") {
                app.session.startBrowsing()
                app.selectedTab = .gathering
            }
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("어떻게 움직이나요").font(.headline)
            Label("사진 → Vision 인물 분리 + 얼굴 랜드마크 → 투명 카드 페르소나", systemImage: "scissors")
            Label("Vision Pro 머리 자세·손 위치 → 페르소나의 고개·손짓", systemImage: "move.3d")
            Label("내 목소리 크기 → 입 벌림, 음성은 좌석 위치에서 공간 재생", systemImage: "waveform")
            Label("MultipeerConnectivity 로 같은 네트워크의 Vision Pro 와 풀 메시 연결", systemImage: "network")
        }
        .foregroundStyle(.secondary)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private func toggleImmersive() async {
        switch app.immersiveState {
        case .open: await app.closeTable(dismissImmersiveSpace)
        case .closed: await app.openTable(openImmersiveSpace)
        case .opening: break
        }
    }
}

struct ActionTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 30))
                Text(title).font(.title3.bold())
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .hoverEffect()
    }
}
#endif
