#if os(visionOS)
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            Tab("홈", systemImage: "house", value: AppTab.home) {
                HomeView()
            }
            Tab("페르소나", systemImage: "person.crop.square.badge.camera", value: AppTab.studio) {
                StudioView()
            }
            Tab("모임", systemImage: "person.3", value: AppTab.gathering) {
                GatheringView()
            }
        }
        .task { await applyLaunchOptions() }
        .onOpenURL { url in
            app.pendingImportURL = url
            app.selectedTab = .studio
        }
    }

    /// DEBUG 실행 인자(`demo`, `hidewindow`)를 한 번만 적용.
    private func applyLaunchOptions() async {
        guard !app.didApplyLaunchOptions else { return }
        app.didApplyLaunchOptions = true
        let options = LaunchOptions.current
        guard options.demo else { return }
        app.session.startSolo(guests: options.guests)
        app.selectedTab = .gathering
        await app.openTable(openImmersiveSpace)
        if app.immersiveState == .open, options.hideWindow {
            try? await Task.sleep(for: .seconds(1))
            dismissWindow()
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
#endif
