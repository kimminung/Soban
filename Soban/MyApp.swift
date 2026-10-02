import SwiftUI

#if os(visionOS)
import RealityKit

/// 소반 (Soban) — 내 모습으로 만든 페르소나를 좌식 상에 둘러앉혀 이야기하는 visionOS 앱.
@main
struct SobanApp: App {
    @State private var app = AppModel()

    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
                .environment(app)
        }
        .defaultSize(width: 1040, height: 760)

        ImmersiveSpace(id: AppModel.immersiveSpaceID) {
            TableImmersiveView()
                .environment(app)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

#else

/// 소반 캡처 — iPhone / iPad / Mac 에서 얼굴을 각도별로 촬영해 페르소나를 만들고 Vision Pro 로 보낸다.
@main
struct SobanCompanionApp: App {
    var body: some Scene {
        WindowGroup {
            CompanionRootView()
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 980)
        #endif
    }
}
#endif
