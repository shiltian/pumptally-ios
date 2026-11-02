# SwiftCSV 0.10.0

Source: https://github.com/swiftcsv/SwiftCSV
Tag: `0.10.0`, revision `6ab5d0fe9b6ef3c79d717eefa70862df389e74d9`.
The upstream MIT license and privacy manifest are included. The package also
copies the license into its app resource bundle. This local Swift
package has no transitive dependencies. Keep upstream formatting intact.

The compatibility probe rejected unmodified SwiftCSV because it accepts an
unterminated quoted field and drops an empty final field at EOF. Local changes:

- `ParsingState.finish()` validates actual EOF, without changing limited reads.
- `Parser` retains an empty trailing field, including a quoted empty field.
- Public `parseCSV` exposes the existing raw-row parser without rectangular
  padding. PumpTally needs the original field counts and blank rows for strict
  domain validation and physical line diagnostics.
- The raw-row API preserves whitespace (including unquoted leading whitespace).
  Existing `CSV` views keep their upstream whitespace defaults. This is an
  option in the existing parsing state, not a separate validation grammar.
- The BOM fixture in `URLTests` has its stray final quote removed; strict EOF
  validation now correctly rejects that formerly malformed fixture. Upstream
  functional tests and `LocalEOFTests` are retained; upstream timing tests are
  excluded from functional validation and app performance runs separately.

No application business rules or second CSV grammar live in this package.
Application regression fixtures cover these changes. Re-evaluate upstream on
upgrades; remove patches when equivalent fixes/APIs are available. No upstream
pull request has been submitted.

Apple TabularData also preserved quoted text in the probe, but rejected legacy
5–7-column rows under one header. CodableCSV 0.6.7 also enforces rectangular
rows. CSV.swift and CHCSVParser were inspected but lack strict EOF validation.
Compatibility regressions live in `PumpTallyTests/CSVImportServiceTests.swift`;
focused parser checks live in `SwiftCSVTests/LocalEOFTests.swift`.
