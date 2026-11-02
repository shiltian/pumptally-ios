import XCTest
@testable import SwiftCSV

final class LocalEOFTests: XCTestCase {
    func testRawRowsPreserveWhitespaceWhileExistingViewsKeepTheirDefaults() throws {
        XCTAssertEqual(try parseCSV("a,b\n  text , \"  quoted  \" "), [["a", "b"], ["  text ", "   quoted   "]])
        XCTAssertEqual(try EnumeratedCSV(string: "a,b\n  text , \"  quoted  \" ", delimiter: .comma).rows,
            [["text ", "  quoted  "]])
    }
    func testRawRowsRetainEmptyFinalFieldsAndVariableWidths() throws {
        XCTAssertEqual(try parseCSV("a,b\n1\n2,\"\""), [["a", "b"], ["1"], ["2", ""]])
        XCTAssertEqual(try parseCSV("a,"), [["a", ""]])
        XCTAssertEqual(try parseCSV("\"\""), [[""]])
        XCTAssertEqual(try parseCSV(""), [])
    }

    func testEOFValidatesActiveFieldAfterQuotedAndUnquotedFields() throws {
        for valid in ["\"a\",b", "a,\"b\"", "\"a\",b,\"c\"", "a,b\n", "\"a\",b,"] {
            XCTAssertNoThrow(try parseCSV(valid))
        }
        for invalid in ["\"a", "a,\"b", "\"a\",b,\"c", "\"a\",b,unclosed\""] {
            XCTAssertThrowsError(try parseCSV(invalid))
        }
        XCTAssertNoThrow(try EnumeratedCSV(string: "a,b\n1,\"unclosed", delimiter: .comma, rowLimit: 0))
    }
}
