import Foundation

/// Service for efficiently computing and caching vehicle statistics
/// Reduces complexity from O(n² log n) to O(n log n) by computing everything in a single pass
final class StatisticsCacheService {

    // MARK: - Full Recalculation

    /// Recalculate all statistics for a vehicle in a single efficient pass
    /// Time complexity: O(n log n) where n = number of records
    /// - Parameter vehicle: The vehicle to recalculate statistics for
    static func recalculateAllStatistics(for vehicle: Vehicle) {
        let records = vehicle.fuelingRecords ?? []

        guard !records.isEmpty else {
            vehicle.invalidateCache()
            vehicle.cachedRecordCount = 0
            vehicle.cacheLastUpdated = Date()
            return
        }

        // Sort once - O(n log n)
        let sortedByDate = records.sorted(
            by: OdometerChronologyValidator.areInIncreasingOrder
        )

        // Single pass to compute all per-record cached values and aggregate statistics - O(n)
        var totalSpent: Double = 0
        var totalDistance: Double = 0
        var totalFuel: Double = 0
        var totalPricePerFuelUnit: Double = 0

        var fullFillUpDistance: Double = 0
        var fullFillUpFuel: Double = 0

        var bestEfficiency: Double = 0
        var worstEfficiency: Double = Double.greatestFiniteMagnitude
        var highestPrice: Double = 0
        var lowestPrice: Double = Double.greatestFiniteMagnitude

        var hasValidEfficiency = false
        var previousOdometer: Double = 0
        for (index, record) in sortedByDate.enumerated() {
            // Cache previous odometer for this record
            record.cachedPreviousOdometer = previousOdometer

            // Calculate distance driven
            let distanceDriven: Double
            if previousOdometer > 0 {
                distanceDriven = record.odometer - previousOdometer
                record.cachedDistanceDriven = distanceDriven
            } else {
                distanceDriven = 0
                record.cachedDistanceDriven = 0
            }

            let previousRecord = index > 0 ? sortedByDate[index - 1] : nil
            if let efficiency = FuelEfficiencyPolicy.rawEfficiency(
                distanceDriven: distanceDriven,
                fuelAmount: record.fuelAmount,
                currentFillUpType: record.fillUpType,
                previousFillUpType: previousRecord?.fillUpType,
                previousIsFirstRecord: index == 1
            ) {
                record.cachedEfficiency = efficiency

                // Track best/worst efficiency
                hasValidEfficiency = true
                if efficiency > bestEfficiency { bestEfficiency = efficiency }
                if efficiency < worstEfficiency { worstEfficiency = efficiency }

                // Accumulate for average efficiency calculation
                fullFillUpDistance += distanceDriven
                fullFillUpFuel += record.fuelAmount
            } else {
                record.cachedEfficiency = nil
            }

            // Calculate cost per distance
            if distanceDriven > 0 {
                record.cachedCostPerDistance = record.totalCost / distanceDriven
            } else {
                record.cachedCostPerDistance = nil
            }

            // Accumulate totals
            totalSpent += record.totalCost
            totalDistance += distanceDriven
            totalFuel += record.fuelAmount
            totalPricePerFuelUnit += record.pricePerFuelUnit

            // Track price extremes
            if record.pricePerFuelUnit > highestPrice { highestPrice = record.pricePerFuelUnit }
            if record.pricePerFuelUnit < lowestPrice { lowestPrice = record.pricePerFuelUnit }

            // Update state for next iteration
            previousOdometer = record.odometer
        }

        // Store aggregated statistics on the vehicle
        vehicle.cachedTotalSpent = totalSpent
        vehicle.cachedTotalDistance = totalDistance
        vehicle.cachedTotalFuel = totalFuel
        vehicle.cachedRecordCount = records.count

        // Average efficiency from full fill-ups only (more accurate)
        if fullFillUpFuel > 0 {
            vehicle.cachedAverageEfficiency = fullFillUpDistance / fullFillUpFuel
        } else if totalFuel > 0 {
            // Fallback to all records if no full fill-ups
            vehicle.cachedAverageEfficiency = totalDistance / totalFuel
        } else {
            vehicle.cachedAverageEfficiency = 0
        }

        // Average cost per distance
        if totalDistance > 0 {
            vehicle.cachedAverageCostPerDistance = totalSpent / totalDistance
        } else {
            vehicle.cachedAverageCostPerDistance = 0
        }

        // Average fill-up cost
        vehicle.cachedAverageFillUpCost = totalSpent / Double(records.count)

        // Average price per fuel unit
        vehicle.cachedAveragePricePerFuelUnit = totalPricePerFuelUnit / Double(records.count)

        // Best/worst efficiency
        vehicle.cachedBestEfficiency = hasValidEfficiency ? bestEfficiency : nil
        vehicle.cachedWorstEfficiency = hasValidEfficiency && worstEfficiency != Double.greatestFiniteMagnitude ? worstEfficiency : nil

        // Price extremes
        vehicle.cachedHighestPricePerFuelUnit = highestPrice > 0 ? highestPrice : nil
        vehicle.cachedLowestPricePerFuelUnit = lowestPrice != Double.greatestFiniteMagnitude ? lowestPrice : nil

        vehicle.cacheLastUpdated = Date()
    }

