import SwiftUI
import UIKit

/// A text field that handles right-to-left digit entry with fixed decimal places.
/// - Right-to-left: typing "247" displays "2.47" for 2 decimal places
/// - Explicit decimal: typing "2.47" also displays "2.47"
/// - Extra digits after decimal limit are ignored
struct CurrencyInputField: View {
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
private func formatValue(_ value: Int, decimalPlaces: Int) -> String {
    let divisor = intPow(10, decimalPlaces)
    let integerPart = value / divisor
    let decimalPart = abs(value % divisor)
    // Pad decimal part with leading zeros
    let decimalString = String(format: "%0\(decimalPlaces)d", decimalPart)
    return "\(integerPart).\(decimalString)"
}

// MARK: - UIViewRepresentable
private struct CurrencyTextFieldRepresentable: UIViewRepresentable {
    @Binding var value: Int
    let decimalPlaces: Int
    let accessibilityIdentifier: String

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.keyboardType = .decimalPad
        textField.textAlignment = .right
        textField.font = UIFont(name: "Avenir Next", size: 16)
        textField.text = formatValue(value, decimalPlaces: decimalPlaces)
        textField.delegate = context.coordinator
        textField.accessibilityIdentifier = accessibilityIdentifier

        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        // Only update if the value changed externally (e.g., from calculation)
        // and we're not currently editing
        if !textField.isFirstResponder {
            textField.text = formatValue(value, decimalPlaces: decimalPlaces)
            // Reset coordinator state when not editing
            context.coordinator.resetState()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator (State Machine)
    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CurrencyTextFieldRepresentable

        // State machine
        private var isDecimalMode: Bool = false
        private var decimalPosition: Int = 0

        // Precomputed constants (decimalPlaces is immutable for the component lifetime)
        private let decimalPlaces: Int
        private let multiplier: Int            // 10^decimalPlaces
        private let positionMultipliers: [Int]  // [10^(dp-1), 10^(dp-2), …, 10^0]

        init(_ parent: CurrencyTextFieldRepresentable) {
            self.parent = parent
            self.decimalPlaces = parent.decimalPlaces
            self.multiplier = intPow(10, parent.decimalPlaces)
            self.positionMultipliers = (0..<parent.decimalPlaces).map {
                intPow(10, parent.decimalPlaces - 1 - $0)
            }
        }

        func resetState() {
            isDecimalMode = false
            decimalPosition = 0
        }

        // MARK: - UITextFieldDelegate

        func textFieldDidBeginEditing(_ textField: UITextField) {
            resetState()
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            resetState()
            // Ensure display is formatted correctly
            textField.text = formatValue(parent.value, decimalPlaces: decimalPlaces)
        }

        func textField(_ textField: UITextField,
                       shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {

            // Work on a local copy — assign to binding exactly once at the end
            var current = parent.value

            // Handle backspace/delete
            if string.isEmpty {
                current = applyBackspace(to: current)
                parent.value = current
                textField.text = formatValue(current, decimalPlaces: decimalPlaces)
                return false
            }

            // Handle decimal point
            if string == "." || string == "," {
                if let newValue = applyDecimalPoint(to: current) {
                    current = newValue
                    parent.value = current
                }
                textField.text = formatValue(current, decimalPlaces: decimalPlaces)
                return false
            }

            // Only allow digits — no CharacterSet allocation
            guard string.allSatisfy(\.isNumber) else {
                return false
            }

            // Process each digit on the local copy
            for char in string {
                if let digit = char.wholeNumberValue {
                    current = applyDigit(digit, to: current)
                }
            }

            // Single binding mutation for the entire keystroke
            parent.value = current
            textField.text = formatValue(current, decimalPlaces: decimalPlaces)
            return false
        }

        // MARK: - State Machine Operations (pure value transforms)

        /// Returns the new value after appending a digit.
        private func applyDigit(_ digit: Int, to value: Int) -> Int {
            if isDecimalMode {
                // Decimal mode: fill decimal places from left to right
                guard decimalPosition < decimalPlaces else {
                    // All decimal places filled — ignore additional digits
                    return value
                }

                let posMul = positionMultipliers[decimalPosition]

                // Clear existing digit at this position and insert new one in a single expression
                let existingDigit = (value / posMul) % 10
                let newValue = value - existingDigit * posMul + digit * posMul
                decimalPosition += 1
                return newValue
            } else {
                // Normal mode: right-to-left entry
                let (shifted, multiplicationOverflow) = value.multipliedReportingOverflow(by: 10)
                let (newValue, additionOverflow) = shifted.addingReportingOverflow(digit)
                if !multiplicationOverflow, !additionOverflow, newValue <= 999_999_999, newValue >= value {
                    return newValue
                }
                return value
            }
        }

        /// Returns the new value after pressing decimal point, or nil if no change.
        private func applyDecimalPoint(to value: Int) -> Int? {
            guard !isDecimalMode else {
                // Already in decimal mode — ignore
                return nil
            }

            // Switch to decimal mode: current value becomes integer part
            let (newValue, overflow) = value.multipliedReportingOverflow(by: multiplier)
            if !overflow, newValue <= 999_999_999 {
                isDecimalMode = true
                decimalPosition = 0
                return newValue
            }
            return nil
        }

        /// Returns the new value after pressing backspace.
        private func applyBackspace(to value: Int) -> Int {
            let result: Int
            if isDecimalMode {
                if decimalPosition > 0 {
                    // Clear the last entered decimal digit
                    let targetPosition = decimalPosition - 1
                    let posMul = positionMultipliers[targetPosition]

                    let existingDigit = (value / posMul) % 10
                    result = value - existingDigit * posMul
                    decimalPosition -= 1
                } else {
                    // At position 0 — transition back to normal mode
                    result = value / multiplier
                    isDecimalMode = false
                }
            } else {
                // Normal mode: remove last digit
                result = value / 10
            }

            // Ensure non-negative
            return max(result, 0)
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

