import SwiftUI
import UIKit

/// A text field that handles right-to-left digit entry with fixed decimal places.
/// - Right-to-left: typing "247" displays "2.47" for 2 decimal places
/// - Explicit decimal: typing "2.47" also displays "2.47"
/// - Extra digits after decimal limit are ignored
struct CurrencyInputField: View {
    @Environment(\.locale) private var locale
    @Binding var value: Int  // Value in smallest units (cents for 2 decimals, mills for 3)
    let decimalPlaces: Int
    let width: CGFloat
    let accessibilityIdentifier: String

    init(
        value: Binding<Int>,
        decimalPlaces: Int = 2,
        width: CGFloat = 100,
        accessibilityIdentifier: String = ""
    ) {
        self._value = value
        self.decimalPlaces = decimalPlaces
        self.width = width
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        CurrencyTextFieldRepresentable(
            value: $value,
            decimalPlaces: decimalPlaces,
            locale: locale,
            accessibilityIdentifier: accessibilityIdentifier
        )
        .frame(width: width, height: 22)
    }
}

// MARK: - Integer Power Helper
private func intPow(_ base: Int, _ exp: Int) -> Int {
    guard exp >= 0 else { return 0 }
    var result = 1
    for _ in 0..<exp {
        result *= base
    }
    return result
}

// MARK: - Display Formatting
private func formatValue(_ value: Int, decimalPlaces: Int, locale: Locale) -> String {
    let number = Decimal(value) / Decimal(intPow(10, decimalPlaces))
    return number.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(decimalPlaces)))
}

