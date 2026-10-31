import SwiftUI
import SwiftData

struct DashboardView: View {
    let vehicle: Vehicle

    @AppStorage private var metricEfficiencyFormatRaw: String

    init(vehicle: Vehicle) {
        self.vehicle = vehicle
        _metricEfficiencyFormatRaw = AppStorage(
            wrappedValue: MetricEfficiencyFormat.defaultFormat.rawValue,
            MetricEfficiencyFormat.storageKey(for: vehicle.id)
        )
    }

    private var units: UnitSystem { vehicle.unitSystem }

    private var metricEfficiencyFormat: MetricEfficiencyFormat {
        MetricEfficiencyFormat(rawValue: metricEfficiencyFormatRaw) ?? .defaultFormat
    }

    private var recordCount: Int {
        vehicle.displayRecordCount
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
        vehicle.cachedTotalDistance ?? 0
    }

    private var totalFuel: Double {
        vehicle.cachedTotalFuel ?? 0
    }

    private var averageEfficiency: Double {
        let raw = vehicle.cachedAverageEfficiency ?? 0
        return units.efficiencyDisplayValue(from: raw, metricFormat: metricEfficiencyFormat)
    }

    private var averageCostPerDistance: Double {
        vehicle.cachedAverageCostPerDistance ?? 0
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
                if let lastRecord = vehicle.lastRecord {
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
                            records: vehicle.fuelingRecords ?? [],
                            unitSystem: units,
                            rawAverageEfficiency: vehicle.cachedAverageEfficiency ?? 0,
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
        .onAppear {
            // Ensure cache is valid when view appears
            StatisticsCacheService.ensureCacheValid(for: vehicle)
        }
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
            from: record.getEfficiency(),
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
                    Text("\(record.fuelAmount.formatted(.number.precision(.fractionLength(2)))) \(unitSystem.fuelUnit)")
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
        DashboardView(vehicle: Vehicle(name: "Test Car"))
    }
        .modelContainer(for: [Vehicle.self, FuelingRecord.self, SyncChange.self, CloudRecordMetadata.self, PendingRemoteChange.self], inMemory: true)
}
