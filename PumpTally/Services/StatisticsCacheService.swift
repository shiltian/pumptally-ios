import Foundation

/// Maintains the existing materialized statistics in the caller's transaction.
/// Interval caches record their predecessor and distance. A chronological pass
/// checks those dependencies and recalculates only invalidated intervals.
/// Vehicle reductions retain canonical order; no rounded-average arithmetic or
/// additional persistent accumulator is needed.
final class StatisticsCacheService {
    struct Update: Sendable {
        var calculatedRecordIDs: Set<UUID> = []
        var updatedRecordIDs: Set<UUID> = []
        var updatedVehicle = false
    }

    /// Business mutations invalidate their own interval inputs explicitly.
    /// Neighbor dependencies are checked by refresh after the graph is staged.
    /// A price-only change needs aggregate work; notes/metadata need neither.
    @discardableResult
    static func invalidateIfNeeded(_ record: FuelingRecord, previous: FuelingRecordValues) -> Bool {
        let intervalChanged =
            previous.date != record.date
            || previous.odometer.bitPattern != record.odometer.bitPattern
            || previous.fuelAmount.bitPattern != record.fuelAmount.bitPattern
            || previous.totalCost.bitPattern != record.totalCost.bitPattern
            || previous.fillUpType != record.fillUpType
        if intervalChanged {
            record.cachedPreviousOdometer = nil
            record.cachedDistanceDriven = nil
            record.cachedEfficiency = nil
            record.cachedCostPerDistance = nil
        }
        return intervalChanged || previous.pricePerFuelUnit.bitPattern != record.pricePerFuelUnit.bitPattern
    }

    @discardableResult
    static func refresh(for vehicle: Vehicle) -> Update {
        update(vehicle, rebuilding: false)
    }

    /// Bootstrap, explicit repair and unit adoption use the same calculation
    /// policy, independently of existing interval caches. Equal values aren't
    /// assigned, so a healthy rebuild does not dirty historical records.
    @discardableResult
    static func recalculateAllStatistics(for vehicle: Vehicle) -> Update {
        update(vehicle, rebuilding: true)
    }

    private static func update(_ vehicle: Vehicle, rebuilding: Bool) -> Update {
        // Project each managed object once; sorting and reductions then use
        // immutable values rather than repeated SwiftData property faults.
        let records = (vehicle.fuelingRecords ?? []).map(Row.init).sorted {
            OdometerChronologyValidator.areInIncreasingOrder(
                lhsDate: $0.date, lhsOdometer: $0.odometer, lhsID: $0.id,
                rhsDate: $1.date, rhsOdometer: $1.odometer, rhsID: $1.id)
        }
        var result = Update()
        var totals = Totals()
        for (index, record) in records.enumerated() {
            let dependencies = Interval(
                record: record, previous: index > 0 ? records[index - 1] : nil,
                previousIsFirst: index == 1)
            var cache = record.cache
            if rebuilding || !dependencies.matches(cache) {
                result.calculatedRecordIDs.insert(record.id)
                cache = dependencies.calculate()
                if cache.apply(to: record.model) { result.updatedRecordIDs.insert(record.id) }
            }
            totals.append(record, cache: cache)
        }
        result.updatedVehicle = totals.apply(to: vehicle)
        if result.updatedVehicle || !result.updatedRecordIDs.isEmpty || vehicle.cacheLastUpdated == nil {
            vehicle.cacheLastUpdated = Date()
            result.updatedVehicle = true
        }
        return result
    }

    /// Models stay inside this synchronous, context-owned pass. Only Update
    /// (IDs and counters) can escape. Sorting never dereferences the model.
    private struct Row {
        let model: FuelingRecord
        let id: UUID
        let date: Date
        let odometer: Double
        let pricePerFuelUnit: Double
        let fuelAmount: Double
        let totalCost: Double
        let fillUpType: FillUpType
        let cache: CachedInterval

        init(_ record: FuelingRecord) {
            model = record
            id = record.id; date = record.date; odometer = record.odometer
            pricePerFuelUnit = record.pricePerFuelUnit; fuelAmount = record.fuelAmount
            totalCost = record.totalCost; fillUpType = record.fillUpType
            cache = CachedInterval(
                previousOdometer: record.cachedPreviousOdometer, distance: record.cachedDistanceDriven,
                efficiency: record.cachedEfficiency, costPerDistance: record.cachedCostPerDistance)
        }
    }

    private struct CachedInterval {
        let previousOdometer: Double?
        let distance: Double?
        let efficiency: Double?
        let costPerDistance: Double?

        func apply(to record: FuelingRecord) -> Bool {
            var changed = set(record, \.cachedPreviousOdometer, previousOdometer)
            changed = set(record, \.cachedDistanceDriven, distance) || changed
            changed = set(record, \.cachedEfficiency, efficiency) || changed
            changed = set(record, \.cachedCostPerDistance, costPerDistance) || changed
            return changed
        }
    }

