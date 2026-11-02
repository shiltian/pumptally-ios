import Foundation
import SwiftCSV

struct CSVImportRecordSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let lineNumber: Int
    let date: Date
    let odometer: Double
    let pricePerFuelUnit: Double
    let fuelAmount: Double
    let totalCost: Double
    let fillUpType: FillUpType
    let notes: String?
}

enum CSVImportError: LocalizedError, Equatable, Sendable {
    case invalidFile(String)
    case invalidRow(line: Int, reason: String)
    case invalidChronology(line: Int, reason: String)
    case persistenceFailed
    case stalePlan

    var errorDescription: String? {
        switch self {
        case .invalidFile(let reason):
            return reason
        case .invalidRow(let line, let reason):
            return "Row \(line): \(reason)"
        case .invalidChronology(let line, let reason):
            return "Row \(line) has invalid odometer chronology: \(reason)"
        case .persistenceFailed:
            return String(localized: "Unable to save the imported records. No data was changed. Please try again.")
        case .stalePlan:
            return String(localized: "Your vehicle or records changed. Review the import again before saving.")
        }
    }
}

/// Strict, all-or-nothing CSV import pipeline.
///
/// Parsing and validation use value types only. SwiftData models are created
/// only after every row has passed structural and chronology validation.
enum CSVImportService {
    static func parse(_ content: String) throws -> [CSVImportRecordSnapshot] {
        let logicalRecords = try rows(content)
        guard let header = logicalRecords.first else {
            throw CSVImportError.invalidFile(String(localized: "The file is empty"))
        }
        guard logicalRecords.count > 1 else {
            throw CSVImportError.invalidFile(
                String(localized: "The file only contains a header row with no data")
            )
        }
        try validateHeader(header.fields)

        var records: [CSVImportRecordSnapshot] = []
        let dateParser = ImportDateParser()

        for logicalRecord in logicalRecords.dropFirst() {
            let lineNumber = logicalRecord.lineNumber
            let fields = logicalRecord.fields
            guard (5...7).contains(fields.count) else {
                throw CSVImportError.invalidRow(
                    line: lineNumber,
                    reason: String(localized: "expected between 5 and 7 columns")
                )
            }

            guard let date = dateParser.parse(fields[0].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw CSVImportError.invalidRow(
                    line: lineNumber,
                    reason: String(localized: "the date is invalid")
                )
            }

            let odometer = try positiveNumber(
                fields[1],
                name: String(localized: "odometer"),
                line: lineNumber
            )
            let price = try nonnegativeNumber(
                fields[2],
                name: String(localized: "price per fuel unit"),
                line: lineNumber
            )
            let fuel = try positiveNumber(
                fields[3],
                name: String(localized: "fuel amount"),
                line: lineNumber
            )
            let cost = try nonnegativeNumber(
                fields[4],
                name: String(localized: "total cost"),
                line: lineNumber
            )
            let fillUpType = try parseFillUpType(
                fields.count > 5 ? fields[5] : "",
                line: lineNumber
            )
            let notes = fields.count > 6 && !fields[6].isEmpty ? fields[6] : nil

            records.append(
                CSVImportRecordSnapshot(
                    id: UUID(),
                    lineNumber: lineNumber,
                    date: date,
                    odometer: odometer,
                    pricePerFuelUnit: price,
                    fuelAmount: fuel,
                    totalCost: cost,
                    fillUpType: fillUpType,
                    notes: notes
                )
            )
        }

        guard !records.isEmpty else {
            throw CSVImportError.invalidFile(
                String(localized: "The file contains no importable records")
            )
        }
        return records
    }

