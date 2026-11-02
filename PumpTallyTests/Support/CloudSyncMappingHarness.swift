import CloudKit
import SwiftData
import XCTest

@testable import PumpTally

/// Compatibility assertions now exercise the staging components directly.
/// The production sync service accepts only its injected writer and values.
@MainActor
struct CloudSyncMappingHarness {
    typealias RemoteApplyResult = CloudReconciliationService.RemoteApplyResult
    private var recordCodec: CloudRecordCodec { CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID) }
    private var reconciliationService: CloudReconciliationService { CloudReconciliationService(codec: recordCodec) }
    func prepareUploadSnapshot(in context: ModelContext) throws -> [CKRecord] {
        try InitialSyncReconciler(codec: recordCodec).uploadSnapshot(in: context)
    }

    func replaceLocalData(
        vehicleCKRecords: [CKRecord], fuelingCKRecords: [CKRecord], context: ModelContext
    ) throws {
        let snapshot = try CloudSnapshotValidator().validate(
            vehicleRecords: vehicleCKRecords, fuelingRecordRecords: fuelingCKRecords)
        if context.hasChanges { try context.save() }
        do {
            try InitialSyncReconciler(codec: recordCodec).stageReplacement(snapshot, in: context)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func reconcileMerge(
        vehicleCKRecords: [CKRecord], fuelingCKRecords: [CKRecord], context: ModelContext
    ) throws -> [CKRecord] {
        try reconciliationService.reconcileMerge(
            vehicleCKRecords: vehicleCKRecords, fuelingCKRecords: fuelingCKRecords, context: context)
    }

    @discardableResult
    func applyRemoteChanges(changedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID], context: ModelContext) throws
        -> RemoteApplyResult
    {
        try reconciliationService.applyRemoteChanges(
            changedRecords: changedRecords,
            deletedRecordIDs: deletedRecordIDs,
            context: context
        )
    }

    func vehicleToCKRecord(_ vehicle: Vehicle) -> CKRecord {
        recordCodec.vehicleToCKRecord(vehicle)
    }

    func fuelingRecordToCKRecord(_ fuelingRecord: FuelingRecord, vehicleRecordID: CKRecord.ID) -> CKRecord {
        recordCodec.fuelingRecordToCKRecord(
            fuelingRecord,
            vehicleRecordID: vehicleRecordID
        )
    }
}

extension CloudReconciliationService {
    @discardableResult
    func applyRemoteChanges(
        changedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID], context: ModelContext
    ) throws -> RemoteApplyResult {
        do {
            let result = try stageRemoteChanges(
                changedRecords: changedRecords,
                deletedRecordIDs: deletedRecordIDs, context: context)
            if context.hasChanges { try context.save() }
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

}

extension FuelingRecordPersistenceService {
    func importRecords(_ records: [CSVImportRecordSnapshot], vehicleID: UUID, storageUnit: UnitSystem) async throws
        -> [UUID]
    {
        let plan = try await prepareImport(records, vehicleID: vehicleID, sourceUnit: storageUnit)
        return try await importRecords(plan: plan, duplicates: .importAll)
    }

    @MainActor
    init(container: ModelContainer, commit: @escaping OwnedModelStore.Commit = { try $0.modelContext.save() }) {
        self.init(writer: OwnedModelStore(container: container, commit: commit))
    }
}

extension VehiclePersistenceService {
    @MainActor
    init(container: ModelContainer, commit: @escaping OwnedModelStore.Commit = { try $0.modelContext.save() }) {
        self.init(writer: OwnedModelStore(container: container, commit: commit))
    }
}

extension StatisticsCachePersistenceService {
    @MainActor
    init(container: ModelContainer, commit: @escaping OwnedModelStore.Commit = { try $0.modelContext.save() }) {
        self.init(writer: OwnedModelStore(container: container, commit: commit))
    }
}

extension SyncPersistenceStore {
    convenience init(
        container: ModelContainer, commit: @escaping OwnedModelStore.Commit = { try $0.modelContext.save() }
    ) {
        self.init(writer: OwnedModelStore(container: container), commit: commit)
    }
}

extension ApplicationLifecycleCoordinator {
    convenience init(
        container: ModelContainer, syncService: any ApplicationSync,
        initializeStore: (@MainActor (ModelContainer) async throws -> Void)? = nil
    ) {
        self.init(
            writer: OwnedModelStore(container: container), syncService: syncService,
            initializeStore: initializeStore)
    }
}

/// A test-only checkpoint for observing UI state before an atomic background
/// save proceeds. Only the worker waits; the XCTest method awaits the command.
func observeOnMainActor(_ observation: @escaping @MainActor @Sendable () -> Void) throws {
    let completed = DispatchSemaphore(value: 0)
    Task { @MainActor in
        observation()
        completed.signal()
    }
    let result = completed.wait(timeout: .now() + 5)
    XCTAssertEqual(result, .success)
    guard result == .success else { throw CocoaError(.userCancelled) }
}
