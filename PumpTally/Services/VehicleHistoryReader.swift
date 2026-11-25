import Combine
import Foundation
import SwiftData
import os

/// History and recovery reads use fresh contexts on SwiftData's native executor.
@ModelActor
actor ModelStoreReader {
    /// Keep the whole read on a detached worker, including native executor
    /// shortcuts that can otherwise execute synchronous work on the caller.
    static func read<Result: Sendable>(
        container: ModelContainer,
        _ operation: @escaping @Sendable (isolated ModelStoreReader) throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            let reader = ModelStoreReader(modelContainer: container)
            return try await reader.perform(operation)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func perform<Result: Sendable>(
        _ operation: @Sendable (isolated ModelStoreReader) throws -> Result
    ) rethrows -> Result {
        modelContext.autosaveEnabled = false
        return try operation(self)
    }
}

extension ModelStoreReader {
    func readHistory(vehicleID: UUID) throws -> VehicleHistorySource {
        try Task.checkCancellation()
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
            predicate: #Predicate { $0.vehicleRelationship?.id == vehicleID },
            sortBy: [SortDescriptor(\.date), SortDescriptor(\.odometer), SortDescriptor(\.id)])
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
    private var index = HistoryRecordsIndex(chronologicalRecords: [], displayUnit: .imperial)
    private var latest: FuelingHistoryRecord?
    private var latestEfficiency = 0.0
    private var chartInput: ChartInput?
    private var presentation: VehicleHistoryPresentation?
    private var lastQuery: Query?
    private var matchingPositions: [Int] = []
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
            try await ModelStoreReader.read(container: container) { reader in
                try reader.readHistory(vehicleID: vehicleID)
            }
        }
    }

    func refresh(
        revision: UInt64, saveGeneration: UInt64 = 0, format: MetricEfficiencyFormat, calendar: Calendar = .current
    ) async throws -> VehicleHistoryPresentation
    {
        try Task.checkCancellation()
        if sourceRevision != revision || sourceSaveGeneration != saveGeneration {
            let attempt = UUID()
            activeRead = attempt
            let loaded = try await load()
            try Task.checkCancellation()
            guard activeRead == attempt else { throw CancellationError() }
            guard Set(loaded.records.lazy.map(\.id)).count == loaded.records.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var ordered = loaded.records
            if zip(ordered, ordered.dropFirst()).contains(where: { FuelingHistoryRecord.precedes($1, $0) }) {
                ordered.sort(by: FuelingHistoryRecord.precedes)
            }
            try Task.checkCancellation()
            sourceLoads += 1
            source = VehicleHistorySource(
                records: ordered, displayUnit: loaded.displayUnit, averageEfficiency: loaded.averageEfficiency)
            sourceRevision = revision
            sourceSaveGeneration = saveGeneration
            version = UUID()
            index = HistoryRecordsIndex(chronologicalRecords: ordered, displayUnit: loaded.displayUnit)
            latest = ordered.last
            latestEfficiency = latest?.cachedEfficiency ?? 0
            // Preserve the last-card fallback for legacy incomplete caches,
            // using the already ordered values rather than a relationship scan.
            if let latest, latest.cachedEfficiency == nil, !latest.hasIntervalCache,
                ordered.count > 1
            {
                let previous = ordered[ordered.count - 2]
                latestEfficiency =
                    FuelEfficiencyPolicy.rawEfficiency(
                        distanceDriven: latest.values.odometer - previous.values.odometer,
                        fuelAmount: latest.values.fuelAmount, currentFillUpType: latest.values.fillUpType,
                        previousFillUpType: previous.values.fillUpType, previousIsFirstRecord: ordered.count == 2) ?? 0
            }
            lastQuery = nil
            matchingPositions = []
        } else if let presentation, presentation.chartData.metricEfficiencyFormat == format,
            presentation.chartData.calendar == calendar
        {
            return presentation
        }
        guard let source else { throw FuelingRecordEditingError.recordUnavailable }
        let input = ChartInput(
            records: source.records.map { record in
                ChartRecordSnapshot(
                    id: record.id, date: record.values.date,
                    odometer: record.values.odometer,
                    cachedEfficiency: record.cachedEfficiency.map {
                        source.displayUnit.efficiencyValue($0, from: record.storageUnit)
                    }, fuelAmount: record.values.fuelAmount, totalCost: record.values.totalCost,
                    pricePerFuelUnit: source.displayUnit.priceValue(
                        record.values.pricePerFuelUnit, from: record.storageUnit))
            }, unitSystem: source.displayUnit, rawAverageEfficiency: source.averageEfficiency,
            metricEfficiencyFormat: format, calendar: calendar)
        let chartData: PrecomputedChartData
        if let presentation, input == chartInput {
            chartData = presentation.chartData
        } else {
            chartData = PrecomputedChartData(chronologicalInput: input)
            chartInput = input
            chartPreparations += 1
        }
        let refreshed = VehicleHistoryPresentation(
            version: version, recordCount: source.records.count, latestRecord: latest,
            latestEfficiency: latestEfficiency, chartData: chartData)
        presentation = refreshed
        return refreshed
    }

    func page(version: UUID, query: Query, offset: Int) throws -> VehicleHistoryPage? {
        try Task.checkCancellation()
        guard version == self.version, let source, offset >= 0 else { return nil }
        if query != lastQuery {
            matchingPositions = index.positions(searchText: query.searchText, sortOrder: query.sortOrder)
            lastQuery = query
            queryEvaluations += 1
        }
        return VehicleHistoryPage(
            records: matchingPositions.dropFirst(offset).prefix(VehicleHistoryPage.size).map { source.records[$0] },
            totalCount: matchingPositions.count)
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
        saveObserver = ModelStoreChange.publisher(in: container, affecting: ["Vehicle", "FuelingRecord"])
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
            if presentation?.version != result.version || presentation?.chartData.metricEfficiencyFormat != format
                || presentation?.chartData.calendar != result.chartData.calendar
            {
                presentation = result
            }
            if failed { failed = false }
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
}
