import SwiftData
import SwiftUI

/// Chronology validation needs the vehicle's live history only while an editor
/// is presented. Browsing History and Dashboard owns no managed history query.
struct FuelingRecordEditorView: View {
    let vehicle: Vehicle
    let selection: FuelingRecordEditSelection?
    let onSave: ((SavedFuelingRecord) -> Void)?
    @Query private var records: [FuelingRecord]

    init(
        vehicle: Vehicle, selection: FuelingRecordEditSelection? = nil,
        onSave: ((SavedFuelingRecord) -> Void)? = nil
    ) {
        self.vehicle = vehicle
        self.selection = selection
        self.onSave = onSave
        let id = vehicle.id
        _records = Query(filter: #Predicate<FuelingRecord> { $0.vehicle.id == id })
    }

    var body: some View {
        if let selection {
            EditRecordView(selection: selection, vehicle: vehicle, records: records)
        } else {
            AddRecordView(vehicle: vehicle, records: records, onSave: onSave)
        }
    }
}
