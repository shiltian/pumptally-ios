import SwiftUI
import SwiftData

struct DashboardView: View {
    let vehicle: Vehicle
    let records: [FuelingRecord]

    @AppStorage private var metricEfficiencyFormatRaw: String

    init(vehicle: Vehicle, records: [FuelingRecord]) {
        self.vehicle = vehicle
        self.records = records
        _metricEfficiencyFormatRaw = AppStorage(
            wrappedValue: MetricEfficiencyFormat.defaultFormat.rawValue,
            MetricEfficiencyFormat.storageKey(for: vehicle.id)
        )
    }

    private var units: UnitSystem { vehicle.displayUnitSystem }

    private var metricEfficiencyFormat: MetricEfficiencyFormat {
        MetricEfficiencyFormat(rawValue: metricEfficiencyFormatRaw) ?? .defaultFormat
    }

    private var recordCount: Int {
        records.count
    }

    private var chartInvalidationKey: String {
        let cacheTimestamp = vehicle.cacheLastUpdated?.timeIntervalSince1970 ?? 0
        return "\(recordCount)-\(cacheTimestamp)"
    }

    // Use cached statistics from the vehicle model
    private var totalSpent: Double {
        vehicle.cachedTotalSpent ?? 0
    }

    private var totalDistance: Double {
        units.distanceValue(vehicle.cachedTotalDistance ?? 0, from: vehicle.unitSystem)
    }

    private var totalFuel: Double {
        units.fuelValue(vehicle.cachedTotalFuel ?? 0, from: vehicle.unitSystem)
    }

    private var averageEfficiency: Double {
        let raw = units.efficiencyValue(vehicle.cachedAverageEfficiency ?? 0, from: vehicle.unitSystem)
        return units.efficiencyDisplayValue(from: raw, metricFormat: metricEfficiencyFormat)
    }

    private var averageCostPerDistance: Double {
        units.costPerDistanceValue(vehicle.cachedAverageCostPerDistance ?? 0, from: vehicle.unitSystem)
    }

    private var averageFillUpCost: Double {
        vehicle.cachedAverageFillUpCost ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Quick Stats Cards
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    StatCard(
                        title: String(localized: "Total Spent"),
                        value: totalSpent.currencyFormatted,
                        icon: "dollarsign.circle.fill",
                        color: .orange
                    )

                    StatCard(
                        title: String(localized: "Total \(units.distanceName)"),
                        value: totalDistance.formatted(.number.precision(.fractionLength(0))),
                        icon: "road.lanes",
                        color: .blue
                    )

                    StatCard(
                        title: String(localized: "Total \(units.fuelName)"),
                        value: totalFuel.formatted(.number.precision(.fractionLength(1))),
                        icon: "fuelpump.fill",
                        color: .green
                    )

                    StatCard(
                        title: String(localized: "Avg \(units.efficiencyUnit(for: metricEfficiencyFormat))"),
                        value: averageEfficiency.formatted(.number.precision(.fractionLength(1))),
                        icon: "gauge.with.dots.needle.67percent",
                        color: .purple
                    )

                    StatCard(
                        title: units.avgCostPerDistanceLabel,
                        value: averageCostPerDistance.currencyFormatted,
                        icon: "chart.line.uptrend.xyaxis",
                        color: .red
                    )

                    StatCard(
                        title: String(localized: "Avg Fill-up"),
                        value: averageFillUpCost.currencyFormatted,
                        icon: "creditcard.fill",
                        color: .teal
                    )
                }
                .padding(.horizontal)

                // Last Fill-up Info - use cached values
                if let lastRecord = records.max(by: OdometerChronologyValidator.areInIncreasingOrder) {
                    LastFillUpCard(
                        record: lastRecord,
                        previousOdometer: lastRecord.getPreviousOdometer(),
                        unitSystem: units,
                        metricEfficiencyFormat: metricEfficiencyFormat
                    )
                        .padding(.horizontal)
                }

                // Charts Section
                if recordCount >= 2 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Trends")
                            .font(.appTitle3)
                            .fontWeight(.bold)
                            .padding(.horizontal)

                        ChartView(
                            records: records,
                            unitSystem: units,
                            rawAverageEfficiency: units.efficiencyValue(
                                vehicle.cachedAverageEfficiency ?? 0, from: vehicle.unitSystem),
                            metricEfficiencyFormat: metricEfficiencyFormat,
                            invalidationKey: chartInvalidationKey
                        )
                            .frame(height: 250)
                            .padding(.horizontal)
                    }
                }

                // Empty state
                if recordCount == 0 {
                    EmptyRecordsView()
                        .padding(.top, 40)
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.appTitle2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(title)
                    .font(.appFootnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .cardStyle()
    }
}

struct LastFillUpCard: View {
    let record: FuelingRecord
    let previousOdometer: Double
    let unitSystem: UnitSystem
    let metricEfficiencyFormat: MetricEfficiencyFormat

    // Use cached efficiency if available
    private var efficiencyValue: Double {
        unitSystem.efficiencyDisplayValue(
            from: unitSystem.efficiencyValue(record.getEfficiency(), from: record.vehicle.unitSystem),
            metricFormat: metricEfficiencyFormat
        )
    }

    private var hasEfficiency: Bool {
        record.getEfficiency() > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundColor(.teal)

                Text("Last Fill-up")
                    .font(.appBody)
                    .fontWeight(.semibold)

                Spacer()

                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.appSubheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "\(unitSystem.fuelValue(record.fuelAmount, from: record.vehicle.unitSystem).formatted(.number.precision(.fractionLength(2)))) \(unitSystem.fuelUnit)"
                    )
                        .font(.appButton)
                        .fontWeight(.semibold)
                    Text(unitSystem.fuelName)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }

                Divider()
                    .frame(height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(record.totalCost.currencyFormatted)
                        .font(.appButton)
                        .fontWeight(.semibold)
                    Text("Total")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }

                Divider()
                    .frame(height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    if hasEfficiency {
                        Text("\(efficiencyValue.formatted(.number.precision(.fractionLength(1)))) \(unitSystem.efficiencyUnit(for: metricEfficiencyFormat))")
                            .font(.appButton)
                            .fontWeight(.semibold)
                        Text("Efficiency")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("—")
                            .font(.appButton)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Text(previousOdometer > 0 ? String(localized: "Partial") : String(localized: "Baseline"))
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }

            if record.isPartialFillUp {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                    Text("Partial fill-up")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .cardStyle()
    }
}

struct EmptyRecordsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "fuelpump")
                .font(.system(size: 50))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No fueling records yet")
                .font(.appButton)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            Text("Tap + to add your first fill-up")
                .font(.appSubheadline)
                .foregroundColor(.secondary.opacity(0.8))
        }
    }
}


#Preview {
    NavigationStack {
        DashboardView(vehicle: Vehicle(name: "Test Car"), records: [])
    }
    .modelContainer(
        for: [
            Vehicle.self, FuelingRecord.self, SyncChange.self, CloudRecordMetadata.self, PendingRemoteChange.self,
            SyncCheckpoint.self,
        ], inMemory: true)
}
