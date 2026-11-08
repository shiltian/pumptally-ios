import Combine
import Foundation
import SwiftData
import os

/// Each reload has a fresh, read-only context on SwiftData's serial executor.
/// Enumerating releases managed batches; only value snapshots leave this actor.
actor VehicleHistoryReader: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor

    private init(container: ModelContainer) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelContainer = container
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    /// Keep the whole read on a detached worker, including native executor
    /// shortcuts that can otherwise execute synchronous work on the caller.
    static func read<Result: Sendable>(
        container: ModelContainer,
        _ operation: @escaping @Sendable (isolated VehicleHistoryReader) throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            let reader = VehicleHistoryReader(container: container)
            return try await reader.perform(operation)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func perform<Result: Sendable>(
        _ operation: @Sendable (isolated VehicleHistoryReader) throws -> Result
    ) rethrows -> Result { try operation(self) }

    func read(vehicleID: UUID) throws -> VehicleHistorySource {
        try Task.checkCancellation()
        modelContext.autosaveEnabled = false
        var ownerQuery = FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == vehicleID })
        ownerQuery.fetchLimit = 1
        guard let vehicle = try modelContext.fetch(ownerQuery).first else {
            throw FuelingRecordEditingError.recordUnavailable
        }
        let storageUnit = vehicle.unitSystem
        let displayUnit = vehicle.displayUnitSystem
        let averageEfficiency = displayUnit.efficiencyValue(vehicle.cachedAverageEfficiency ?? 0, from: storageUnit)
        var records: [FuelingHistoryRecord] = []
        let query = FetchDescriptor<FuelingRecord>(
            predicate: #Predicate { $0.vehicle.id == vehicleID },
            sortBy: [SortDescriptor(\.date), SortDescriptor(\.odometer)])
        try modelContext.enumerate(query, batchSize: 256) { record in
            try Task.checkCancellation()
            records.append(FuelingHistoryRecord(record: record, storageUnit: storageUnit))
        }
        return VehicleHistorySource(
            records: records, displayUnit: displayUnit, averageEfficiency: averageEfficiency)
    }
}