    // MARK: - Incremental Updates

    /// Update statistics after adding a new record
    /// If the record is the most recent, this is O(1). Otherwise, triggers full recalculation.
    static func updateForNewRecord(_ record: FuelingRecord, vehicle: Vehicle) {
        let records = vehicle.fuelingRecords ?? []

        // If this is the first record or records are empty, do full calculation
        guard records.count > 1 else {
            recalculateAllStatistics(for: vehicle)
            return
        }

        // Check if this record is the most recent by deterministic chronology.
        let isLatestRecord = !records.contains {
            $0.id != record.id
                && OdometerChronologyValidator.areInIncreasingOrder(record, $0)
        }

        if isLatestRecord {
            // Find the previous record in O(n) without sorting.
            var previousRecord: FuelingRecord?
            for r in records {
                guard r.id != record.id else { continue }
                guard OdometerChronologyValidator.areInIncreasingOrder(r, record) else { continue }
                if previousRecord == nil
                    || OdometerChronologyValidator.areInIncreasingOrder(previousRecord!, r) {
                    previousRecord = r
                }
            }
            let previousIsFirstRecord = previousRecord.map { previous in
                !records.contains {
                    $0.id != previous.id
                        && OdometerChronologyValidator.areInIncreasingOrder($0, previous)
                }
            } ?? false
            incrementalAddLatestRecord(
                record,
                previousRecord: previousRecord,
                previousIsFirstRecord: previousIsFirstRecord,
                to: vehicle
            )
        } else {
            // Record inserted in the middle - need to recalculate from that point
            // For simplicity, just do a full recalculation
            recalculateAllStatistics(for: vehicle)
        }
    }

