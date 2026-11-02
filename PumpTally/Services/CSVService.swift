import Foundation

/// The backward-compatible seven-column CSV exchange format.
enum CSVService {
    static let csvHeader =
        "date,odometer,pricePerFuelUnit,fuelAmount,totalCost,fillUpType,notes"

    struct RecordSnapshot: Sendable {
        let id: UUID
        let date: Date
        let odometer: Double
        let pricePerFuelUnit: Double
        let fuelAmount: Double
        let totalCost: Double
        let fillUpTypeRaw: String
        let notes: String?

        init(record: FuelingRecord) {
            self.id = record.id
            self.date = record.date
            self.odometer = record.odometer
            self.pricePerFuelUnit = record.pricePerFuelUnit
            self.fuelAmount = record.fuelAmount
            self.totalCost = record.totalCost
            self.fillUpTypeRaw = record.fillUpType.rawValue
            self.notes = record.notes
        }
    }

    /// Export value snapshots to CSV format. This is safe to run away from the
    /// main actor because it does not touch SwiftData model objects.
    static func exportRecords(_ records: [RecordSnapshot]) -> String {
        let formatter = ISO8601DateFormatter()
        let rows = records.sorted {
            OdometerChronologyValidator.areInIncreasingOrder(
                lhsDate: $0.date,
                lhsOdometer: $0.odometer,
                lhsID: $0.id,
                rhsDate: $1.date,
                rhsOdometer: $1.odometer,
                rhsID: $1.id
            )
        }.map { snapshot in
            let dateString = formatter.string(from: snapshot.date)
            let notesEscaped = (snapshot.notes ?? "").replacingOccurrences(of: "\"", with: "\"\"")

            return "\(dateString),\(snapshot.odometer),\(snapshot.pricePerFuelUnit),\(snapshot.fuelAmount),\(snapshot.totalCost),\(snapshot.fillUpTypeRaw),\"\(notesEscaped)\""
        }
        return ([csvHeader] + rows).joined(separator: "\n") + "\n"
    }

}
