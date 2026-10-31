import XCTest
import CloudKit
import SwiftData
@testable import PumpTally

/// Tests for the CloudKit conflict-resolution and reconciliation logic.
///
/// These exercise the pure decision helper plus the two seams that previously
/// caused silent data loss:
///  - `applyRemoteChanges` (incremental pull): ordering + last-writer-wins.
///  - `reconcileMerge` (first-time "Merge Both"): uploading local-newer records.
///
/// Everything here runs against an in-memory SwiftData store and constructs
/// CKRecords directly, so no network or iCloud account is required.
@MainActor
final class CloudSyncServiceTests: XCTestCase {

    // MARK: - Fixtures

    private let t1 = Date(timeIntervalSince1970: 1_000_000)
    private let t2 = Date(timeIntervalSince1970: 2_000_000)
    private let t3 = Date(timeIntervalSince1970: 3_000_000)

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: SchemaV3.self)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func makeService() -> CloudSyncService {
        CloudSyncService(stateManager: SyncStateManager())
    }

    private func makeVehicle(
        id: UUID = UUID(),
        name: String,
        createdAt: Date,
        modifiedAt: Date?
    ) -> Vehicle {
        let v = Vehicle(id: id, name: name, createdAt: createdAt)
        v.modifiedAt = modifiedAt
        return v
    }

    private func makeRecord(
        id: UUID = UUID(),
        odometer: Double,
        createdAt: Date,
        modifiedAt: Date?,
        vehicle: Vehicle
    ) -> FuelingRecord {
        let r = FuelingRecord(
            id: id,
            date: createdAt,
            odometer: odometer,
            pricePerFuelUnit: 3.0,
            fuelAmount: 10.0,
            totalCost: 30.0,
            fillUpType: .full,
            createdAt: createdAt,
            vehicle: vehicle
        )
        r.modifiedAt = modifiedAt
        return r
    }

    private func assertVehicleWirePayload(
        _ record: CKRecord,
        matches vehicle: Vehicle,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(record.recordType, "Vehicle", file: file, line: line)
        XCTAssertEqual(record.recordID.recordName, vehicle.id.uuidString, file: file, line: line)
        XCTAssertEqual(record.recordID.zoneID.zoneName, "FuelioZone", file: file, line: line)
        XCTAssertEqual(record.recordID.zoneID.ownerName, CKCurrentUserDefaultName, file: file, line: line)
        XCTAssertNil(record.parent, file: file, line: line)
        XCTAssertEqual(
            Set(record.allKeys()),
            Set([
                "vehicleID",
                "name",
                "make",
                "model",
                "year",
                "unitSystemRaw",
                "vehicleCreatedAt",
                "vehicleModifiedAt"
            ]),
            file: file,
            line: line
        )
        XCTAssertEqual(record["vehicleID"] as? String, vehicle.id.uuidString, file: file, line: line)
        XCTAssertEqual(record["name"] as? String, vehicle.name, file: file, line: line)
        XCTAssertEqual(record["make"] as? String, vehicle.make, file: file, line: line)
        XCTAssertEqual(record["model"] as? String, vehicle.model, file: file, line: line)
        XCTAssertEqual(record["year"] as? Int, vehicle.year, file: file, line: line)
        XCTAssertEqual(record["unitSystemRaw"] as? String, vehicle.unitSystemRaw, file: file, line: line)
        XCTAssertEqual(record["vehicleCreatedAt"] as? Date, vehicle.createdAt, file: file, line: line)
        XCTAssertEqual(record["vehicleModifiedAt"] as? Date, vehicle.modifiedAt, file: file, line: line)
        XCTAssertFalse(record.allKeys().contains { record[$0] is CKRecord.Reference }, file: file, line: line)
    }

    private func assertFuelingRecordWirePayload(
        _ record: CKRecord,
        matches fuelingRecord: FuelingRecord,
        vehicleID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(record.recordType, "FuelingRecord", file: file, line: line)
        XCTAssertEqual(record.recordID.recordName, fuelingRecord.id.uuidString, file: file, line: line)
        XCTAssertEqual(record.recordID.zoneID.zoneName, "FuelioZone", file: file, line: line)
        XCTAssertEqual(record.recordID.zoneID.ownerName, CKCurrentUserDefaultName, file: file, line: line)
        XCTAssertNil(record.parent, file: file, line: line)
        XCTAssertEqual(
            Set(record.allKeys()),
            Set([
                "fuelingRecordID",
                "date",
                "odometer",
                "pricePerFuelUnit",
                "fuelAmount",
                "totalCost",
                "fillUpTypeRaw",
                "notes",
                "fuelingCreatedAt",
                "fuelingModifiedAt",
                "vehicleOwnerID"
            ]),
            file: file,
            line: line
        )
        XCTAssertEqual(record["fuelingRecordID"] as? String, fuelingRecord.id.uuidString, file: file, line: line)
        XCTAssertEqual(record["date"] as? Date, fuelingRecord.date, file: file, line: line)
        XCTAssertEqual(record["odometer"] as? Double, fuelingRecord.odometer, file: file, line: line)
        XCTAssertEqual(record["pricePerFuelUnit"] as? Double, fuelingRecord.pricePerFuelUnit, file: file, line: line)
        XCTAssertEqual(record["fuelAmount"] as? Double, fuelingRecord.fuelAmount, file: file, line: line)
        XCTAssertEqual(record["totalCost"] as? Double, fuelingRecord.totalCost, file: file, line: line)
        XCTAssertEqual(record["fillUpTypeRaw"] as? String, fuelingRecord.fillUpTypeRaw, file: file, line: line)
        XCTAssertEqual(record["notes"] as? String, fuelingRecord.notes, file: file, line: line)
        XCTAssertEqual(record["fuelingCreatedAt"] as? Date, fuelingRecord.createdAt, file: file, line: line)
        XCTAssertEqual(record["fuelingModifiedAt"] as? Date, fuelingRecord.modifiedAt, file: file, line: line)
        XCTAssertEqual(record["vehicleOwnerID"] as? String, vehicleID.uuidString, file: file, line: line)
        XCTAssertFalse(record.allKeys().contains { record[$0] is CKRecord.Reference }, file: file, line: line)
    }

    private func assertReplacementRejectedWithoutMutation(
        vehicleRecords: [CKRecord],
        fuelingRecords: [CKRecord],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let service = makeService()
        let context = try makeContext()
        let localVehicle = makeVehicle(name: "Irreplaceable", createdAt: t1, modifiedAt: t2)
        let localRecord = makeRecord(
            odometer: 321,
            createdAt: t1,
            modifiedAt: t2,
            vehicle: localVehicle
        )
        context.insert(localVehicle)
        context.insert(localRecord)
        try context.save()

        XCTAssertThrowsError(
            try service.replaceLocalData(
                vehicleCKRecords: vehicleRecords,
                fuelingCKRecords: fuelingRecords,
                context: context
            ),
            file: file,
            line: line
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Vehicle>()).map(\.id),
            [localVehicle.id],
            file: file,
            line: line
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FuelingRecord>()).map(\.id),
            [localRecord.id],
            file: file,
            line: line
        )
    }

    // MARK: - CloudKit wire-format hard gate

    func testVehicleToCKRecord_matchesExactWireContract() {
        let service = makeService()
        let vehicle = Vehicle(
            id: UUID(uuidString: "135A3623-A1B2-4C3D-8E9F-0123456789AB")!,
            name: "Wire Vehicle",
            make: "Honda",
            model: "Civic",
            year: 2024,
            createdAt: t1,
            unitSystem: .metric
        )
        vehicle.modifiedAt = t2

        assertVehicleWirePayload(service.vehicleToCKRecord(vehicle), matches: vehicle)
    }

    func testFuelingRecordToCKRecord_matchesExactWireContract() {
        let service = makeService()
        let vehicle = Vehicle(
            id: UUID(uuidString: "246B4734-B2C3-4D5E-9F01-123456789ABC")!,
            name: "Wire Vehicle",
            createdAt: t1,
            unitSystem: .imperial
        )
        let fuelingRecord = FuelingRecord(
            id: UUID(uuidString: "357C5845-C3D4-4E6F-A012-23456789ABCD")!,
            date: t2,
            odometer: 12_345.678,
            pricePerFuelUnit: 3.459,
            fuelAmount: 10.125,
            totalCost: 35.02,
            fillUpType: .partial,
            notes: "Exact payload",
            createdAt: t1,
            vehicle: vehicle
        )
        fuelingRecord.modifiedAt = t3

        let vehicleRecordID = service.vehicleToCKRecord(vehicle).recordID
        assertFuelingRecordWirePayload(
            service.fuelingRecordToCKRecord(fuelingRecord, vehicleRecordID: vehicleRecordID),
            matches: fuelingRecord,
            vehicleID: vehicle.id
        )
    }

    func testFullCKRecordArchiveRoundTripsRootRecord() throws {
        let service = makeService()
        let vehicle = makeVehicle(name: "Archived Vehicle", createdAt: t1, modifiedAt: t2)
        let original = service.vehicleToCKRecord(vehicle)

        let data = try CloudRecordCodec.archiveFullRecord(original)
        let restored = try XCTUnwrap(CloudRecordCodec.unarchiveFullRecord(from: data))

        XCTAssertEqual(restored.recordType, original.recordType)
        XCTAssertEqual(restored.recordID, original.recordID)
        XCTAssertEqual(restored["vehicleID"] as? String, vehicle.id.uuidString)
        XCTAssertEqual(restored["name"] as? String, "Archived Vehicle")
        XCTAssertEqual(restored["vehicleModifiedAt"] as? Date, t2)
    }

    func testCKRecordMapping_omitsNilOptionalFields() {
        let service = makeService()
        let vehicle = makeVehicle(name: "Minimal Vehicle", createdAt: t1, modifiedAt: nil)
        let fuelingRecord = makeRecord(
            odometer: 10,
            createdAt: t1,
            modifiedAt: nil,
            vehicle: vehicle
        )

        let vehicleCKRecord = service.vehicleToCKRecord(vehicle)
        XCTAssertEqual(
            Set(vehicleCKRecord.allKeys()),
            Set(["vehicleID", "name", "unitSystemRaw", "vehicleCreatedAt"])
        )

        let fuelingCKRecord = service.fuelingRecordToCKRecord(
            fuelingRecord,
            vehicleRecordID: vehicleCKRecord.recordID
        )
        XCTAssertEqual(
            Set(fuelingCKRecord.allKeys()),
            Set([
                "fuelingRecordID",
                "date",
                "odometer",
                "pricePerFuelUnit",
                "fuelAmount",
                "totalCost",
                "fillUpTypeRaw",
                "fuelingCreatedAt",
                "vehicleOwnerID"
            ])
        )
    }

    // MARK: - Transactional cloud replacement

    func testReplaceLocalData_validSnapshotReplacesEverything() throws {
        let service = makeService()
        let context = try makeContext()

        let oldVehicle = makeVehicle(name: "Local Only", createdAt: t1, modifiedAt: t1)
        context.insert(oldVehicle)
        context.insert(makeRecord(odometer: 100, createdAt: t1, modifiedAt: t1, vehicle: oldVehicle))
        try context.save()

        let cloudVehicle = Vehicle(
            name: "Cloud Car",
            make: "Toyota",
            model: "Prius",
            year: 2025,
            createdAt: t2,
            unitSystem: .metric
        )
        cloudVehicle.modifiedAt = t3
        let cloudRecord = makeRecord(odometer: 500, createdAt: t2, modifiedAt: t3, vehicle: cloudVehicle)
        cloudRecord.date = t3
        cloudRecord.pricePerFuelUnit = 1.789
        cloudRecord.fuelAmount = 42.125
        cloudRecord.totalCost = 75.35
        cloudRecord.fillUpType = .partial
        cloudRecord.notes = "Preserve every cloud field"
        let cloudVehicleCK = service.vehicleToCKRecord(cloudVehicle)
        let cloudRecordCK = service.fuelingRecordToCKRecord(
            cloudRecord,
            vehicleRecordID: cloudVehicleCK.recordID
        )

        try service.replaceLocalData(
            vehicleCKRecords: [cloudVehicleCK],
            fuelingCKRecords: [cloudRecordCK],
            context: context
        )

        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        let records = try context.fetch(FetchDescriptor<FuelingRecord>())
        XCTAssertEqual(vehicles.map(\.id), [cloudVehicle.id])
        XCTAssertEqual(vehicles.first?.name, "Cloud Car")
        XCTAssertEqual(vehicles.first?.make, "Toyota")
        XCTAssertEqual(vehicles.first?.model, "Prius")
        XCTAssertEqual(vehicles.first?.year, 2025)
        XCTAssertEqual(vehicles.first?.unitSystem, .metric)
        XCTAssertEqual(vehicles.first?.createdAt, t2)
        XCTAssertEqual(vehicles.first?.modifiedAt, t3)
        XCTAssertEqual(records.map(\.id), [cloudRecord.id])
        XCTAssertEqual(records.first?.date, t3)
        XCTAssertEqual(records.first?.odometer, 500)
        XCTAssertEqual(records.first?.pricePerFuelUnit, 1.789)
        XCTAssertEqual(records.first?.fuelAmount, 42.125)
        XCTAssertEqual(records.first?.totalCost, 75.35)
        XCTAssertEqual(records.first?.fillUpType, .partial)
        XCTAssertEqual(records.first?.notes, "Preserve every cloud field")
        XCTAssertEqual(records.first?.createdAt, t2)
        XCTAssertEqual(records.first?.modifiedAt, t3)
        XCTAssertEqual(records.first?.vehicle.id, cloudVehicle.id)

        let freshContext = ModelContext(context.container)
        freshContext.autosaveEnabled = false
        XCTAssertEqual(try freshContext.fetch(FetchDescriptor<Vehicle>()).map(\.id), [cloudVehicle.id])
        XCTAssertEqual(try freshContext.fetch(FetchDescriptor<FuelingRecord>()).map(\.id), [cloudRecord.id])
    }

    func testReplaceLocalData_invalidSnapshotPreservesLocalStore() throws {
        let service = makeService()
        let context = try makeContext()

        let localVehicle = makeVehicle(name: "Irreplaceable Local", createdAt: t1, modifiedAt: t2)
        context.insert(localVehicle)
        let localRecord = makeRecord(odometer: 321, createdAt: t1, modifiedAt: t2, vehicle: localVehicle)
        context.insert(localRecord)
        try context.save()

        // Structurally valid record, but its parent is absent from the proposed
        // cloud snapshot. Validation must fail before deleting local models.
        let absentVehicle = makeVehicle(name: "Missing Parent", createdAt: t1, modifiedAt: t1)
        let orphan = makeRecord(odometer: 999, createdAt: t1, modifiedAt: t1, vehicle: absentVehicle)
        let orphanCK = service.fuelingRecordToCKRecord(
            orphan,
            vehicleRecordID: service.vehicleToCKRecord(absentVehicle).recordID
        )

        XCTAssertThrowsError(
            try service.replaceLocalData(
                vehicleCKRecords: [],
                fuelingCKRecords: [orphanCK],
                context: context
            )
        )

        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        let records = try context.fetch(FetchDescriptor<FuelingRecord>())
        XCTAssertEqual(vehicles.map(\.id), [localVehicle.id])
        XCTAssertEqual(vehicles.first?.name, "Irreplaceable Local")
        XCTAssertEqual(records.map(\.id), [localRecord.id])
        XCTAssertEqual(records.first?.odometer, 321)
    }

    func testReplaceLocalData_rejectsMalformedVehicleBeforeMutation() throws {
        let service = makeService()
        let vehicle = makeVehicle(name: "Malformed", createdAt: t1, modifiedAt: t2)
        let malformed = service.vehicleToCKRecord(vehicle)
        malformed[CloudSyncService.CloudFieldKey.Vehicle.name] = nil

        try assertReplacementRejectedWithoutMutation(
            vehicleRecords: [malformed],
            fuelingRecords: []
        )
    }

    func testReplaceLocalData_rejectsDuplicateVehicleBeforeMutation() throws {
        let service = makeService()
        let vehicle = makeVehicle(name: "Duplicate", createdAt: t1, modifiedAt: t2)
        let duplicate = service.vehicleToCKRecord(vehicle)

        try assertReplacementRejectedWithoutMutation(
            vehicleRecords: [duplicate, duplicate],
            fuelingRecords: []
        )
    }

    func testReplaceLocalData_rejectsMalformedFuelingRecordBeforeMutation() throws {
        let service = makeService()
        let vehicle = makeVehicle(name: "Parent", createdAt: t1, modifiedAt: t2)
        let record = makeRecord(odometer: 100, createdAt: t1, modifiedAt: t2, vehicle: vehicle)
        let vehicleCK = service.vehicleToCKRecord(vehicle)
        let malformed = service.fuelingRecordToCKRecord(record, vehicleRecordID: vehicleCK.recordID)
        malformed[CloudSyncService.CloudFieldKey.FuelingRecord.totalCost] = nil

        try assertReplacementRejectedWithoutMutation(
            vehicleRecords: [vehicleCK],
            fuelingRecords: [malformed]
        )
    }

    func testReplaceLocalData_rejectsDuplicateFuelingRecordBeforeMutation() throws {
        let service = makeService()
        let vehicle = makeVehicle(name: "Parent", createdAt: t1, modifiedAt: t2)
        let record = makeRecord(odometer: 100, createdAt: t1, modifiedAt: t2, vehicle: vehicle)
        let vehicleCK = service.vehicleToCKRecord(vehicle)
        let duplicate = service.fuelingRecordToCKRecord(record, vehicleRecordID: vehicleCK.recordID)

        try assertReplacementRejectedWithoutMutation(
            vehicleRecords: [vehicleCK],
            fuelingRecords: [duplicate, duplicate]
        )
    }

    func testReplaceLocalData_rejectsMismatchedRecordNameBeforeMutation() throws {
        let service = makeService()
        let vehicle = makeVehicle(name: "Mismatch", createdAt: t1, modifiedAt: t2)
        let mismatched = service.vehicleToCKRecord(vehicle)
        mismatched[CloudSyncService.CloudFieldKey.Vehicle.id] = UUID().uuidString

        try assertReplacementRejectedWithoutMutation(
            vehicleRecords: [mismatched],
            fuelingRecords: []
        )
    }

    func testReplaceLocalData_rejectsNonFiniteFuelValueBeforeMutation() throws {
        let service = makeService()
        let vehicle = makeVehicle(name: "Parent", createdAt: t1, modifiedAt: t2)
        let record = makeRecord(odometer: 100, createdAt: t1, modifiedAt: t2, vehicle: vehicle)
        let vehicleCK = service.vehicleToCKRecord(vehicle)
        let nonFinite = service.fuelingRecordToCKRecord(
            record,
            vehicleRecordID: vehicleCK.recordID
        )
        nonFinite[CloudSyncService.CloudFieldKey.FuelingRecord.fuelAmount] = Double.infinity

        try assertReplacementRejectedWithoutMutation(
            vehicleRecords: [vehicleCK],
            fuelingRecords: [nonFinite]
        )
    }

    // MARK: - resolveConflict (pure decision, incl. nil-modifiedAt legacy data)

    func testResolveConflict_cloudModifiedNewer_cloudWins() {
        XCTAssertEqual(
            CloudSyncService.resolveConflict(cloudModifiedAt: t3, cloudCreatedAt: t1, localModifiedAt: t2, localCreatedAt: t1),
            .cloud
        )
    }

    func testResolveConflict_localModifiedNewer_localWins() {
        XCTAssertEqual(
            CloudSyncService.resolveConflict(cloudModifiedAt: t2, cloudCreatedAt: t1, localModifiedAt: t3, localCreatedAt: t1),
            .local
        )
    }

    func testResolveConflict_equalModified_isTie() {
        XCTAssertEqual(
            CloudSyncService.resolveConflict(cloudModifiedAt: t2, cloudCreatedAt: t1, localModifiedAt: t2, localCreatedAt: t1),
            .tie
        )
    }

    func testResolveConflict_nilModified_fallsBackToCreatedAt() {
        XCTAssertEqual(
            CloudSyncService.resolveConflict(cloudModifiedAt: nil, cloudCreatedAt: t2, localModifiedAt: nil, localCreatedAt: t1),
            .cloud
        )
        XCTAssertEqual(
            CloudSyncService.resolveConflict(cloudModifiedAt: nil, cloudCreatedAt: t1, localModifiedAt: nil, localCreatedAt: t1),
            .tie
        )
    }

    func testResolveConflict_legacyLocalNilModified_vs_cloudEdit_cloudWins() {
        // Legacy local record (never edited → nil modifiedAt) vs a genuine remote edit.
        XCTAssertEqual(
            CloudSyncService.resolveConflict(cloudModifiedAt: t2, cloudCreatedAt: t1, localModifiedAt: nil, localCreatedAt: t1),
            .cloud
        )
    }

    func testResolveConflict_localEdit_vs_legacyCloudNilModified_localWins() {
        XCTAssertEqual(
            CloudSyncService.resolveConflict(cloudModifiedAt: nil, cloudCreatedAt: t1, localModifiedAt: t2, localCreatedAt: t1),
            .local
        )
    }

    func testResolveConflict_allNil_isTie() {
        XCTAssertEqual(
            CloudSyncService.resolveConflict(cloudModifiedAt: nil, cloudCreatedAt: nil, localModifiedAt: nil, localCreatedAt: nil),
            .tie
        )
    }

    // MARK: - #3: pull ordering must not drop records

    func testApplyRemoteChanges_recordBeforeItsNewVehicle_isNotDropped() throws {
        let service = makeService()
        let context = try makeContext()

        // A brand-new vehicle + its record, neither present locally yet.
        let vehicle = makeVehicle(name: "New Car", createdAt: t1, modifiedAt: t1)
        let record = makeRecord(odometer: 100, createdAt: t1, modifiedAt: t1, vehicle: vehicle)

        let vehicleCK = service.vehicleToCKRecord(vehicle)
        let recordCK = service.fuelingRecordToCKRecord(record, vehicleRecordID: vehicleCK.recordID)

        // Deliberately place the fueling record BEFORE its parent vehicle.
        try service.applyRemoteChanges(
            changedRecords: [recordCK, vehicleCK],
            deletedRecordIDs: [],
            context: context
        )

        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        let records = try context.fetch(FetchDescriptor<FuelingRecord>())
        XCTAssertEqual(vehicles.count, 1)
        XCTAssertEqual(records.count, 1, "Record must survive even when it precedes its new vehicle in the change set")
        XCTAssertEqual(records.first?.vehicle.id, vehicle.id)
    }

    func testApplyRemoteChanges_persistsBeforeReturning() throws {
        let service = makeService()
        let context = try makeContext()
        let vehicle = makeVehicle(name: "Persisted Remote", createdAt: t1, modifiedAt: t2)

        try service.applyRemoteChanges(
            changedRecords: [service.vehicleToCKRecord(vehicle)],
            deletedRecordIDs: [],
            context: context
        )

        let freshContext = ModelContext(context.container)
        freshContext.autosaveEnabled = false
        let persistedVehicles = try freshContext.fetch(FetchDescriptor<Vehicle>())
        XCTAssertEqual(persistedVehicles.map(\.id), [vehicle.id])
    }

    // MARK: - #2: last-writer-wins on incremental pull

    func testApplyRemoteChanges_olderCloudDoesNotClobberNewerLocal() throws {
        let service = makeService()
        let context = try makeContext()

        let local = Vehicle(
            name: "Local Name",
            make: "Local Make",
            model: "Local Model",
            year: 2024,
            createdAt: t1,
            unitSystem: .metric
        )
        local.modifiedAt = t2
        context.insert(local)
        try context.save()

        // Older cloud copy (t1) with a different name.
        let cloudCopy = makeVehicle(id: local.id, name: "Old Cloud Name", createdAt: t1, modifiedAt: t1)
        let cloudCK = service.vehicleToCKRecord(cloudCopy)

        let result = try service.applyRemoteChanges(changedRecords: [cloudCK], deletedRecordIDs: [], context: context)

        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        XCTAssertEqual(vehicles.count, 1)
        XCTAssertEqual(vehicles.first?.name, "Local Name", "Older cloud copy must not overwrite the newer local edit")

        // The local winner must be queued for upload (with local payload) so the
        // stale cloud copy is corrected instead of leaving devices divergent.
        let uploaded = result.recordsToUpload.first { $0.recordID.recordName == local.id.uuidString }
        XCTAssertNotNil(uploaded, "Local-newer vehicle must be pushed back during pull")
        assertVehicleWirePayload(try XCTUnwrap(uploaded), matches: local)

        let freshContext = ModelContext(context.container)
        freshContext.autosaveEnabled = false
        let queued = try freshContext.fetch(FetchDescriptor<SyncChange>())
        XCTAssertTrue(
            queued.contains {
                $0.key == "Vehicle:\(local.id.uuidString)"
                    && $0.operationRaw == SyncChangeJournal.Operation.save.rawValue
            },
            "The winning local record and its durable upload request must commit together"
        )
    }

    func testApplyRemoteChanges_newerCloudOverwritesLocal() throws {
        let service = makeService()
        let context = try makeContext()

        let local = makeVehicle(name: "Local Name", createdAt: t1, modifiedAt: t1)
        context.insert(local)
        try context.save()

        let cloudCopy = Vehicle(
            id: local.id,
            name: "Newer Cloud Name",
            make: "Cloud Make",
            model: "Cloud Model",
            year: 2026,
            createdAt: t1,
            unitSystem: .metric
        )
        cloudCopy.modifiedAt = t3
        let cloudCK = service.vehicleToCKRecord(cloudCopy)

        let result = try service.applyRemoteChanges(changedRecords: [cloudCK], deletedRecordIDs: [], context: context)

        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        XCTAssertEqual(vehicles.first?.name, "Newer Cloud Name")
        XCTAssertEqual(vehicles.first?.make, "Cloud Make")
        XCTAssertEqual(vehicles.first?.model, "Cloud Model")
        XCTAssertEqual(vehicles.first?.year, 2026)
        XCTAssertEqual(vehicles.first?.unitSystem, .metric)
        XCTAssertEqual(vehicles.first?.modifiedAt, t3)
        XCTAssertTrue(result.recordsToUpload.isEmpty, "When the cloud copy wins there is nothing to push back")
    }

    func testApplyRemoteChanges_legacyLocalNilModified_acceptsCloudEdit() throws {
        let service = makeService()
        let context = try makeContext()

        // Legacy record migrated from V1: modifiedAt == nil.
        let local = makeVehicle(name: "Legacy Local", createdAt: t1, modifiedAt: nil)
        context.insert(local)
        try context.save()

        let cloudCopy = makeVehicle(id: local.id, name: "Cloud Edit", createdAt: t1, modifiedAt: t2)
        let cloudCK = service.vehicleToCKRecord(cloudCopy)

        try service.applyRemoteChanges(changedRecords: [cloudCK], deletedRecordIDs: [], context: context)

        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        XCTAssertEqual(vehicles.first?.name, "Cloud Edit", "A genuine remote edit must win over a legacy nil-modifiedAt local copy")
    }

    func testApplyRemoteChanges_fuelingRecord_olderCloudDoesNotClobberNewerLocal_andIsQueued() throws {
        let service = makeService()
        let context = try makeContext()

        let vehicle = makeVehicle(name: "Car", createdAt: t1, modifiedAt: t1)
        context.insert(vehicle)
        let local = makeRecord(odometer: 500, createdAt: t1, modifiedAt: t2, vehicle: vehicle)
        local.date = t2
        local.pricePerFuelUnit = 4.125
        local.fuelAmount = 11.75
        local.totalCost = 48.47
        local.fillUpType = .partial
        local.notes = "Local winner"
        context.insert(local)
        try context.save()

        // Older cloud copy of the same fueling record with a different odometer.
        let cloudCopy = makeRecord(id: local.id, odometer: 999, createdAt: t1, modifiedAt: t1, vehicle: vehicle)
        let vehicleRecordID = service.vehicleToCKRecord(vehicle).recordID
        let cloudCK = service.fuelingRecordToCKRecord(cloudCopy, vehicleRecordID: vehicleRecordID)

        let result = try service.applyRemoteChanges(changedRecords: [cloudCK], deletedRecordIDs: [], context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<FuelingRecord>()).first?.odometer, 500,
                       "Older cloud fueling record must not overwrite the newer local edit")
        let uploaded = result.recordsToUpload.first { $0.recordID.recordName == local.id.uuidString }
        XCTAssertNotNil(uploaded, "Local-newer fueling record must be pushed back during pull")
        assertFuelingRecordWirePayload(
            try XCTUnwrap(uploaded),
            matches: local,
            vehicleID: vehicle.id
        )
    }

    func testApplyRemoteChanges_fuelingRecord_newerCloudOverwritesLocal() throws {
        let service = makeService()
        let context = try makeContext()

        let vehicle = makeVehicle(name: "Car", createdAt: t1, modifiedAt: t1)
        context.insert(vehicle)
        let local = makeRecord(odometer: 500, createdAt: t1, modifiedAt: t1, vehicle: vehicle)
        context.insert(local)
        try context.save()

        let cloudCopy = makeRecord(id: local.id, odometer: 777, createdAt: t1, modifiedAt: t3, vehicle: vehicle)
        cloudCopy.date = t2
        cloudCopy.pricePerFuelUnit = 4.999
        cloudCopy.fuelAmount = 9.25
        cloudCopy.totalCost = 46.24
        cloudCopy.fillUpType = .reset
        cloudCopy.notes = "Cloud winner"
        let vehicleRecordID = service.vehicleToCKRecord(vehicle).recordID
        let cloudCK = service.fuelingRecordToCKRecord(cloudCopy, vehicleRecordID: vehicleRecordID)

        let result = try service.applyRemoteChanges(changedRecords: [cloudCK], deletedRecordIDs: [], context: context)

        let updated = try context.fetch(FetchDescriptor<FuelingRecord>()).first
        XCTAssertEqual(updated?.date, t2)
        XCTAssertEqual(updated?.odometer, 777,
                       "Newer cloud fueling record must overwrite the older local copy")
        XCTAssertEqual(updated?.pricePerFuelUnit, 4.999)
        XCTAssertEqual(updated?.fuelAmount, 9.25)
        XCTAssertEqual(updated?.totalCost, 46.24)
        XCTAssertEqual(updated?.fillUpType, .reset)
        XCTAssertEqual(updated?.notes, "Cloud winner")
        XCTAssertEqual(updated?.modifiedAt, t3)
        XCTAssertTrue(result.recordsToUpload.isEmpty, "When the cloud copy wins there is nothing to push back")
    }

    func testApplyRemoteChanges_tieLeavesLocalUntouchedAndQueuesNothing() throws {
        let service = makeService()
        let context = try makeContext()
        let local = makeVehicle(name: "Local Tie", createdAt: t1, modifiedAt: t2)
        context.insert(local)
        try context.save()

        let cloud = makeVehicle(
            id: local.id,
            name: "Cloud Tie",
            createdAt: t1,
            modifiedAt: t2
        )
        let result = try service.applyRemoteChanges(
            changedRecords: [service.vehicleToCKRecord(cloud)],
            deletedRecordIDs: [],
            context: context
        )

        XCTAssertEqual(local.name, "Local Tie")
        XCTAssertTrue(result.recordsToUpload.isEmpty)
    }

    // MARK: - Unresolvable-parent children are reported, not silently dropped

    func testApplyRemoteChanges_recordWithUnresolvableParent_isSkippedAndReported() throws {
        let service = makeService()
        let context = try makeContext()

        // A fueling record whose parent vehicle is neither present locally nor
        // in this change set (mimics the parent's fetch failing during a pull).
        let absentVehicle = makeVehicle(name: "Absent", createdAt: t1, modifiedAt: t1)
        let orphan = makeRecord(odometer: 100, createdAt: t1, modifiedAt: t1, vehicle: absentVehicle)
        let orphanCK = service.fuelingRecordToCKRecord(
            orphan,
            vehicleRecordID: CKRecord.ID(recordName: absentVehicle.id.uuidString)
        )

        let result = try service.applyRemoteChanges(changedRecords: [orphanCK], deletedRecordIDs: [], context: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<FuelingRecord>()).isEmpty,
                      "A record whose parent cannot be resolved must not be inserted")
        XCTAssertEqual(result.unresolvedChildIDs, [orphan.id],
                       "The unresolved child must be reported so the caller can hold the change token and retry")
    }

    // MARK: - Deletions follow an explicit delete-wins policy

    func testApplyRemoteChanges_remoteDeletion_removesLocalRecordEvenIfNewer_deleteWins() throws {
        let service = makeService()
        let context = try makeContext()

        let vehicle = makeVehicle(name: "Car", createdAt: t1, modifiedAt: t1)
        context.insert(vehicle)
        // Local record carries a NEWER edit (t3) than the cloud ever saw.
        let local = makeRecord(odometer: 500, createdAt: t1, modifiedAt: t3, vehicle: vehicle)
        context.insert(local)
        try context.save()

        let deletionID = CKRecord.ID(recordName: local.id.uuidString)
        try service.applyRemoteChanges(changedRecords: [], deletedRecordIDs: [deletionID], context: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<FuelingRecord>()).isEmpty,
                      "Delete-wins policy: a remote deletion removes the local record even when it has a newer edit")
    }

    func testApplyRemoteChanges_remoteVehicleDeletion_cascadesAndPersists() throws {
        let service = makeService()
        let context = try makeContext()
        let vehicle = makeVehicle(name: "Deleted Car", createdAt: t1, modifiedAt: t3)
        context.insert(vehicle)
        context.insert(makeRecord(odometer: 500, createdAt: t1, modifiedAt: t3, vehicle: vehicle))
        try context.save()

        try service.applyRemoteChanges(
            changedRecords: [],
            deletedRecordIDs: [service.vehicleToCKRecord(vehicle).recordID],
            context: context
        )

        let freshContext = ModelContext(context.container)
        freshContext.autosaveEnabled = false
        XCTAssertTrue(try freshContext.fetch(FetchDescriptor<Vehicle>()).isEmpty)
        XCTAssertTrue(try freshContext.fetch(FetchDescriptor<FuelingRecord>()).isEmpty)
    }

    // MARK: - Pull orchestration: the change token advances only when the window applied safely

    /// End-to-end (network-free) check that the pull sequence
    /// `applyRemoteChanges` → `commitPullOutcome` holds the stored change token
    /// when a child's parent could not be resolved, so the record is retried
    /// rather than skipped forever.
    func testPullOrchestration_unresolvedChild_holdsStoredToken() throws {
        let stateManager = SyncStateManager()
        stateManager.serverChangeToken = nil // known clean starting state
        let service = CloudSyncService(stateManager: stateManager)
        let context = try makeContext()

        // A fueling record whose parent vehicle is absent from both the local
        // store and the change set (mimics the parent's fetch failing).
        let absentVehicle = makeVehicle(name: "Absent", createdAt: t1, modifiedAt: t1)
        let orphan = makeRecord(odometer: 100, createdAt: t1, modifiedAt: t1, vehicle: absentVehicle)
        let orphanCK = service.fuelingRecordToCKRecord(
            orphan,
            vehicleRecordID: CKRecord.ID(recordName: absentVehicle.id.uuidString)
        )

        // Drive the same post-fetch sequence pullRemoteChanges uses.
        let applyResult = try service.applyRemoteChanges(
            changedRecords: [orphanCK],
            deletedRecordIDs: [],
            context: context
        )
        let didAdvance = service.commitPullOutcome(
            fetchedToken: nil,
            hadFetchFailure: false,
            unresolvedChildIDs: applyResult.unresolvedChildIDs
        )

        XCTAssertEqual(applyResult.unresolvedChildIDs, [orphan.id])
        XCTAssertFalse(didAdvance, "Token must not advance while a child's parent is unresolved")
        XCTAssertNil(stateManager.serverChangeToken, "Stored change token must remain unchanged for unresolved children")
        XCTAssertEqual(stateManager.syncStatus, .error(String(localized: "Pull incomplete — will retry")))
    }

    func testCommitPullOutcome_advancesOnlyWhenWindowFullyApplied() {
        let stateManager = SyncStateManager()
        stateManager.serverChangeToken = nil
        let service = CloudSyncService(stateManager: stateManager)

        // Held on unresolved children, on fetch failure, or on both.
        XCTAssertFalse(service.commitPullOutcome(fetchedToken: nil, hadFetchFailure: false, unresolvedChildIDs: [UUID()]))
        XCTAssertNil(stateManager.serverChangeToken)
        XCTAssertFalse(service.commitPullOutcome(fetchedToken: nil, hadFetchFailure: true, unresolvedChildIDs: []))
        XCTAssertFalse(service.commitPullOutcome(fetchedToken: nil, hadFetchFailure: true, unresolvedChildIDs: [UUID()]))

        // Advances only when the window applied cleanly.
        XCTAssertTrue(service.commitPullOutcome(fetchedToken: nil, hadFetchFailure: false, unresolvedChildIDs: []))
        XCTAssertEqual(stateManager.syncStatus, .synced)
    }

    // MARK: - #1: merge must upload local-newer matched records

    func testReconcileMerge_localNewerRecordsAreUploaded_andLocalPreserved() throws {
        let service = makeService()
        let context = try makeContext()

        let vehicle = makeVehicle(name: "Local Car", createdAt: t1, modifiedAt: t2)
        context.insert(vehicle)
        let record = makeRecord(odometer: 100, createdAt: t1, modifiedAt: t2, vehicle: vehicle)
        context.insert(record)
        try context.save()

        // Older cloud copies of the same records.
        let cloudVehicle = makeVehicle(id: vehicle.id, name: "Old Cloud Car", createdAt: t1, modifiedAt: t1)
        let cloudVehicleCK = service.vehicleToCKRecord(cloudVehicle)
        let cloudRecord = makeRecord(id: record.id, odometer: 999, createdAt: t1, modifiedAt: t1, vehicle: cloudVehicle)
        let cloudRecordCK = service.fuelingRecordToCKRecord(cloudRecord, vehicleRecordID: cloudVehicleCK.recordID)

        let uploads = try service.reconcileMerge(
            vehicleCKRecords: [cloudVehicleCK],
            fuelingCKRecords: [cloudRecordCK],
            context: context
        )

        // The uploaded CKRecords must carry the LOCAL (newer) payload, not just
        // a matching record ID — re-uploading the older cloud copy would pass an
        // ID-only assertion while silently overwriting the newer data.
        let uploadedVehicle = uploads.first { $0.recordID.recordName == vehicle.id.uuidString }
        XCTAssertNotNil(uploadedVehicle, "Local-newer vehicle must be queued for upload")
        XCTAssertEqual(uploadedVehicle?[CloudSyncService.CloudFieldKey.Vehicle.name] as? String, "Local Car")
        XCTAssertEqual(uploadedVehicle?[CloudSyncService.CloudFieldKey.Vehicle.modifiedAt] as? Date, t2)

        let uploadedRecord = uploads.first { $0.recordID.recordName == record.id.uuidString }
        XCTAssertNotNil(uploadedRecord, "Local-newer record must be queued for upload")
        XCTAssertEqual(uploadedRecord?[CloudSyncService.CloudFieldKey.FuelingRecord.odometer] as? Double, 100,
                       "Uploaded record must have the local odometer (100), not the older cloud value (999)")
        XCTAssertEqual(uploadedRecord?[CloudSyncService.CloudFieldKey.FuelingRecord.modifiedAt] as? Date, t2)
        XCTAssertEqual(uploadedRecord?[CloudSyncService.CloudFieldKey.FuelingRecord.vehicleRef] as? String, vehicle.id.uuidString,
                       "Uploaded record must still reference its parent vehicle")

        // Local (newer) values must be preserved, not overwritten by the older cloud copy.
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Vehicle>()).first?.name, "Local Car")
        XCTAssertEqual(try context.fetch(FetchDescriptor<FuelingRecord>()).first?.odometer, 100)
    }

    func testReconcileMerge_cloudNewerUpdatesLocal_andIsNotUploaded() throws {
        let service = makeService()
        let context = try makeContext()

        let vehicle = makeVehicle(name: "Local Car", createdAt: t1, modifiedAt: t1)
        context.insert(vehicle)
        try context.save()

        let cloudVehicle = makeVehicle(id: vehicle.id, name: "Newer Cloud Car", createdAt: t1, modifiedAt: t3)
        let cloudVehicleCK = service.vehicleToCKRecord(cloudVehicle)

        let uploads = try service.reconcileMerge(
            vehicleCKRecords: [cloudVehicleCK],
            fuelingCKRecords: [],
            context: context
        )

        XCTAssertFalse(uploads.contains { $0.recordID.recordName == vehicle.id.uuidString })
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Vehicle>()).first?.name, "Newer Cloud Car")
    }

    func testReconcileMerge_cloudNewerFuelingRecordUpdatesEveryMutableField() throws {
        let service = makeService()
        let context = try makeContext()
        let vehicle = makeVehicle(name: "Car", createdAt: t1, modifiedAt: t1)
        context.insert(vehicle)
        let localRecord = makeRecord(odometer: 100, createdAt: t1, modifiedAt: t1, vehicle: vehicle)
        context.insert(localRecord)
        try context.save()

        let cloudRecord = makeRecord(
            id: localRecord.id,
            odometer: 250,
            createdAt: t1,
            modifiedAt: t3,
            vehicle: vehicle
        )
        cloudRecord.date = t2
        cloudRecord.pricePerFuelUnit = 5.125
        cloudRecord.fuelAmount = 8.75
        cloudRecord.totalCost = 44.84
        cloudRecord.fillUpType = .reset
        cloudRecord.notes = "Merged cloud edit"
        let vehicleCK = service.vehicleToCKRecord(vehicle)

        let uploads = try service.reconcileMerge(
            vehicleCKRecords: [vehicleCK],
            fuelingCKRecords: [
                service.fuelingRecordToCKRecord(
                    cloudRecord,
                    vehicleRecordID: vehicleCK.recordID
                )
            ],
            context: context
        )

        XCTAssertTrue(uploads.isEmpty)
        XCTAssertEqual(localRecord.date, t2)
        XCTAssertEqual(localRecord.odometer, 250)
        XCTAssertEqual(localRecord.pricePerFuelUnit, 5.125)
        XCTAssertEqual(localRecord.fuelAmount, 8.75)
        XCTAssertEqual(localRecord.totalCost, 44.84)
        XCTAssertEqual(localRecord.fillUpType, .reset)
        XCTAssertEqual(localRecord.notes, "Merged cloud edit")
        XCTAssertEqual(localRecord.modifiedAt, t3)
    }

    func testReconcileMerge_tie_neitherUpdatesNorUploads() throws {
        let service = makeService()
        let context = try makeContext()

        let vehicle = makeVehicle(name: "Local Car", createdAt: t1, modifiedAt: t2)
        context.insert(vehicle)
        try context.save()

        // Identical timestamps → tie → leave both sides untouched.
        let cloudVehicle = makeVehicle(id: vehicle.id, name: "Cloud Car", createdAt: t1, modifiedAt: t2)
        let cloudVehicleCK = service.vehicleToCKRecord(cloudVehicle)

        let uploads = try service.reconcileMerge(
            vehicleCKRecords: [cloudVehicleCK],
            fuelingCKRecords: [],
            context: context
        )

        XCTAssertTrue(uploads.isEmpty, "A tie must not trigger an upload")
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Vehicle>()).first?.name, "Local Car", "A tie must not overwrite local")
    }

    func testReconcileMerge_localOnlyRecordsAreUploaded() throws {
        let service = makeService()
        let context = try makeContext()

        let vehicle = Vehicle(
            name: "Only Local",
            make: "Local Make",
            model: "Local Model",
            year: 2023,
            createdAt: t1,
            unitSystem: .metric
        )
        vehicle.modifiedAt = t2
        context.insert(vehicle)
        let record = makeRecord(odometer: 123, createdAt: t1, modifiedAt: t2, vehicle: vehicle)
        record.notes = "Local-only record"
        context.insert(record)
        try context.save()

        let uploads = try service.reconcileMerge(vehicleCKRecords: [], fuelingCKRecords: [], context: context)
        assertVehicleWirePayload(
            try XCTUnwrap(uploads.first { $0.recordID.recordName == vehicle.id.uuidString }),
            matches: vehicle
        )
        assertFuelingRecordWirePayload(
            try XCTUnwrap(uploads.first { $0.recordID.recordName == record.id.uuidString }),
            matches: record,
            vehicleID: vehicle.id
        )
    }

    func testReconcileMerge_cloudOnlyRecordsAreInsertedLocally() throws {
        let service = makeService()
        let context = try makeContext()

        let cloudVehicle = makeVehicle(name: "Cloud Only", createdAt: t1, modifiedAt: t1)
        let cloudRecord = makeRecord(
            odometer: 345,
            createdAt: t1,
            modifiedAt: t2,
            vehicle: cloudVehicle
        )
        let cloudVehicleCK = service.vehicleToCKRecord(cloudVehicle)
        let cloudRecordCK = service.fuelingRecordToCKRecord(
            cloudRecord,
            vehicleRecordID: cloudVehicleCK.recordID
        )

        let uploads = try service.reconcileMerge(
            vehicleCKRecords: [cloudVehicleCK],
            fuelingCKRecords: [cloudRecordCK],
            context: context
        )

        XCTAssertFalse(uploads.contains { $0.recordID.recordName == cloudVehicle.id.uuidString })
        try context.save()
        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        let records = try context.fetch(FetchDescriptor<FuelingRecord>())
        XCTAssertEqual(vehicles.count, 1)
        XCTAssertEqual(vehicles.first?.name, "Cloud Only")
        XCTAssertEqual(records.map(\.id), [cloudRecord.id])
        XCTAssertEqual(records.first?.vehicle.id, cloudVehicle.id)
    }

    func testReconcileMerge_cloudOnlyOrphanIsSilentlySkipped() throws {
        let service = makeService()
        let context = try makeContext()
        let absentVehicle = makeVehicle(name: "Absent", createdAt: t1, modifiedAt: t1)
        let orphan = makeRecord(odometer: 100, createdAt: t1, modifiedAt: t1, vehicle: absentVehicle)
        let orphanCK = service.fuelingRecordToCKRecord(
            orphan,
            vehicleRecordID: service.vehicleToCKRecord(absentVehicle).recordID
        )

        let uploads = try service.reconcileMerge(
            vehicleCKRecords: [],
            fuelingCKRecords: [orphanCK],
            context: context
        )

        XCTAssertTrue(uploads.isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<FuelingRecord>()).isEmpty)
        XCTAssertFalse(context.hasChanges)
    }

    func testReconcileMerge_leavesSaveOwnershipWithCaller() throws {
        let service = makeService()
        let context = try makeContext()
        let cloudVehicle = makeVehicle(name: "Unsaved Merge", createdAt: t1, modifiedAt: t2)

        _ = try service.reconcileMerge(
            vehicleCKRecords: [service.vehicleToCKRecord(cloudVehicle)],
            fuelingCKRecords: [],
            context: context
        )

        XCTAssertTrue(context.hasChanges)
        let freshContext = ModelContext(context.container)
        freshContext.autosaveEnabled = false
        XCTAssertTrue(try freshContext.fetch(FetchDescriptor<Vehicle>()).isEmpty)

        try context.save()
        XCTAssertEqual(
            try freshContext.fetch(FetchDescriptor<Vehicle>()).map(\.id),
            [cloudVehicle.id]
        )
    }

    // MARK: - Automatic push echo suppression

    func testRemoteApplySaveRemainsSuppressedAfterDebounce() {
        XCTAssertFalse(
            CloudSyncService.shouldScheduleAutomaticPush(
                wasSuppressedWhenSaved: true,
                isCurrentlySuppressed: false
            )
        )
    }

    func testOrdinaryLocalSaveSchedulesAutomaticPush() {
        XCTAssertTrue(
            CloudSyncService.shouldScheduleAutomaticPush(
                wasSuppressedWhenSaved: false,
                isCurrentlySuppressed: false
            )
        )
    }

    func testCurrentSuppressionPreventsAutomaticPush() {
        XCTAssertFalse(
            CloudSyncService.shouldScheduleAutomaticPush(
                wasSuppressedWhenSaved: false,
                isCurrentlySuppressed: true
            )
        )
        XCTAssertFalse(
            CloudSyncService.shouldScheduleAutomaticPush(
                wasSuppressedWhenSaved: true,
                isCurrentlySuppressed: true
            )
        )
    }
}
