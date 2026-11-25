import Foundation

/// Immutable data selected by the user, including original inbound bytes and
/// exact journal generations. Native record archives preserve numeric precision.
struct CloudRecoveryManifest: Codable, Sendable {
    struct JournalEntry: Codable, Sendable {
        let key: String
        let recordName: String
        let recordType: String
        let operation: String
        let generation: String
        let createdAt: Date
        let origin: String?
    }
    struct InboxEntry: Codable, Sendable {
        let key: String
        let data: Data
    }
    let version: Int
    let previousGeneration: String
    let records: [Data]
    let journal: [JournalEntry]
    let inbox: [InboxEntry]
}
