import CloudKit
import SwiftData

/// User decisions about historical ambiguity are confined to this boundary.
enum SyncReviewService {
    struct Item: Identifiable, Sendable {
        let id: String
        let archivedPayload: Data
        let recordID: CKRecord.ID
        let isVehicle: Bool
        let title: String
        let incomingUnit: UnitSystem?
        let odometer: Double?
        let fuelAmount: Double?

        init(id: String, record: CKRecord, archivedPayload: Data) {
            self.id = id
            self.archivedPayload = archivedPayload
            recordID = record.recordID
            isVehicle = record.recordType == CloudRecordCodec.RecordType.vehicle
            if isVehicle {
                title = record[CloudRecordCodec.CloudFieldKey.Vehicle.name] as? String ?? String(localized: "Vehicle")
            } else {
                title =
                    (record[CloudRecordCodec.CloudFieldKey.FuelingRecord.date] as? Date)?.formatted(
                        date: .abbreviated, time: .shortened) ?? String(localized: "Fueling Record")
            }
            incomingUnit = (record[CloudRecordCodec.CloudFieldKey.Vehicle.unitSystemRaw] as? String).flatMap(
                UnitSystem.init(rawValue:))
            odometer = record[CloudRecordCodec.CloudFieldKey.FuelingRecord.odometer] as? Double
            fuelAmount = record[CloudRecordCodec.CloudFieldKey.FuelingRecord.fuelAmount] as? Double
        }
    }

    struct Diagnostic: Identifiable, Sendable {
        enum Reason: Equatable {
            case unreadableChange, malformedRecord, unsupportedFormat, missingVehicle

            var explanation: String {
                switch self {
                case .unreadableChange:
                    return String(localized: "This incoming change could not be read. Its original data has been kept.")
                case .malformedRecord:
                    return String(
                        localized: "This iCloud record has missing or invalid fields. Choosing units cannot repair it.")
                case .unsupportedFormat:
                    return String(
                        localized: "This change uses an unsupported format. Update PumpTally before trying again.")
                case .missingVehicle:
                    return String(
                        localized:
                            "The vehicle for this fueling record is not available on this device. Try syncing again.")
                }
            }
        }

        let id: String
        let title: String
        let reason: Reason
    }

    struct Assessment: Sendable {
        var unitConfirmations: [Item] = []
        var diagnostics: [Diagnostic] = []
        var legacyDeletionCount = 0
        var metrics = Metrics()
    }

    struct Metrics: Sendable {
        var inbox = PendingRemoteInbox.Metrics()
        var vehiclesRead = 0
        var fuelingRecordsRead = 0
    }

    private enum Disposition {
        case automatic
        case confirmUnits
        case diagnostic(Diagnostic.Reason)
    }

    static func items(in context: ModelContext) throws -> [Item] {
        try assessment(in: context).unitConfirmations
    }

    /// Read-only assessment. Ordinary inbox work is left to the sync engine;
    /// only resolvable unit ambiguity is presented as a user decision.
    static func assessment(in context: ModelContext) throws -> Assessment {
        try assessment(in: context, inbox: PendingRemoteInbox(in: context))
    }