    private struct Interval {
        let previousOdometer: Double
        let distance: Double
        let fuel: Double
        let cost: Double
        let fill: FillUpType
        let previousFill: FillUpType?
        let previousIsFirst: Bool

        init(record: Row, previous: Row?, previousIsFirst: Bool) {
            previousOdometer = previous?.odometer ?? 0
            distance = previousOdometer > 0 ? record.odometer - previousOdometer : 0
            fuel = record.fuelAmount
            cost = record.totalCost
            fill = record.fillUpType
            previousFill = previous?.fillUpType
            self.previousIsFirst = previousIsFirst
        }

        private var eligible: Bool {
            FuelEfficiencyPolicy.isEligible(
                distanceDriven: distance, fuelAmount: fuel,
                currentFillUpType: fill, previousFillUpType: previousFill,
                previousIsFirstRecord: previousIsFirst)
        }

        func matches(_ cache: CachedInterval) -> Bool {
            same(cache.previousOdometer, previousOdometer)
                && same(cache.distance, distance)
                && (cache.efficiency != nil) == eligible
                && (cache.costPerDistance != nil) == (distance > 0)
        }

        func calculate() -> CachedInterval {
            CachedInterval(
                previousOdometer: previousOdometer, distance: distance,
                efficiency: FuelEfficiencyPolicy.rawEfficiency(
                    distanceDriven: distance, fuelAmount: fuel,
                    currentFillUpType: fill, previousFillUpType: previousFill,
                    previousIsFirstRecord: previousIsFirst), costPerDistance: distance > 0 ? cost / distance : nil)
        }
    }

    private struct Totals {
        var count = 0
        var spent: Double = 0
        var distance: Double = 0
        var fuel: Double = 0
        var price: Double = 0
        var eligibleDistance: Double = 0
        var eligibleFuel: Double = 0
        var best: Double = 0
        var worst = Double.greatestFiniteMagnitude
        var highest: Double = 0
        var lowest = Double.greatestFiniteMagnitude
        var hasEfficiency = false

        mutating func append(_ record: Row, cache: CachedInterval) {
            let intervalDistance = cache.distance ?? 0
            if let efficiency = cache.efficiency {
                hasEfficiency = true
                if efficiency > best { best = efficiency }
                if efficiency < worst { worst = efficiency }
                eligibleDistance += intervalDistance
                eligibleFuel += record.fuelAmount
            }
            spent += record.totalCost
            distance += intervalDistance
            fuel += record.fuelAmount
            price += record.pricePerFuelUnit
            if record.pricePerFuelUnit > highest { highest = record.pricePerFuelUnit }
            if record.pricePerFuelUnit < lowest { lowest = record.pricePerFuelUnit }
            count += 1
        }

        func apply(to vehicle: Vehicle) -> Bool {
            let averageEfficiency =
                eligibleFuel > 0 ? eligibleDistance / eligibleFuel : (fuel > 0 ? distance / fuel : 0)
            var changed = set(vehicle, \.cachedTotalSpent, count > 0 ? spent : nil)
            changed = set(vehicle, \.cachedTotalDistance, count > 0 ? distance : nil) || changed
            changed = set(vehicle, \.cachedTotalFuel, count > 0 ? fuel : nil) || changed
            changed = set(vehicle, \.cachedAverageEfficiency, count > 0 ? averageEfficiency : nil) || changed
            changed =
                set(vehicle, \.cachedAverageCostPerDistance, count > 0 ? (distance > 0 ? spent / distance : 0) : nil)
                || changed
            changed = set(vehicle, \.cachedAverageFillUpCost, count > 0 ? spent / Double(count) : nil) || changed
            changed = set(vehicle, \.cachedAveragePricePerFuelUnit, count > 0 ? price / Double(count) : nil) || changed
            changed = set(vehicle, \.cachedBestEfficiency, hasEfficiency ? best : nil) || changed
            changed =
                set(vehicle, \.cachedWorstEfficiency, hasEfficiency && worst != .greatestFiniteMagnitude ? worst : nil)
                || changed
            changed = set(vehicle, \.cachedHighestPricePerFuelUnit, highest > 0 ? highest : nil) || changed
            changed =
                set(vehicle, \.cachedLowestPricePerFuelUnit, lowest != .greatestFiniteMagnitude ? lowest : nil)
                || changed
            if vehicle.cachedRecordCount != count { vehicle.cachedRecordCount = count; changed = true }
            return changed
        }
    }

    private static func same(_ lhs: Double?, _ rhs: Double?) -> Bool {
        lhs?.bitPattern == rhs?.bitPattern
    }

    private static func set<Root: AnyObject>(
        _ root: Root, _ key: ReferenceWritableKeyPath<Root, Double?>, _ value: Double?
    ) -> Bool {
        guard !same(root[keyPath: key], value) else { return false }
        root[keyPath: key] = value
        return true
    }
}
