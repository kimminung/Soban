#if os(visionOS)
import SwiftUI
import RealityKit

/// 혼합(mixed) 이머시브 공간. 바닥 원점에 두레반을 놓고, 참가자 아바타를 방석 위에 띄운다.
/// 이머시브 상태(`app.immersiveState`)는 이 뷰의 등장/사라짐으로만 결정한다 —
/// Digital Crown 으로 닫거나 시스템이 닫아도 창의 "소반 펼치기" 버튼이 다시 살아난다.
struct TableImmersiveView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        RealityView { content in
            content.add(app.session.renderer.root)
        }
        .onAppear {
            app.immersiveState = .open
            app.openError = nil
        }
        .task {
            await app.session.immersiveOpened()
        }
        .onDisappear {
            app.immersiveState = .closed
            app.session.immersiveClosed()
        }
    }
}
#endif
