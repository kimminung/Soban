#if os(visionOS)
import Foundation
import Observation
import SwiftUI

enum AppTab: String, Hashable {
    case home, studio, gathering
}

/// 앱 전역 상태. 페르소나 저장소와 모임 세션을 소유한다.
@Observable
final class AppModel {
    static let immersiveSpaceID = "SobanTable"

    let store: PersonaStore
    let session: GatheringSession
    var selectedTab: AppTab = .home
    var immersiveState: ImmersiveState = .closed
    var openError: String?
    var didApplyLaunchOptions = false
    /// AirDrop/파일 앱에서 소반으로 연 파일(.sobanpersona / .ply). 스튜디오가 가져가 초안으로 만든다.
    var pendingImportURL: URL?

    enum ImmersiveState { case closed, opening, open }

    init() {
        let store = PersonaStore()
        self.store = store
        self.session = GatheringSession(store: store)
        let options = LaunchOptions.current
        if let d = options.distance { session.tableDistance = d }
        if let tab = options.tab, let t = AppTab(rawValue: tab) { selectedTab = t }
        if options.sample, store.personas.isEmpty {
            let sample = PlaceholderPersona.make(name: "콜슨", style: PlaceholderPersona.palette[0])
            _ = try? store.save(sample)
        }
        if options.splats, let active = store.active, !active.hasSplats, let pkg = store.package(for: active.id) {
            Task { [store, session] in
                if let cloud = try? await SplatBuilder.build(from: pkg, progress: { _ in }) {
                    try? store.saveSplats(cloud.encode(), count: cloud.count, for: active.id)
                    session.refreshLocalPersona()
                    if let path = options.exportPLYPath {
                        try? cloud.plyData().write(to: URL(fileURLWithPath: path), options: .atomic)
                    }
                }
            }
        } else if let path = options.exportPLYPath, let active = store.active,
                  let data = store.splatData(for: active.id), let cloud = SplatCloud(data: data) {
            try? cloud.plyData().write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        if let path = options.importPath {
            pendingImportURL = URL(fileURLWithPath: path)
            selectedTab = .studio
        }
    }

    /// 이머시브 공간 열기. 실패 사유를 `openError` 에 남긴다.
    func openTable(_ open: OpenImmersiveSpaceAction) async {
        guard immersiveState == .closed else { return }
        immersiveState = .opening
        openError = nil
        let result = await open(id: Self.immersiveSpaceID)
        switch result {
        case .opened:
            immersiveState = .open
        case .userCancelled:
            immersiveState = .closed
            openError = "이머시브 공간 열기가 취소되었습니다."
        case .error:
            immersiveState = .closed
            openError = "이머시브 공간을 열지 못했습니다. 다른 이머시브 앱이 열려 있다면 닫고 다시 시도하세요."
        @unknown default:
            immersiveState = .closed
        }
    }

    func closeTable(_ dismiss: DismissImmersiveSpaceAction) async {
        guard immersiveState == .open else { return }
        await dismiss()
        // 실제 상태 전환은 TableImmersiveView.onDisappear 가 담당
    }
}
#endif