/// Owns the immutable catalog and indexes off the UI actor. Search, sorting and
/// pagination reuse it without another store read or managed-model projection.
actor VehicleHistoryRepository {
    typealias Load = @Sendable () async throws -> VehicleHistorySource
    private let load: Load
    private var sourceRevision: UInt64?
    private var sourceSaveGeneration: UInt64?
    private var version = UUID()
    private var activeRead = UUID()
    private var source: VehicleHistorySource?
    private var recordsByID: [UUID: FuelingHistoryRecord] = [:]
    private var index: HistoryRecordsIndex?
    private var latest: FuelingHistoryRecord?
    private var latestEfficiency = 0.0
    private var chartInput: ChartInput?
    private var chartData: PrecomputedChartData?
    private var lastQuery: Query?
    private var matchingIDs: [UUID] = []
    private(set) var sourceLoads = 0
    private(set) var chartPreparations = 0
    private(set) var queryEvaluations = 0

    struct Query: Equatable, Sendable {
        let searchText: String
        let sortOrder: HistorySortOrder
    }

    init(load: @escaping Load) { self.load = load }

    init(container: ModelContainer, vehicleID: UUID) {
        load = {
            try await VehicleHistoryReader.read(container: container) { reader in
                try reader.read(vehicleID: vehicleID)
            }
        }
    }

    func refresh(revision: UInt64, saveGeneration: UInt64 = 0, format: MetricEfficiencyFormat) async throws
        -> VehicleHistoryPresentation
    {
        if sourceRevision != revision || sourceSaveGeneration != saveGeneration {
            let attempt = UUID()
            activeRead = attempt
            let loaded = try await load()
            try Task.checkCancellation()
            guard activeRead == attempt else { throw CancellationError() }
            var indexed: [UUID: FuelingHistoryRecord] = [:]
            for record in loaded.records {
                guard indexed.updateValue(record, forKey: record.id) == nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            let preparedIndex = HistoryRecordsIndex(
                records: loaded.records.map {
                    HistoryRecordSnapshot(
                        id: $0.id, date: $0.values.date, totalCost: $0.values.totalCost,
                        odometer: loaded.displayUnit.distanceValue($0.values.odometer, from: $0.storageUnit),
                        notes: $0.values.notes)
                })
            try Task.checkCancellation()
            sourceLoads += 1
            source = loaded
            sourceRevision = revision
            sourceSaveGeneration = saveGeneration
            version = UUID()
            recordsByID = indexed
            index = preparedIndex
            let ids = preparedIndex.recordIDs(searchText: "", sortOrder: .dateAscending)
            latest = ids.last.flatMap { recordsByID[$0] }
            latestEfficiency = latest?.cachedEfficiency ?? 0
            // Preserve the last-card fallback for legacy incomplete caches,
            // using the already ordered values rather than a relationship scan.
            if let latest, latest.cachedEfficiency == nil, !latest.hasIntervalCache,
                ids.count > 1, let previous = recordsByID[ids[ids.count - 2]]
            {
                latestEfficiency =
                    FuelEfficiencyPolicy.rawEfficiency(
                        distanceDriven: latest.values.odometer - previous.values.odometer,
                        fuelAmount: latest.values.fuelAmount, currentFillUpType: latest.values.fillUpType,
                        previousFillUpType: previous.values.fillUpType, previousIsFirstRecord: ids.count == 2) ?? 0
            }
            lastQuery = nil
            matchingIDs = []
        }
        guard let source else { throw FuelingRecordEditingError.recordUnavailable }
        let input = ChartInput(
            records: source.records.map { record in
                ChartRecordSnapshot(
                    id: record.id, date: record.values.date,
                    odometer: source.displayUnit.distanceValue(record.values.odometer, from: record.storageUnit),
                    cachedEfficiency: record.cachedEfficiency.map {
                        source.displayUnit.efficiencyValue($0, from: record.storageUnit)
                    }, totalCost: record.values.totalCost,
                    pricePerFuelUnit: source.displayUnit.priceValue(
                        record.values.pricePerFuelUnit, from: record.storageUnit))
            }, unitSystem: source.displayUnit, rawAverageEfficiency: source.averageEfficiency,
            metricEfficiencyFormat: format)
        if input != chartInput {
            chartData = PrecomputedChartData(input: input)
            chartInput = input
            chartPreparations += 1
        }
        return VehicleHistoryPresentation(
            version: version, recordCount: recordsByID.count, latestRecord: latest,
            latestEfficiency: latestEfficiency, chartData: chartData!)
    }

    func page(version: UUID, query: Query, offset: Int) throws -> VehicleHistoryPage? {
        try Task.checkCancellation()
        guard version == self.version, let index, offset >= 0 else { return nil }
        if query != lastQuery {
            matchingIDs = index.recordIDs(searchText: query.searchText, sortOrder: query.sortOrder)
            lastQuery = query
            queryEvaluations += 1
        }
        return VehicleHistoryPage(
            records: matchingIDs.dropFirst(offset).prefix(VehicleHistoryPage.size).compactMap { recordsByID[$0] },
            totalCount: matchingIDs.count)
    }
}

/// A small UI-facing state owner. Its task identity contains only a source
/// revision and presentation settings, never a projection of the history.
@MainActor
final class VehicleHistoryModel: ObservableObject {
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var presentation: VehicleHistoryPresentation?
    @Published private(set) var failed = false
    private let repository: VehicleHistoryRepository
    private var saveObserver: AnyCancellable?
    private var reloadAttempt = UUID()
    private var retryEpoch: UInt64 = 0
    private let saveGeneration = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var presentationGeneration: UInt64?
    private static let logger = Logger(subsystem: "me.tianshilei.fuelio", category: "VehicleHistory")

    init(container: ModelContainer, vehicleID: UUID, repository: VehicleHistoryRepository? = nil) {
        self.repository = repository ?? VehicleHistoryRepository(container: container, vehicleID: vehicleID)
        saveObserver = NotificationCenter.default.publisher(for: ModelContext.didSave)
            .filter { Self.isRelevant($0, container: container) }
            .map { [generation = saveGeneration] _ in generation.withLock { $0 &+= 1 } }
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.revision &+= 1 }
    }

    func retry() {
        retryEpoch &+= 1
        revision &+= 1
    }

    func reload(revision: UInt64, format: MetricEfficiencyFormat) async {
        let attempt = UUID()
        reloadAttempt = attempt
        let generation = saveGeneration.withLock { $0 }
        do {
            let result = try await repository.refresh(revision: retryEpoch, saveGeneration: generation, format: format)
            guard !Task.isCancelled, self.revision == revision, reloadAttempt == attempt,
                saveGeneration.withLock({ $0 }) == generation
            else { return }
            presentationGeneration = generation
            presentation = result
            failed = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, self.revision == revision, reloadAttempt == attempt,
                saveGeneration.withLock({ $0 }) == generation
            else { return }
            Self.logger.error("Failed to read vehicle history: \(error)")
            failed = true
        }
    }

    func page(version: UUID, query: VehicleHistoryRepository.Query, offset: Int) async -> VehicleHistoryPage? {
        guard presentation?.version == version, presentationGeneration == saveGeneration.withLock({ $0 }) else {
            return nil
        }
        let page = try? await repository.page(version: version, query: query, offset: offset)
        guard !Task.isCancelled, presentation?.version == version,
            presentationGeneration == saveGeneration.withLock({ $0 })
        else { return nil }
        return page
    }

    /// Inspect the saving context only on its posting executor, and forward a
    /// value signal to MainActor. Journal/checkpoint saves do not reload views.
    nonisolated private static func isRelevant(_ notification: Notification, container: ModelContainer) -> Bool {
        guard let context = notification.object as? ModelContext, context.container === container else { return false }
        let invalidationKey = ModelContext.NotificationKey.invalidatedAllIdentifiers
        if let invalidated = notification.userInfo?[invalidationKey.rawValue] ?? notification.userInfo?[invalidationKey]
        {
            if let all = invalidated as? Bool {
                if all { return true }
            } else if let ids = invalidated as? [PersistentIdentifier] {
                if !ids.isEmpty { return true }
            } else {
                return true
            }
        }
        var recognized = false
        for key in [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers] {
            guard let value = notification.userInfo?[key.rawValue] ?? notification.userInfo?[key] else { continue }
            let ids: [PersistentIdentifier]
            if let array = value as? [PersistentIdentifier] {
                ids = array
            } else if let set = value as? Set<PersistentIdentifier> {
                ids = Array(set)
            } else {
                return true
            }
            recognized = true
            if ids.contains(where: { $0.entityName == "Vehicle" || $0.entityName == "FuelingRecord" }) { return true }
        }
        // Older runtimes may omit identifier details. Refresh conservatively.
        return !recognized
    }
}
