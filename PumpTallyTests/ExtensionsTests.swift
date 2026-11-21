import XCTest
@testable import PumpTally

final class ExtensionsTests: XCTestCase {

    // MARK: - Currency Formatting

    func testCurrencyFormattingFollowsLocale() {
        XCTAssertEqual(1234.56.currencyFormatted(locale: Locale(identifier: "en_US")), "$1,234.56")
        XCTAssertEqual(1234.56.currencyFormatted(locale: Locale(identifier: "en_GB")), "£1,234.56")
        XCTAssertEqual(3.45.currencyFormatted(locale: Locale(identifier: "fr_FR")), "3,45\u{00A0}€")
    }

    func testCurrencyFormattingPreservesUnitPricePrecision() {
        XCTAssertEqual(3.459.currencyFormatted(locale: Locale(identifier: "en_GB"), fractionDigits: 3), "£3.459")
    }

    func testCurrencyFormattingUsesCurrencyFractionDigits() {
        XCTAssertEqual(245.3.currencyFormatted(locale: Locale(identifier: "en_JP")), "¥245")
    }

    func testCurrencyFormattingWithoutRegionalCurrencyDisplaysANumber() {
        let locale = Locale(identifier: "en")
        XCTAssertNil(locale.displayCurrencySymbol)
        XCTAssertEqual(3.45.currencyFormatted(locale: locale), "3.45")
    }

    func testCurrencyFormattingPreservesSignAndZero() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual((-25.5).currencyFormatted(locale: locale), "-$25.50")
        XCTAssertEqual(0.0.currencyFormatted(locale: locale), "$0.00")
    }

    // MARK: - Editable Decimal Strings

    func testEditableDecimalStringOmitsTrailingZeroForWholeValue() {
        XCTAssertEqual(45_000.0.editableDecimalString, "45000")
    }

    func testEditableDecimalStringPreservesFractionalValue() {
        XCTAssertEqual(45_000.25.editableDecimalString, "45000.25")
    }
}
