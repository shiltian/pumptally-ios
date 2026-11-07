import SwiftUI
import UIKit
import XCTest

@testable import PumpTally

@MainActor
final class CurrencyInputFieldTests: XCTestCase {
    private final class Host<Content: View>: UIHostingController<Content> {
        var appeared: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared?()
        }
    }

    private final class Input {
        var value: Int
        var writes = 0

        init(_ value: Int) { self.value = value }

        var binding: Binding<Int> {
            Binding(
                get: { self.value },
                set: {
                    self.value = $0
                    self.writes += 1
                })
        }
    }

    private func withField(
        value: Int = 0, decimalPlaces: Int = 2, locale: Locale = Locale(identifier: "en_US"),
        _ body: (UITextField, Input) throws -> Void
    ) throws {
        let input = Input(value)
        let host = Host(
            rootView:
                CurrencyInputField(value: input.binding, decimalPlaces: decimalPlaces).environment(\.locale, locale))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = host
        let appeared = expectation(description: "Native input host appeared")
        host.appeared = { appeared.fulfill() }
        window.makeKeyAndVisible()
        wait(for: [appeared], timeout: 5)
        host.view.layoutIfNeeded()
        func findField(in view: UIView) -> UITextField? {
            (view as? UITextField) ?? view.subviews.lazy.compactMap { findField(in: $0) }.first
        }
        let field = try XCTUnwrap(findField(in: host.view))
        field.delegate?.textFieldDidBeginEditing?(field)
        defer { window.isHidden = true }
        try body(field, input)
    }

    private func replace(_ field: UITextField, range: NSRange, with text: String, selected: Bool = true) {
        let start = field.position(from: field.beginningOfDocument, offset: range.location)!
        let end = field.position(from: start, offset: selected ? range.length : 0)!
        field.selectedTextRange = field.textRange(from: start, to: end)
        if field.delegate?.textField?(field, shouldChangeCharactersIn: range, replacementString: text) == true {
            field.replace(
                field.textRange(from: start, to: field.position(from: start, offset: range.length)!)!, withText: text)
            field.sendActions(for: .editingChanged)
        }
    }

    func testSelectAllDeleteClearsTheWholeValue() throws {
        try withField(value: 12345) { field, input in
            replace(field, range: NSRange(location: 0, length: field.text!.utf16.count), with: "")
            XCTAssertEqual(input.value, 0)
        }
    }

    func testDecimalPasteReplacesTheSelection() throws {
        try withField(value: 12345) { field, input in
            replace(field, range: NSRange(location: 0, length: field.text!.utf16.count), with: "2.47")
            XCTAssertEqual(input.value, 247)
            XCTAssertEqual(field.text, "2.47")
        }
    }

    func testDecimalPasteIntoTheInitialZero() throws {
        try withField { field, input in
            replace(field, range: NSRange(location: field.text!.utf16.count, length: 0), with: "2.47")
            XCTAssertEqual(field.text, "2.47")
            XCTAssertEqual(input.value, 247)
            XCTAssertEqual(input.writes, 1)
        }
    }

    func testBackspaceOnAnEmptyFieldKeepsCashRegisterEntry() throws {
        try withField { field, input in
            replace(field, range: NSRange(location: 0, length: 0), with: "")
            replace(field, range: NSRange(location: 0, length: 0), with: "2")
            XCTAssertEqual(input.value, 2)
            XCTAssertEqual(field.text, "0.02")
        }
    }

    func testCashRegisterDigitsAndBackspaceKeepFixedDecimalEntry() throws {
        for decimalPlaces in [2, 3] {
            try withField(decimalPlaces: decimalPlaces) { field, input in
                for digit in "247" {
                    replace(field, range: NSRange(location: field.text!.utf16.count, length: 0), with: String(digit))
                }
                XCTAssertEqual(input.value, 247)
                let end = field.endOfDocument
                field.selectedTextRange = field.textRange(from: end, to: end)
                _ = field.delegate?.textField?(
                    field,
                    shouldChangeCharactersIn: NSRange(location: field.text!.utf16.count - 1, length: 1),
                    replacementString: "")
                XCTAssertEqual(input.value, 24)
                XCTAssertEqual(input.writes, 4)
            }
        }
    }

    func testExplicitDecimalEntryAndExcessPrecision() throws {
        try withField { field, input in
            for digit in "2.479" {
                replace(field, range: NSRange(location: field.text!.utf16.count, length: 0), with: String(digit))
            }
            XCTAssertEqual(input.value, 247)
            XCTAssertEqual(field.text, "2.47")
        }
    }

    func testSelectedDigitReplacementAndDeletionUseTheRequestedRange() throws {
        try withField(value: 12345) { field, input in
            replace(field, range: NSRange(location: 1, length: 1), with: "9")
            XCTAssertEqual(field.text, "193.45")
            XCTAssertEqual(input.value, 19345)
            XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: field.selectedTextRange!.start), 2)
            replace(field, range: NSRange(location: 0, length: 1), with: "")
            XCTAssertEqual(field.text, "93.45")
            XCTAssertEqual(input.value, 9345)
        }
    }

    func testInsertionAtTheCursorDoesNotAppendADigitToTheValue() throws {
        try withField(value: 12345) { field, input in
            replace(field, range: NSRange(location: 1, length: 0), with: "9")
            XCTAssertEqual(field.text, "1923.45")
            XCTAssertEqual(input.value, 192345)
        }
    }

    func testSelectedLastDigitDeletionDoesNotUseCashRegisterBackspace() throws {
        try withField(value: 12345) { field, input in
            replace(field, range: NSRange(location: 5, length: 1), with: "")
            XCTAssertEqual(field.text, "123.4")
            XCTAssertEqual(input.value, 12340)
        }
    }

    func testClearedFieldAcceptsNormalDecimalTextAndFormatsOnBlur() throws {
        try withField(value: 12345) { field, input in
            replace(field, range: NSRange(location: 0, length: field.text!.utf16.count), with: "")
            XCTAssertEqual(field.text, "")
            for digit in "2.4" {
                replace(field, range: NSRange(location: field.text!.utf16.count, length: 0), with: String(digit))
            }
            XCTAssertEqual(input.value, 240)
            XCTAssertEqual(field.text, "2.4")
            field.delegate?.textFieldDidEndEditing?(field)
            XCTAssertEqual(field.text, "2.40")
        }
    }

    func testLocalizedDisplayAndPaste() throws {
        for (identifier, text) in [
            ("en_US", "12,345.67"), ("es_ES", "12.345,67"),
            ("fr_FR", "12\u{202f}345,67"), ("ar_EG", "١٢٬٣٤٥٫٦٧"),
        ] {
            let locale = Locale(identifier: identifier)
            try withField(value: 12345, locale: locale) { field, input in
                XCTAssertTrue(field.text!.contains(locale.decimalSeparator!))
                replace(field, range: NSRange(location: 0, length: field.text!.utf16.count), with: text)
                XCTAssertEqual(input.value, 1_234_567, identifier)
                XCTAssertEqual(input.writes, 1)
            }
        }
    }

    func testDecimalCommaKeystrokes() throws {
        try withField(locale: Locale(identifier: "es_ES")) { field, input in
            for digit in "2,47" {
                replace(field, range: NSRange(location: field.text!.utf16.count, length: 0), with: String(digit))
            }
            XCTAssertEqual(input.value, 247)
            XCTAssertEqual(field.text, "2,47")
        }
    }

    func testInvalidPasteAndOverflowAreRejectedAtomically() throws {
        for text in ["2.47garbage", "1.2.3", "-2.47", "NaN", "1e3", "2.471", "10000000", "999999999999999999999"] {
            try withField(value: 12345) { field, input in
                replace(field, range: NSRange(location: 0, length: field.text!.utf16.count), with: text)
                XCTAssertEqual(field.text, "123.45", text)
                XCTAssertEqual(input.value, 12345, text)
                XCTAssertEqual(input.writes, 0, text)
            }
        }
        try withField(value: 999_999_999) { field, input in
            replace(field, range: NSRange(location: field.text!.utf16.count, length: 0), with: "9")
            XCTAssertEqual(input.value, 999_999_999)
            XCTAssertEqual(input.writes, 0)
        }
    }

    func testFocusAndBlurDoNotWriteUntouchedLegacyValues() throws {
        for value in [-1234, 1234, 1_234_567_890] {
            try withField(value: value) { field, input in
                field.delegate?.textFieldDidEndEditing?(field)
                XCTAssertEqual(input.value, value)
                XCTAssertEqual(input.writes, 0)
            }
        }
    }

    func testNativeSelectionReplacementAndDeletePublishTheirValues() throws {
        try withField(value: 247) { field, input in
            XCTAssertTrue(field.becomeFirstResponder())
            field.selectAll(nil)
            field.insertText("12.34")
            XCTAssertEqual(input.value, 1234)
            field.selectAll(nil)
            field.deleteBackward()
            XCTAssertEqual(input.value, 0)
        }
    }

    func testNativeUndoRestoresTheOriginalLegacyValue() throws {
        for value in [-1234, 1_234_567_890] {
            try withField(value: value) { field, input in
                XCTAssertTrue(field.becomeFirstResponder())
                let originalText = field.text
                field.selectAll(nil)
                field.insertText("2.47")
                XCTAssertEqual(input.value, 247)
                let undo = try XCTUnwrap(field.undoManager)
                XCTAssertTrue(undo.canUndo)
                undo.undo()
                XCTAssertEqual(field.text, originalText)
                XCTAssertEqual(input.value, value)
            }
        }
    }
}
