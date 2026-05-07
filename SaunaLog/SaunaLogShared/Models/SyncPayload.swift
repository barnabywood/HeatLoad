import Foundation

public struct SessionSyncPayload: Codable {
    public let session: HeatSession

    public init(session: HeatSession) {
        self.session = session
    }
}
