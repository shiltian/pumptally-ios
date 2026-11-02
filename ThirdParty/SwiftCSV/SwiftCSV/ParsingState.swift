//
//  ParsingState.swift
//  SwiftCSV
//
//  Created by Christian Tietze on 25/10/16.
//  Copyright © 2016 Naoto Kaneko. All rights reserved.
//

public enum CSVParseError: Error {
    case generic(message: String)
    case quotation(message: String)
}

/// State machine of parsing CSV contents character by character.
struct ParsingState {

    private(set) var atStart = true
    private(set) var parsingField = false
    private(set) var parsingQuotes = false
    private(set) var innerQuotes = false

    let delimiter: Character
    let finishRow: () -> Void
    let appendChar: (Character) -> Void
    let finishField: () -> Void
    let preservesWhitespace: Bool

    init(delimiter: Character,
         finishRow: @escaping () -> Void,
         appendChar: @escaping (Character) -> Void,
         finishField: @escaping () -> Void,
         preservesWhitespace: Bool = false) {

        self.delimiter = delimiter
        self.finishRow = finishRow
        self.appendChar = appendChar
        self.finishField = finishField
        self.preservesWhitespace = preservesWhitespace
    }

    /// - Throws: `CSVParseError`
    mutating func change(_ char: Character) throws {
        if atStart {
            if char == "\"" {
                atStart = false
                parsingQuotes = true
            } else if char == delimiter {
                finishField()
            } else if char.isNewline {
                finishRow()
            } else if char.isWhitespace {
              // ignore whitespaces between fields
              if preservesWhitespace { appendChar(char) }
            } else {
                parsingField = true
                atStart = false
                appendChar(char)
            }
        } else if parsingField {
            if innerQuotes {
                if char == "\"" {
                    appendChar(char)
                    innerQuotes = false
                } else {
                    throw CSVParseError.quotation(message: "Can't have non-quote here: \(char)")
                }
            } else {
                if char == "\"" {
                    innerQuotes = true
                } else if char == delimiter {
                    atStart = true
                    parsingField = false
                    innerQuotes = false
                    finishField()
                } else if char.isNewline {
                    atStart = true
                    parsingField = false
                    innerQuotes = false
                    finishRow()
                } else {
                    appendChar(char)
                }
            }
        } else if parsingQuotes {
            if innerQuotes {
                if char == "\"" {
                    appendChar(char)
                    innerQuotes = false
                } else if char == delimiter {
                    atStart = true
                    parsingField = false
                    innerQuotes = false
                    finishField()
                } else if char.isNewline {
                    atStart = true
                    parsingQuotes = false
                    innerQuotes = false
                    finishRow()
                } else if char.isWhitespace {
                  // ignore whitespaces between fields
                  if preservesWhitespace { appendChar(char) }
                } else {
                    throw CSVParseError.quotation(message: "Can't have non-quote here: \(char)")
                }
            } else {
                if char == "\"" {
                    innerQuotes = true
                } else {
                    appendChar(char)
                }
            }
        } else {
            throw CSVParseError.generic(message: "me_irl")
        }
    }

    /// A row limit may stop parsing early; only call this at the actual EOF.
    func finish() throws {
        guard !atStart else { return }
        if !parsingField && parsingQuotes && !innerQuotes {
            throw CSVParseError.quotation(message: "Quoted field is not closed")
        }
        if parsingField && innerQuotes {
            throw CSVParseError.quotation(message: "Unexpected quote in an unquoted field")
        }
    }
}
