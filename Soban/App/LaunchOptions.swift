import Foundation

/// DEBUG 빌드에서만 읽는 실행 인자. 시뮬레이터 스크린샷/자동 검증용.
///
/// 예) `simctl launch <udid> com.coulson.Soban demo sample tab=gathering hidewindow`
/// - `sample`      : 저장된 페르소나가 없으면 샘플 페르소나를 만들어 활성화
/// - `demo`        : 시작하자마자 이머시브 공간을 열고 데모 손님 3명과 소반을 펼침
/// - `guests=N`    : 데모 손님 수
/// - `tab=home|studio|gathering`
/// - `hidewindow`  : 이머시브가 열리면 메인 창을 닫음(스크린샷용)
/// - `distance=1.4`: 테이블 거리(m)
/// - `splats`      : 샘플/데모 손님을 스플랫 입체로
nonisolated struct LaunchOptions: Sendable {
    var sample = false
    var demo = false
    var guests = 3
    var tab: String?
    var hideWindow = false
    var distance: Float?
    /// 샘플 페르소나와 데모 손님에게 가우시안 스플랫을 만들어 입체로 보여 준다(시뮬레이터 검증용).
    var splats = false
    /// `sample` 과 함께 쓰면 만화 카드 대신 블렌더 흉상 샘플을 저장한다.
    var bust = false
    /// 활성 페르소나의 스플랫을 3DGS PLY 로 이 경로에 쓴다 / 이 경로의 파일을 불러와 초안으로 만든다 (파서 라운드트립 검증용).
    var exportPLYPath: String?
    var importPath: String?

    static let current: LaunchOptions = {
        var o = LaunchOptions()
        #if DEBUG
        for arg in CommandLine.arguments.dropFirst() {
            switch arg {
            case "sample": o.sample = true
            case "demo": o.demo = true
            case "hidewindow": o.hideWindow = true
            case "splats": o.splats = true
            case "bust": o.bust = true
            default:
                if arg.hasPrefix("tab=") { o.tab = String(arg.dropFirst(4)) }
                if arg.hasPrefix("guests="), let n = Int(arg.dropFirst(7)) { o.guests = n }
                if arg.hasPrefix("distance="), let d = Float(arg.dropFirst(9)) { o.distance = d }
                if arg.hasPrefix("exportply=") { o.exportPLYPath = String(arg.dropFirst(10)) }
                if arg.hasPrefix("import=") { o.importPath = String(arg.dropFirst(7)) }
            }
        }
        #endif
        return o
    }()
}
