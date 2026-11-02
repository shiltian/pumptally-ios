# PumpTally: Fuel & Car Log

A native iOS app built with SwiftUI and SwiftData to track your vehicle's fuel consumption, costs, and efficiency.

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/us/app/id6756544340)

## Features

### Multi-Vehicle Support
- Track multiple vehicles, each with its own dashboard, history, and settings
- Per-vehicle unit system: Imperial (miles / gallons / MPG) or Metric (km / liters), with a device-local choice of L/100 km or km/L for each Metric vehicle
- Synced display/input units; switching units preserves stored historical measurements

### Smart Data Entry
- Auto-calculates the third field when you enter any two of: price per unit, fuel amount, or total cost
- Right-to-left currency input with fixed decimal places
- Three fill-up types: Full Tank, Partial Fill, and Missed Fueling (reset)
- Optional notes per record

### Statistics Dashboard
- Total spent, total distance, total fuel consumed
- Average efficiency (MPG, L/100 km, or km/L), average cost per distance, average fill-up cost
- Last fill-up summary card with date, fuel, cost, and efficiency

### Charts
- Efficiency over time (line chart with average reference line)
- Cost per fill-up over time (bar chart with average reference line)
- Fuel price over time (line chart with average reference line)
- Bucket-averaged for large datasets (100+ data points)

### iCloud Sync
- Toggle on/off from Settings
- First-time sync offers: upload local data, use iCloud data, or merge both
- Incremental sync with CKSyncEngine and a durable SwiftData inbox/checkpoint
- Automatic push on local changes, pull on app launch and foreground

### CSV Import / Export
- Export a vehicle's fueling history as a CSV file (via native Save to Files picker)
- Import CSV files to add records to a vehicle
- Round-trip compatible format

Both file-opening and the vehicle's file picker use the same import review.
Choose the CSV's source units explicitly; imports convert into the vehicle's
storage units without changing its existing measurements. Possible duplicates
require a choice to skip them or import every row. The seven-column exchange
has no stable IDs, unit metadata or fractional timestamps, so duplicate matches
are candidates and the CSV is not a complete application backup.

CSV syntax uses the pinned local SwiftCSV package; see
[dependency provenance and compatibility fixes](ThirdParty/SwiftCSV/UPSTREAM.md).
An immutable import plan binds the preview to the store and exact history.
The background writer checks that revision, validates indexed chronology and
commits records, caches and outgoing sync intent together. A changed history
requires a fresh review before any records are inserted.

## Requirements

- iOS 17.0+
- Xcode 15.0+
- An iCloud account (for sync features only)

## Getting Started

1. Open `PumpTally.xcodeproj` in Xcode
2. In the project's **Signing & Capabilities**, enable the **iCloud** capability with **CloudKit** (the container `iCloud.<your-bundle-id>` is read from the entitlements automatically)
3. Build and run on your device or simulator

## Architecture

- **SwiftUI** views with **SwiftData** persistence
- One injected persistence writer serializes local commands, cache repair and sync using fresh background `ModelActor` contexts; views await committed value results
- CKSyncEngine-backed CloudKit integration (local SwiftData is the source of truth; CloudKit acts as a mirror)
- Statistics caching via `StatisticsCacheService` for O(1) dashboard reads
- Shared `FuelingRecordFormView` component used by both Add and Edit flows
- Centralized UI styling via `Font`, `LinearGradient`, and `CardModifier` extensions
- Structured logging with `os.Logger` throughout

## Testing and data compatibility

Run the shared scheme on **iPhone 17 Pro Max**:

```sh
xcodebuild test -project PumpTally.xcodeproj -scheme PumpTally -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

The scheme's Test action uses the dedicated **Testing** build configuration. It selects `PumpTallyTests/Support/TestingAppBootstrap.swift` to supply isolated storage, preferences, synthetic UI fixtures, and a deterministic CloudKit boundary. Failure workflows also use synthetic read-only disk stores. Startup and sync events run through the same production lifecycle and service. The test app has a separate bundle identifier and no CloudKit entitlements. Ordinary Debug and Release builds select `ProductionAppBootstrap.swift` and exclude test support from compilation; the app entry point has no test-mode detection. Run tests using the scheme's configuration rather than overriding it with Debug or Release.

Shared build settings live in `Config/`. The `PumpTallyBenchmarks` scheme uses Release optimization with isolated test dependencies; it does not access production data. GitHub Actions verifies functional/UI tests, coverage, optimized persistence and performance cases, focused Thread Sanitizer checks, Debug analysis, Release compilation and test-support exclusion. Core Data concurrency diagnostics are configured in test launches. Performance runs use the optimized scheme separately from functional tests. CI pins hosted Xcode 27.1; local follow-up validation uses 27.2.

Check formatting only on changed Swift lines (or add `--fix`):

```sh
python3 scripts/swift_format.py
```

Live CloudKit contract tests use the separate `CloudKitProtocol` scheme and the development-container settings in `Config/CloudKitProbe.xcconfig`. Provision that container for the `CloudKitProbe` target, sign the host, and use an isolated test iCloud account. The probe refuses the production container and operates only on uniquely named synthetic test zones. These live tests are excluded from the ordinary offline suite.

Cloud replacement still requires live verification of guarded saves/deletes, cancellation and multiple batches, followed by a durable resumable recovery implementation. The current protocol probe compiles; offline tests do not establish those server guarantees. Minimum-iOS and native device/file-picker verification also remain release checks.

An immutable synthetic V3 store with 800 records verifies numeric fidelity through V4 migration, initial sync activation, and save/reopen. Initial enable is one account-bound application command: it commits records, caches, server metadata, outgoing work and activation together before starting the engine. Settings only collects the source choice; it does not manage persistence or activation flags.

V4 separates display preferences from measurement storage and stores sync checkpoints alongside inbound changes. Settings shows **Confirm Measurement Units** or **Review Previous Deletions** only when the corresponding user decision is needed. Incomplete records, unsupported formats, and missing vehicles appear under a separate **View Sync Diagnostics** action with no unit-confirmation controls. Ordinary pending sync work does not create recovery actions. Updating the app does not infer units, authorize previous deletions, or repair already-corrupted historical values automatically.

## License

MIT License