// MARK: - UIViewRepresentable
private struct CurrencyTextFieldRepresentable: UIViewRepresentable {
    @Binding var value: Int
    let decimalPlaces: Int
    let locale: Locale
    let accessibilityIdentifier: String

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.keyboardType = .decimalPad
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.textAlignment = .right
        textField.font = UIFont(name: "Avenir Next", size: 16)
        textField.delegate = context.coordinator
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textChanged), for: .editingChanged)
        textField.accessibilityIdentifier = accessibilityIdentifier
        let toolbar = UIToolbar()
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(
                barButtonSystemItem: .done, target: textField,
                action: #selector(UIResponder.resignFirstResponder)),
        ]
        toolbar.sizeToFit()
        textField.inputAccessoryView = toolbar
        context.coordinator.refresh(textField)
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        let coordinator = context.coordinator
        let configurationChanged =
            coordinator.parent.locale != locale || coordinator.parent.decimalPlaces != decimalPlaces
        coordinator.parent = self
        if !textField.isFirstResponder || coordinator.lastValue != value || configurationChanged {
            coordinator.refresh(textField)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CurrencyTextFieldRepresentable
        private(set) var lastValue: Int
        private var initialValue: Int
        private var isTextEditing = false
        private var multiplier: Int { intPow(10, parent.decimalPlaces) }
        private var separator: String { parent.locale.decimalSeparator ?? "." }
        private let maximumValue = 999_999_999

        init(_ parent: CurrencyTextFieldRepresentable) {
            self.parent = parent
            lastValue = parent.value
            initialValue = parent.value
        }

        func refresh(_ textField: UITextField) {
            isTextEditing = false
            lastValue = parent.value
            initialValue = parent.value
            textField.text = formatValue(parent.value, decimalPlaces: parent.decimalPlaces, locale: parent.locale)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            isTextEditing = false
            initialValue = parent.value
            // The initial zero is a display template, not text to append a
            // pasted number to. Focusing it does not change the bound value.
            if parent.value == 0 { textField.text = "" }
        }
        func textFieldDidEndEditing(_ textField: UITextField) { refresh(textField) }

        @objc func textChanged(_ textField: UITextField) {
            guard let value = parsedValue(textField.text ?? "") else {
                refresh(textField)
                return
            }
            publish(value)
        }

        func textField(_ textField: UITextField,
                       shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            let text = textField.text ?? ""
            guard let replacementRange = Range(range, in: text) else { return false }
            guard !string.isEmpty || range.length > 0 else { return false }
            let hasSelection = textField.selectedTextRange?.isEmpty == false
            let insertsAtEnd = !hasSelection && range.length == 0 && range.location == text.utf16.count
            let deletesAtEnd =
                !hasSelection && string.isEmpty && range.length == 1
                && NSMaxRange(range) == text.utf16.count

            // Cash-register entry applies only to individual keystrokes at the
            // end. All selection, cursor and paste edits use UIKit replacement.
            if !isTextEditing, insertsAtEnd, string.count == 1 {
                if let digit = string.first?.wholeNumberValue,
                    string.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) })
                {
                    let (shifted, overflow) = parent.value.multipliedReportingOverflow(by: 10)
                    let (value, additionOverflow) = shifted.addingReportingOverflow(digit)
                    guard !overflow, !additionOverflow, value >= 0, value <= maximumValue else { return false }
                    apply(value, to: textField)
                    return false
                }
                if string == separator {
                    let (value, overflow) = parent.value.multipliedReportingOverflow(by: multiplier)
                    guard !overflow, value >= 0, value <= maximumValue else { return false }
                    isTextEditing = true
                    let integer = parent.value.formatted(.number.locale(parent.locale).grouping(.never))
                    apply(value, text: integer + separator, to: textField)
                    return false
                }
            }
            if !isTextEditing, deletesAtEnd {
                apply(max(parent.value / 10, 0), to: textField)
                return false
            }

            let candidate = text.replacingCharacters(in: replacementRange, with: string)
            guard parsedValue(candidate) != nil else { return false }
            isTextEditing = true
            // UIKit owns the replacement and selection, including cut/paste and
            // undo. editingChanged publishes the resulting value exactly once.
            return true
        }

        private func parsedValue(_ text: String) -> Int? {
            // Undo may restore an unchanged legacy value outside today's entry
            // limits. Its original text must still restore its exact value.
            if text == formatValue(initialValue, decimalPlaces: parent.decimalPlaces, locale: parent.locale) {
                return initialValue
            }
            if text.isEmpty || text == separator { return 0 }
            var allowed = CharacterSet.decimalDigits
            allowed.formUnion(CharacterSet(charactersIn: separator + (parent.locale.groupingSeparator ?? "")))
            guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
            let parts = text.components(separatedBy: separator)
            guard parts.count <= 2,
                parts.count == 1 || parts[1].count <= parent.decimalPlaces,
                let number = text.wholeMatch(of: .localizedDecimal(locale: parent.locale))?.output
            else { return nil }
            let scaled = number * Decimal(multiplier)
            guard scaled >= 0, scaled <= Decimal(maximumValue) else { return nil }
            return NSDecimalNumber(decimal: scaled).intValue
        }

        private func publish(_ value: Int) {
            lastValue = value
            if parent.value != value { parent.value = value }
        }

        private func apply(_ value: Int, text: String? = nil, to textField: UITextField) {
            textField.text = text ?? formatValue(value, decimalPlaces: parent.decimalPlaces, locale: parent.locale)
            textField.selectedTextRange = textField.textRange(
                from: textField.endOfDocument, to: textField.endOfDocument)
            publish(value)
            textField.sendActions(for: .editingChanged)
        }
    }
}

// MARK: - Preview
#Preview {
    struct PreviewWrapper: View {
        @State private var totalCost: Int = 0
        @State private var gallons: Int = 0
        @State private var price: Int = 0

        var body: some View {
            Form {
                Section("Total Cost (2 decimals)") {
                    HStack {
                        Text("$")
                        CurrencyInputField(value: $totalCost, decimalPlaces: 2)
                    }
                    Text("Raw: \(totalCost) cents = $\(String(format: "%.2f", Double(totalCost)/100))")
                        .font(.caption)
                }

                Section("Gallons (3 decimals)") {
                    HStack {
                        CurrencyInputField(value: $gallons, decimalPlaces: 3)
                        Text("gal")
                    }
                    Text("Raw: \(gallons) mills")
                        .font(.caption)
                }

                Section("Price (3 decimals)") {
                    HStack {
                        Text("$")
                        CurrencyInputField(value: $price, decimalPlaces: 3)
                    }
                    Text("Raw: \(price) mills")
                        .font(.caption)
                }

                Section("Instructions") {
                    Text("• Type '247' → 2.47 (right-to-left)")
                    Text("• Type '2.47' → 2.47 (explicit decimal)")
                    Text("• Type '1.23456' → 1.23 (extra digits ignored)")
                }
                .font(.caption)
            }
        }
    }

    return PreviewWrapper()
}

