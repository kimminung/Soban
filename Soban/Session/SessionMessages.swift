import Foundation

/// 모임에 참여한 사람의 정체성. 기기별로 고정 UUID 를 쓴다.
nonisolated struct ParticipantInfo: Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var personaID: UUID?
}

nonisolated struct SeatAssignment: Codable, Hashable, Sendable {
    var participantID: UUID
    var seat: Int
}

/// 피어 간에 오가는 메시지. 바이너리 plist 로 인코딩한다 (Data 가 그대로 들어가서 JSON 보다 작다).
nonisolated enum SessionMessage: Codable, Sendable {
    /// 연결 직후 서로 교환. 매니페스트가 있으면 함께, PNG 는 `sendResource` 로 별도 전송.
    case hello(ParticipantInfo, PersonaManifest?)
    /// 호스트 → 전원. 좌석표.
    case roster([SeatAssignment], hostID: UUID)
    /// 15Hz 머리/입/손 상태 (unreliable).
    case pose(UUID, PersonaPose)
    /// 60ms 16kHz Int16 PCM (unreliable).
    case voice(UUID, UInt32, Data)
    case reaction(UUID, Reaction)
    case bye(UUID)
    /// 캡처 기기(iPhone/iPad/Mac) → Vision Pro. PNG 는 `persona-<id>.png` 리소스로 뒤따른다.
    case personaTransfer(PersonaManifest, senderName: String)
    /// 캡처 기기 → Vision Pro. 모든 리소스(`persona-`, `depth-`, `side-`, `splats-`) 전송이 끝났음을 알린다.
    case personaTransferComplete(UUID, resources: [String])
    /// Vision Pro → 캡처 기기. 저장 완료 알림.
    case personaReceived(UUID)

    nonisolated static func encode(_ message: SessionMessage) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(message)
    }

    nonisolated static func decode(_ data: Data) throws -> SessionMessage {
        try PropertyListDecoder().decode(SessionMessage.self, from: data)
    }
}
