import Foundation
import SwiftData

/// Cache repair shares the actor and transaction boundary used by local writes.
/// Only IDs cross suspension points; each vehicle is reread before its repair.
struct StatisticsCachePersistenceService: Sendable {
    private let store: OwnedModelStore

    init(writer: OwnedModelStore) { store = writer }

    @discardableResult
    func rebuildIfNeeded() async throws -> Int {
        try Task.checkCancellation()
        let ids = try await store.transaction { actor in
            let context = actor.modelContext
            return try context.fetch(FetchDescriptor<Vehicle>(sortBy: [SortDescriptor(\.createdAt)])).map(\.id)
        }
        var rebuilt = 0
        for id in ids {
            try Task.checkCancellation()
            if try await rebuildIfNeeded(vehicleID: id) { rebuilt += 1 }
            await Task.yield()
        }
        return rebuilt
    }

    /// A fresh transaction skips deleted vehicles and caches already maintained
    /// by an intervening local edit or sync event. Counting does not hydrate an
    /// already-cached vehicle's complete history.
    @discardableResult
    func rebuildIfNeeded(vehicleID: UUID) async throws -> Bool {
        try await store.transaction { actor in
            let context = actor.modelContext
            var query = FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == vehicleID })
            query.fetchLimit = 1
            guard let vehicle = try context.fetch(query).first else { return false }
            let count = try context.fetchCount(
                FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.vehicle.id == vehicleID }))
            guard vehicle.cacheLastUpdated == nil || vehicle.cachedRecordCount != count else { return false }
            StatisticsCacheService.recalculateAllStatistics(for: vehicle)
            return true
        }
    }
}
