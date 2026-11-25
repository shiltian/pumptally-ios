import Foundation
import SwiftUI

// MARK: - App Typography

/// Centralized font definitions for consistent typography across the app.
/// All views should use these instead of inline `.custom("Avenir Next", size:)`.
extension Font {
    /// 11pt — badge labels (e.g., FillUpTypeBadge)
    static let appCaption2 = Font.custom("Avenir Next", size: 11)
    /// 12pt — section headers, footers, detail chips, secondary info
    static let appCaption = Font.custom("Avenir Next", size: 12)
    /// 13pt — secondary descriptions, notes, sub-labels
    static let appFootnote = Font.custom("Avenir Next", size: 13)
    /// 14pt — secondary labels, status text, chart labels
    static let appSubheadline = Font.custom("Avenir Next", size: 14)
    /// 16pt — form fields, body text, primary labels
    static let appBody = Font.custom("Avenir Next", size: 16)
    /// 17pt — card values, vehicle row title
    static let appHeadline = Font.custom("Avenir Next", size: 17)
    /// 18pt — buttons, medium-emphasis text
    static let appButton = Font.custom("Avenir Next", size: 18)
    /// 20pt — section titles, record cost
    static let appTitle3 = Font.custom("Avenir Next", size: 20)
    /// 22pt — stat card values
    static let appTitle2 = Font.custom("Avenir Next", size: 22)
    /// 24pt — export/import view titles
    static let appTitle = Font.custom("Avenir Next", size: 24)
    /// 26pt — popup title
    static let appLargeTitle = Font.custom("Avenir Next", size: 26)
    /// 32pt — welcome title
    static let appDisplay = Font.custom("Avenir Next", size: 32)
    /// 36pt — hero stat (cost per distance)
    static let appHero2 = Font.custom("Avenir Next", size: 36)
    /// 48pt — hero stat (efficiency)
    static let appHero = Font.custom("Avenir Next", size: 48)
}

// MARK: - App Gradients

/// Centralized gradient definitions for consistent theming.
extension LinearGradient {
    /// Primary brand gradient (teal → cyan, diagonal) for icon backgrounds
    static let brandDiagonal = LinearGradient(
        colors: [.teal, .cyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Primary brand gradient (teal → cyan, horizontal) for buttons
    static let brandHorizontal = LinearGradient(
        colors: [.teal, .cyan],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Subdued brand gradient for vehicle row icons
    static let brandSubdued = LinearGradient(
        colors: [.teal.opacity(0.7), .cyan.opacity(0.7)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Success gradient (green → mint) for checkmark icons
    static let success = LinearGradient(
        colors: [.green.opacity(0.8), .mint.opacity(0.8)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Efficiency icon gradient (purple → indigo)
    static let efficiencyIcon = LinearGradient(
        colors: [.purple, .indigo],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Cost icon gradient (orange → yellow)
    static let costIcon = LinearGradient(
        colors: [.orange, .yellow],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Background gradient for empty states
    static let subtleBackground = LinearGradient(
        colors: [Color(.systemBackground), Color(.systemGray6)],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Card Modifier

/// Reusable card styling: rounded corners + shadow
struct CardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
}

extension View {
    /// Apply card styling (background, rounded corners, shadow)
    func cardStyle(cornerRadius: CGFloat = 16) -> some View {
        modifier(CardModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Currency Display

extension Locale {
    var displayCurrencySymbol: String? {
        guard let currency else { return nil }
        return currencySymbol ?? currency.identifier
    }
}

extension Double {
    /// Format an amount using the locale's currency and number conventions.
    func currencyFormatted(locale: Locale, fractionDigits: Int? = nil) -> String {
        guard let currency = locale.currency else {
            return formatted(.number.locale(locale).precision(.fractionLength(fractionDigits ?? 2)))
        }
        let style = FloatingPointFormatStyle<Double>.Currency(code: currency.identifier, locale: locale)
        if let fractionDigits {
            return formatted(style.precision(.fractionLength(fractionDigits)))
        }
        return formatted(style)
    }
}

// MARK: - Editable Numbers

extension Double {
    /// A locale-independent representation suitable for editable numeric text
    /// fields. Whole values omit a trailing ".0"; fractional values retain
    /// their stored precision.
    var editableDecimalString: String {
        guard isFinite else { return String(self) }
        return rounded(.towardZero) == self ? String(format: "%.0f", self) : String(self)
    }
}

// MARK: - View Extensions

extension View {
    /// Hide keyboard
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
