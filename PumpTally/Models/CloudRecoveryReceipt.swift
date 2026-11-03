import Foundation
import SwiftData

/// New V5 entity: existing business models are never rewritten to prepare a
/// replacement. Completed receipts retain the chosen snapshot and old inbox.
@Model
final class CloudRecoveryReceipt {
    @Attribute(.unique) var id: UUID
    var scope: String
    var accountID: String
    var phaseRaw: String
    var payload: Data
    var verifiedRecords: Data?
    var remoteBackup: Data?
    var retainedInbox: Data?

    init(id: UUID, scope: String, accountID: String, payload: Data) {
        self.id = id
        self.scope = scope
        self.accountID = accountID
        self.payload = payload
        phaseRaw = "prepared"
    }
}
