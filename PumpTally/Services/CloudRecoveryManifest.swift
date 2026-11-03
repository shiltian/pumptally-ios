import CloudKit
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

    func decodedRecords() throws -> [CKRecord] {
        guard version == 1 else { throw CloudRecoveryError.invalidReceipt }
        return try records.map {
            guard let record = try CloudRecordCodec.unarchiveFullRecord(from: $0) else {
                throw CloudRecoveryError.invalidReceipt
            }
            return record
        }
    }

    /// Overlay known business fields on current system fields. Unknown additive
    /// fields survive; omitted optional business fields are explicitly cleared.
    static func publicationRecord(_ chosen: CKRecord, existing: CKRecord?, generation: String) throws -> CKRecord {
        guard existing == nil || existing?.recordType == chosen.recordType else {
            throw CloudRecoveryError.verificationFailed
        }
        let result =
            existing?.copy() as? CKRecord
            ?? CKRecord(recordType: chosen.recordType, recordID: chosen.recordID)
        for key in try businessFields(for: chosen.recordType) { result[key] = chosen[key] }
        result[CloudSyncControl.businessGenerationField] = generation
        return result
    }

    static func matches(_ chosen: CKRecord, server: CKRecord, generation: String) throws -> Bool {
        guard chosen.recordID == server.recordID, chosen.recordType == server.recordType,
            server[CloudSyncControl.businessGenerationField] as? String == generation
        else { return false }
        for key in try businessFields(for: chosen.recordType) {
            let lhs = chosen[key]
            let rhs = server[key]
            switch (lhs, rhs) {
            case (nil, nil): break
            case (let lhs as Date, let rhs as Date):
                // CloudKit's wire timestamp uses the Unix epoch. Converting
                // epochs may change a Date's reference-epoch least-significant
                // bit without changing its representable wire instant.
                guard lhs.timeIntervalSince1970.bitPattern == rhs.timeIntervalSince1970.bitPattern else { return false }
            case (let lhs as Data, let rhs as Data):
                if key == CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements {
                    // JSON key order is not part of the measurement contract.
                    // Malformed server data is a mismatch to repair, never a
                    // reason to substitute or weaken the trusted source.
                    let expected = try JSONDecoder().decode(CloudMeasurementPayload.self, from: lhs)
                    guard let actual = try? JSONDecoder().decode(CloudMeasurementPayload.self, from: rhs),
                        expected == actual
                    else { return false }
                } else {
                    guard lhs == rhs else { return false }
                }
            case (let lhs as String, let rhs as String):
                guard lhs == rhs else { return false }
            case (let lhs as NSNumber, let rhs as NSNumber):
                if key == CloudRecordCodec.CloudFieldKey.Vehicle.year {
                    guard lhs.int64Value == rhs.int64Value else { return false }
                } else {
                    guard lhs.doubleValue.bitPattern == rhs.doubleValue.bitPattern else { return false }
                }
            default: return false
            }
        }
        return true
    }

    private static func businessFields(for type: String) throws -> [String] {
        switch type {
        case CloudRecordCodec.RecordType.vehicle:
            typealias F = CloudRecordCodec.CloudFieldKey.Vehicle
            return [
                F.id, F.name, F.make, F.model, F.year, F.unitSystemRaw, F.displayUnitSystemRaw, F.createdAt,
                F.modifiedAt,
            ]
        case CloudRecordCodec.RecordType.fuelingRecord:
            typealias F = CloudRecordCodec.CloudFieldKey.FuelingRecord
            return [
                F.id, F.date, F.odometer, F.pricePerFuelUnit, F.fuelAmount, F.totalCost, F.fillUpTypeRaw,
                F.notes, F.createdAt, F.modifiedAt, F.vehicleRef, F.measurements,
            ]
        default: throw CloudRecoveryError.invalidReceipt
        }
    }
}