    private static func assessment(in context: ModelContext, inbox: PendingRemoteInbox) throws -> Assessment {
        var result = Assessment()
        result.metrics.inbox = inbox.metrics
        result.legacyDeletionCount = try context.fetchCount(
            FetchDescriptor<SyncChange>(
                predicate: #Predicate { $0.operationRaw == "delete" && $0.originRaw == nil }))
        var incoming: [(item: Item, record: CKRecord)] = []
        for entry in inbox.entries {
            try Task.checkCancellation()
            do {
                guard case .modification(let record) = try entry.decoded.get() else { continue }
                incoming.append((Item(id: entry.key, record: record, archivedPayload: entry.archivedPayload), record))
            } catch {
                result.diagnostics.append(
                    Diagnostic(id: entry.key, title: String(localized: "Incoming Change"), reason: .unreadableChange))
            }
        }
        guard !incoming.isEmpty else { return result }

        var vehicleIDs: Set<UUID> = []
        var recordIDs: Set<UUID> = []
        for (_, record) in incoming {
            if record.recordType == CloudRecordCodec.RecordType.vehicle {
                if let id = UUID(uuidString: record.recordID.recordName) { vehicleIDs.insert(id) }
            } else if record.recordType == CloudRecordCodec.RecordType.fuelingRecord {
                if let name = record[CloudRecordCodec.CloudFieldKey.FuelingRecord.vehicleRef] as? String,
                    let owner = UUID(uuidString: name)
                {
                    vehicleIDs.insert(owner)
                }
                if let id = UUID(uuidString: record.recordID.recordName) { recordIDs.insert(id) }
            }
        }
        // Bound SQL membership lists, and never materialize unrelated history.
        var vehicles: [UUID: Vehicle] = [:]
        let owners = Array(vehicleIDs)
        for offset in stride(from: 0, to: owners.count, by: 256) {
            try Task.checkCancellation()
            let ids = Array(owners.dropFirst(offset).prefix(256))
            for vehicle in try context.fetch(FetchDescriptor<Vehicle>(predicate: #Predicate { ids.contains($0.id) })) {
                if vehicles[vehicle.id] == nil { vehicles[vehicle.id] = vehicle }
                result.metrics.vehiclesRead += 1
            }
        }
        var records: [UUID: FuelingRecord] = [:]
        let changed = Array(recordIDs)
        for offset in stride(from: 0, to: changed.count, by: 256) {
            try Task.checkCancellation()
            let ids = Array(changed.dropFirst(offset).prefix(256))
            for record in try context.fetch(
                FetchDescriptor<FuelingRecord>(predicate: #Predicate { ids.contains($0.id) }))
            {
                if records[record.id] == nil { records[record.id] = record }
                result.metrics.fuelingRecordsRead += 1
            }
        }
        let pendingVehicles = Set(incoming.filter { $0.item.isVehicle }.map { $0.record.recordID.recordName })
        for (item, record) in incoming {
            try Task.checkCancellation()
            let disposition: Disposition
            do {
                disposition = try Self.disposition(
                    of: record, vehicles: vehicles, records: records, pendingVehicles: pendingVehicles)
            } catch CloudMeasurementPayload.ValidationError.unresolvedUnits {
                disposition = .confirmUnits
            } catch CloudMeasurementPayload.ValidationError.unsupportedVersion {
                disposition = .diagnostic(.unsupportedFormat)
            } catch {
                disposition = .diagnostic(.malformedRecord)
            }
            switch disposition {
            case .automatic: break
            case .confirmUnits: result.unitConfirmations.append(item)
            case .diagnostic(let reason):
                result.diagnostics.append(Diagnostic(id: item.id, title: item.title, reason: reason))
            }
        }
        return result
    }

    private static func disposition(
        of record: CKRecord, vehicles: [UUID: Vehicle], records: [UUID: FuelingRecord], pendingVehicles: Set<String>
    ) throws -> Disposition {
        let validator = CloudSnapshotValidator()
        switch record.recordType {
        case CloudSyncControl.recordType:
            _ = try CloudSyncControl(record: record, zone: record.recordID.zoneID)
            return .automatic
        case CloudRecordCodec.RecordType.vehicle:
            let snapshot = try validator.validate(vehicleRecords: [record], fuelingRecordRecords: []).vehicles[0]
            guard let local = vehicles[snapshot.id], local.unitSystem != snapshot.unitSystem else { return .automatic }
            return .confirmUnits
        case CloudRecordCodec.RecordType.fuelingRecord:
            let ownerName = record[CloudRecordCodec.CloudFieldKey.FuelingRecord.vehicleRef] as? String ?? ""
            let ownerIDs = Set(UUID(uuidString: ownerName).map { [$0] } ?? [])
            let snapshot = try validator.validateFuelingRecords(from: [record], vehicleIDs: ownerIDs)[0]
            // Resolve the parent first. A pending parent may itself need a
            // decision or diagnosis; its children cannot safely be confirmed.
            guard !pendingVehicles.contains(ownerName) else { return .automatic }
            guard let owner = vehicles[snapshot.vehicleID] else { return .diagnostic(.missingVehicle) }
            _ = try CloudRecordCodec(zoneID: record.recordID.zoneID).decodeFuelingRecord(
                record, owner: owner, existing: records[snapshot.id])
            return .automatic
        default:
            return .diagnostic(.unsupportedFormat)
        }
    }

    static func resolveLegacyDeletions(apply: Bool, writer: OwnedModelStore) async throws {
        try await writer.transaction { actor in
            let context = actor.modelContext
            try CloudRecoveryStore.requireNoPendingRecovery(in: context)
            let pending = try context.fetch(
                FetchDescriptor<SyncChange>(
                    predicate: #Predicate {
                        $0.operationRaw == "delete" && $0.originRaw == nil
                    }))
            guard apply else {
                for entry in pending { context.delete(entry) }
                return
            }
            let vehicleIDs = pending.filter { $0.recordTypeRaw == "Vehicle" }.compactMap {
                UUID(uuidString: $0.recordName)
            }
            let recordIDs = pending.filter { $0.recordTypeRaw == "FuelingRecord" }.compactMap {
                UUID(uuidString: $0.recordName)
            }
            let deletedOwners = Set(vehicleIDs)
            for entry in pending { entry.originRaw = "confirmed" }
            var affectedOwners: [UUID: Vehicle] = [:]
            if !recordIDs.isEmpty {
                for record in try context.fetch(
                    FetchDescriptor<FuelingRecord>(predicate: #Predicate { recordIDs.contains($0.id) }))
                where !deletedOwners.contains(record.vehicle.id) {
                    affectedOwners[record.vehicle.id] = record.vehicle
                    context.delete(record)
                }
            }
            if !affectedOwners.isEmpty {
                context.processPendingChanges()
                for vehicle in affectedOwners.values { StatisticsCacheService.refresh(for: vehicle) }
            }
            if !vehicleIDs.isEmpty {
                for vehicle in try context.fetch(
                    FetchDescriptor<Vehicle>(predicate: #Predicate { vehicleIDs.contains($0.id) }))
                {
                    for child in vehicle.fuelingRecords ?? [] {
                        try SyncChangeJournal.enqueue(child, operation: .delete, in: context)
                    }
                    context.delete(vehicle)
                }
            }
        }
    }

    static func confirm(_ item: Item, sourceUnit: UnitSystem, writer: OwnedModelStore) async throws {
        try await writer.transaction { actor in
            let context = actor.modelContext
            try CloudRecoveryStore.requireNoPendingRecovery(in: context)
            let inbox = try PendingRemoteInbox(in: context)
            guard
                let current = try assessment(in: context, inbox: inbox).unitConfirmations.first(where: {
                    $0.id == item.id
                }),
                current.archivedPayload == item.archivedPayload
            else { throw FuelingRecordEditingError.recordChanged }
            guard let entry = inbox.entries.first(where: { $0.key == item.id }),
                case .modification(let record) = try entry.decoded.get()
            else { throw FuelingRecordEditingError.recordChanged }
            let codec = CloudRecordCodec(zoneID: record.recordID.zoneID)
            if item.isVehicle {
                let snapshot = try CloudSnapshotValidator().validate(vehicleRecords: [record], fuelingRecordRecords: [])
                    .vehicles[0]
                let id = snapshot.id
                guard
                    let vehicle = try context.fetch(FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == id }))
                        .first
                else { throw FuelingRecordEditingError.recordUnavailable }
                guard sourceUnit == snapshot.unitSystem else {
                    throw CloudMeasurementPayload.ValidationError.unresolvedUnits
                }
                try VehiclePersistenceService.stageLegacyStorageUnit(
                    vehicle: vehicle, metadata: snapshot, inboxKey: item.id, context: context)
                return
            }
            let confirmed = try CloudMeasurementPayload.confirmedLegacyRecord(record, unit: sourceUnit)
            let result = try CloudReconciliationService(codec: codec).stageRemoteChanges(
                changedRecords: [confirmed], deletedRecordIDs: [], context: context)
            guard result.deferredRecordNames.isEmpty, result.unresolvedChildIDs.isEmpty else {
                throw CloudMeasurementPayload.ValidationError.unresolvedUnits
            }
            let key = item.id
            for entry in try context.fetch(
                FetchDescriptor<PendingRemoteChange>(predicate: #Predicate { $0.key == key }))
            {
                context.delete(entry)
            }
            if let id = UUID(uuidString: record.recordID.recordName),
                let local = try context.fetch(FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.id == id }))
                    .first
            {
                try SyncChangeJournal.enqueue(local, in: context)
            }
        }
    }
}