    /// Incremental update when adding the latest (most recent) record
    private static func incrementalAddLatestRecord(
        _ record: FuelingRecord,
        previousRecord: FuelingRecord?,
        previousIsFirstRecord: Bool,
        to vehicle: Vehicle
    ) {
        guard let previousRecord else {
            recalculateAllStatistics(for: vehicle)
            return
        }

        let previousOdometer = previousRecord.odometer

        // Cache values for the new record
        record.cachedPreviousOdometer = previousOdometer

        let distanceDriven = record.odometer - previousOdometer
        record.cachedDistanceDriven = distanceDriven > 0 ? distanceDriven : 0

        if let efficiency = FuelEfficiencyPolicy.rawEfficiency(
            distanceDriven: distanceDriven,
            fuelAmount: record.fuelAmount,
            currentFillUpType: record.fillUpType,
            previousFillUpType: previousRecord.fillUpType,
            previousIsFirstRecord: previousIsFirstRecord
        ) {
            record.cachedEfficiency = efficiency

            // Update best/worst efficiency
            if let currentBest = vehicle.cachedBestEfficiency {
                if efficiency > currentBest { vehicle.cachedBestEfficiency = efficiency }
            } else {
                vehicle.cachedBestEfficiency = efficiency
            }

            if let currentWorst = vehicle.cachedWorstEfficiency {
                if efficiency < currentWorst { vehicle.cachedWorstEfficiency = efficiency }
            } else {
                vehicle.cachedWorstEfficiency = efficiency
            }
        } else {
            record.cachedEfficiency = nil
        }

        // Calculate cost per distance
        if distanceDriven > 0 {
            record.cachedCostPerDistance = record.totalCost / distanceDriven
        } else {
            record.cachedCostPerDistance = nil
        }

        // Update aggregate totals
        vehicle.cachedTotalSpent = (vehicle.cachedTotalSpent ?? 0) + record.totalCost
        vehicle.cachedTotalDistance = (vehicle.cachedTotalDistance ?? 0) + (distanceDriven > 0 ? distanceDriven : 0)
        vehicle.cachedTotalFuel = (vehicle.cachedTotalFuel ?? 0) + record.fuelAmount

        let newCount = (vehicle.cachedRecordCount ?? 0) + 1
        vehicle.cachedRecordCount = newCount

        // Recalculate averages
        if let totalSpent = vehicle.cachedTotalSpent {
            vehicle.cachedAverageFillUpCost = totalSpent / Double(newCount)
        }

        if let totalDistance = vehicle.cachedTotalDistance, totalDistance > 0, let totalSpent = vehicle.cachedTotalSpent {
            vehicle.cachedAverageCostPerDistance = totalSpent / totalDistance
        }

        // Recompute average efficiency using only valid full-to-full intervals,
        // matching the semantics of recalculateAllStatistics. We scan the
        // relationship for records whose cachedEfficiency was already set by
        // prior recalculations or by this incremental update.
        var fullFillUpDistance: Double = 0
        var fullFillUpFuel: Double = 0
        for r in (vehicle.fuelingRecords ?? []) {
            if let dist = r.cachedDistanceDriven, dist > 0,
               let _ = r.cachedEfficiency {
                fullFillUpDistance += dist
                fullFillUpFuel += r.fuelAmount
            }
        }
        if fullFillUpFuel > 0 {
            vehicle.cachedAverageEfficiency = fullFillUpDistance / fullFillUpFuel
        } else if let totalDistance = vehicle.cachedTotalDistance,
                  let totalFuel = vehicle.cachedTotalFuel, totalFuel > 0 {
            vehicle.cachedAverageEfficiency = totalDistance / totalFuel
        }

        // Update average price per fuel unit incrementally
        if let currentAvg = vehicle.cachedAveragePricePerFuelUnit {
            let oldCount = Double(newCount - 1)
            vehicle.cachedAveragePricePerFuelUnit = (currentAvg * oldCount + record.pricePerFuelUnit) / Double(newCount)
        } else {
            vehicle.cachedAveragePricePerFuelUnit = record.pricePerFuelUnit
        }

        // Update price extremes
        if let currentHighest = vehicle.cachedHighestPricePerFuelUnit {
            if record.pricePerFuelUnit > currentHighest {
                vehicle.cachedHighestPricePerFuelUnit = record.pricePerFuelUnit
            }
        } else {
            vehicle.cachedHighestPricePerFuelUnit = record.pricePerFuelUnit
        }

        if let currentLowest = vehicle.cachedLowestPricePerFuelUnit {
            if record.pricePerFuelUnit < currentLowest {
                vehicle.cachedLowestPricePerFuelUnit = record.pricePerFuelUnit
            }
        } else {
            vehicle.cachedLowestPricePerFuelUnit = record.pricePerFuelUnit
        }

        vehicle.cacheLastUpdated = Date()
    }

    /// Update statistics after deleting a record
    /// This triggers a full recalculation since deletion can affect subsequent records
    static func updateForDeletedRecord(vehicle: Vehicle) {
        recalculateAllStatistics(for: vehicle)
    }

    /// Update statistics after editing a record
    /// This triggers a full recalculation since edits can affect all calculations
    static func updateForEditedRecord(vehicle: Vehicle) {
        recalculateAllStatistics(for: vehicle)
    }

}