    static func validateChronology(
        _ records: [CSVImportRecordSnapshot],
        existingRecords: [OdometerReadingSnapshot]
    ) throws {
        guard existingRecords.allSatisfy({ $0.date.timeIntervalSince1970.isFinite && $0.odometer.isFinite }) else {
            throw CSVImportError.invalidFile(
                String(
                    localized:
                        "This vehicle has invalid dates or odometer readings. Review its history before importing."))
        }
        for row in records {
            guard row.date.timeIntervalSince1970.isFinite, row.odometer.isFinite, row.odometer > 0 else {
                throw CSVImportError.invalidChronology(
                    line: row.lineNumber,
                    reason: String(localized: "the reading must be a positive finite number"))
            }
        }
        let importedReadings = records.map {
            OdometerReadingSnapshot(id: $0.id, date: $0.date, odometer: $0.odometer)
        }
        let index = OdometerChronologyIndex(existingRecords + importedReadings)

        for record in records {
            let validation = index.validate(
                OdometerReadingSnapshot(id: record.id, date: record.date, odometer: record.odometer))
            guard let issue = validation.issue else { continue }

            let reason: String
            switch issue {
            case .invalidReading:
                reason = String(localized: "the reading must be a positive finite number")
            case .notGreaterThanPredecessor(let predecessor):
                reason = String(
                    localized: "the reading must be greater than \(formatted(predecessor.odometer))"
                )
            case .notLessThanSuccessor(let successor):
                reason = String(
                    localized: "the reading must be less than \(formatted(successor.odometer))"
                )
            }
            throw CSVImportError.invalidChronology(
                line: record.lineNumber,
                reason: reason
            )
        }
    }

    private static func positiveNumber(
        _ text: String,
        name: String,
        line: Int
    ) throws -> Double {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, value > 0 else {
            throw CSVImportError.invalidRow(
                line: line,
                reason: "\(name) must be a positive finite number"
            )
        }
        return value
    }

    private static func nonnegativeNumber(
        _ text: String,
        name: String,
        line: Int
    ) throws -> Double {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, value >= 0
        else {
            throw CSVImportError.invalidRow(
                line: line,
                reason: "\(name) must be a nonnegative finite number"
            )
        }
        return value
    }

    private static func validateHeader(_ header: [String]) throws {
        let fields = header.map {
            $0.lowercased().filter(\.isLetter)
        }
        let acceptedColumns: [Set<String>] = [
            ["date", "timestamp", "time"],
            ["odometer"],
            ["price", "priceperfuelunit"],
            ["fuel", "fuelamount"],
            ["cost", "totalcost"]
        ]
        guard fields.count >= acceptedColumns.count else {
            throw CSVImportError.invalidFile(
                String(localized: "The CSV header must contain date, odometer, price, fuel amount, and total cost columns.")
            )
        }
        for index in acceptedColumns.indices {
            guard acceptedColumns[index].contains(fields[index]) else {
                throw CSVImportError.invalidFile(
                    String(localized: "The CSV columns are missing or in an unsupported order.")
                )
            }
        }
    }

    private struct Row {
        let lineNumber: Int
        let fields: [String]
    }

    private static func rows(_ content: String) throws -> [Row] {
        let text = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
        let fields: [[String]]
        do { fields = try SwiftCSV.parseCSV(text) } catch {
            throw CSVImportError.invalidFile(String(localized: "The CSV contains invalid or unclosed quoted text."))
        }
        var line = 1
        return fields.compactMap { fields in
            let row = Row(lineNumber: line, fields: fields)
            // The library handles CSV syntax. Counting decoded newlines only
            // maps its rows back to physical lines; no quote scanner is needed.
            line += 1 + fields.reduce(0) { count, field in count + field.filter(\.isNewline).count }
            return fields.count == 1 && fields[0].trimmingCharacters(in: .whitespaces).isEmpty ? nil : row
        }
    }

    private static func formatted(_ value: Double) -> String {
        value.formatted(
            .number.precision(.fractionLength(0...3))
        )
    }

    private static func parseFillUpType(
        _ text: String,
        line: Int
    ) throws -> FillUpType {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty || normalized == "false" {
            return .full
        }
        if normalized == "true" {
            return .partial
        }
        guard let fillUpType = FillUpType(rawValue: normalized) else {
            throw CSVImportError.invalidRow(
                line: line,
                reason: String(localized: "fill-up type must be full, partial, or reset")
            )
        }
        return fillUpType
    }

    private struct ImportDateParser {
        private let isoFormatter = ISO8601DateFormatter()
        private let dateFormatters: [DateFormatter]

        init() {
            dateFormatters = ["yyyy-MM-dd", "MM/dd/yyyy"].map { format in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = format
                formatter.isLenient = false
                return formatter
            }
        }

        func parse(_ text: String) -> Date? {
            if let date = isoFormatter.date(from: text) {
                return date
            }
            for formatter in dateFormatters {
                if let date = formatter.date(from: text) {
                    return date
                }
            }
            return nil
        }
    }
}
