import SwiftUI

// MARK: - Value-type snapshot of a fueling record for the summary popup.
// Using a plain struct instead of the SwiftData model object avoids any
// issues with model faulting / context invalidation during sheet transitions.
struct FuelingSummaryData: Identifiable {
    let id = UUID()
    let date: Date
    let odometer: Double
    let fuelAmount: Double
    let pricePerFuelUnit: Double
    let totalCost: Double
    let isPartialFillUp: Bool
    let previousOdometer: Double
    let efficiencyRaw: Double
    let costPerDistance: Double
    let distanceDriven: Double
    let unitSystem: UnitSystem
    let metricEfficiencyFormat: MetricEfficiencyFormat

    /// Presentation consumes the committed value result, without retaining a
    /// model from the write transaction.
    init(
        record: SavedFuelingRecord,
        unitSystem: UnitSystem,
        metricEfficiencyFormat: MetricEfficiencyFormat = .defaultFormat
    ) {
        self.date = record.values.date
        self.odometer = unitSystem.distanceValue(record.values.odometer, from: record.storageUnit)
        self.fuelAmount = unitSystem.fuelValue(record.values.fuelAmount, from: record.storageUnit)
        self.pricePerFuelUnit = unitSystem.priceValue(record.values.pricePerFuelUnit, from: record.storageUnit)
        self.totalCost = record.values.totalCost
        self.isPartialFillUp = record.values.fillUpType == .partial
        self.previousOdometer = unitSystem.distanceValue(record.previousOdometer, from: record.storageUnit)
        self.efficiencyRaw = unitSystem.efficiencyValue(record.efficiency, from: record.storageUnit)
        self.costPerDistance = unitSystem.costPerDistanceValue(
            record.costPerDistance, from: record.storageUnit)
        self.distanceDriven = unitSystem.distanceValue(record.distanceDriven, from: record.storageUnit)
        self.unitSystem = unitSystem
        self.metricEfficiencyFormat = metricEfficiencyFormat
    }

    var efficiencyDisplay: Double {
        unitSystem.efficiencyDisplayValue(
            from: efficiencyRaw,
            metricFormat: metricEfficiencyFormat
        )
    }

    var hasEfficiency: Bool {
        efficiencyRaw > 0
    }
}

struct FuelingSummaryPopup: View {
    let data: FuelingSummaryData

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.success)
                        .frame(width: 80, height: 80)

                    Image(systemName: "checkmark")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                }

                Text("Fill-up Recorded!")
                    .font(.appLargeTitle)
                    .fontWeight(.bold)

                Text(data.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.appSubheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 32)

            // Stats Cards
            VStack(spacing: 16) {
                // Efficiency Card - Hero Stat (only show for full fill-ups with valid previous record)
                if data.hasEfficiency {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Fuel Efficiency")
                                .font(.appSubheadline)
                                .foregroundColor(.secondary)

                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(data.efficiencyDisplay.formatted(.number.precision(.fractionLength(1))))
                                    .font(.appHero)
                                    .fontWeight(.bold)
                                    .foregroundColor(.purple)

                                Text(data.unitSystem.efficiencyUnit(for: data.metricEfficiencyFormat))
                                    .font(.appButton)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.purple.opacity(0.7))
                            }
                        }

                        Spacer()

                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 50))
                            .foregroundStyle(LinearGradient.efficiencyIcon)
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.purple.opacity(0.1))
                    )

                    // Cost per Distance Card
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(data.unitSystem.costPerDistanceLabel)
                                .font(.appSubheadline)
                                .foregroundColor(.secondary)

                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(data.costPerDistance.currencyFormatted)
                                    .font(.appHero2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.orange)

                                Text(data.unitSystem.costPerDistanceShort)
                                    .font(.appBody)
                                    .foregroundColor(.orange.opacity(0.7))
                            }
                        }

                        Spacer()

                        Image(systemName: "dollarsign.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(LinearGradient.costIcon)
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.orange.opacity(0.1))
                    )
                }

                // Details Grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    if data.previousOdometer > 0 {
                        SummaryDetailCard(
                            title: String(localized: "\(data.unitSystem.distanceName) Driven"),
                            value: "\(data.distanceDriven.formatted(.number.precision(.fractionLength(0)))) \(data.unitSystem.distanceUnit)",
                            icon: "road.lanes",
                            color: .blue
                        )
                    } else {
                        SummaryDetailCard(
                            title: String(localized: "Odometer"),
                            value: "\(data.odometer.formatted(.number.precision(.fractionLength(0)))) \(data.unitSystem.distanceUnit)",
                            icon: "speedometer",
                            color: .blue
                        )
                    }

                    SummaryDetailCard(
                        title: data.unitSystem.fuelName,
                        value: "\(data.fuelAmount.formatted(.number.precision(.fractionLength(2)))) \(data.unitSystem.fuelUnit)",
                        icon: "fuelpump.fill",
                        color: .green
                    )

                    SummaryDetailCard(
                        title: data.unitSystem.pricePerFuelShortLabel,
                        value: data.pricePerFuelUnit.currencyFormatted,
                        icon: "tag.fill",
                        color: .teal
                    )

                    SummaryDetailCard(
                        title: String(localized: "Total Cost"),
                        value: data.totalCost.currencyFormatted,
                        icon: "creditcard.fill",
                        color: .pink
                    )
                }

                if data.isPartialFillUp {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("Partial fill-up — efficiency may be less accurate")
                            .font(.appFootnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.yellow.opacity(0.1))
                    )
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            // Done Button
            Button(action: { dismiss() }) {
                Text("Done")
                    .font(.appButton)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                    LinearGradient.brandHorizontal
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

struct SummaryDetailCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)

            Text(value)
                .font(.appHeadline)
                .fontWeight(.semibold)

            Text(title)
                .font(.appCaption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    let vehicle = Vehicle(name: "Test Car")
    let record = FuelingRecord(
        odometer: 12500,
        pricePerFuelUnit: 3.459,
        fuelAmount: 10.5,
        totalCost: 36.32,
        vehicle: vehicle
    )
    record.cachedPreviousOdometer = 12200
    record.cachedDistanceDriven = 300
    record.cachedEfficiency = 300.0 / 10.5
    record.cachedCostPerDistance = 36.32 / 300.0
    return FuelingSummaryPopup(
        data: FuelingSummaryData(record: SavedFuelingRecord(record: record), unitSystem: .imperial)
    )
}
