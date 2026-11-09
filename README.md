# PumpTally: Fuel & Car Log

A native iOS app for tracking your vehicles' fuel consumption, costs and efficiency.

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/us/app/id6756544340)

## Features

- Multiple vehicles, each with its own dashboard, history and settings
- Imperial and Metric units, including MPG, L/100 km and km/L
- Fueling records with automatic cost calculations, fill-up types and notes
- Statistics and charts for fuel efficiency, spending and fuel prices
- Optional iCloud sync, with choices to use iCloud data or merge both copies
- Saved sync review and recovery information for changes that need confirmation
- CSV import and export, with unit conversion and duplicate review

## Requirements

- iOS 17.0 or later
- Xcode; see the [CI workflow](.github/workflows/ios.yml) for the verified toolchain
- An iCloud account for sync features

## Getting Started

1. Open `PumpTally.xcodeproj` in Xcode and select the **PumpTally** scheme.
2. For physical-device builds, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and enter your development team identifier. This local file is ignored by Git.
3. Configure bundle identifiers and CloudKit containers for your own Apple Developer team under **Signing & Capabilities**.
4. Build and run on your device or simulator.

## Development

PumpTally uses SwiftUI, SwiftData and CloudKit's CKSyncEngine. Persistence uses serialized writes and versioned schema migrations. CSV parsing uses the pinned [SwiftCSV dependency](ThirdParty/SwiftCSV/UPSTREAM.md).

Run the functional and UI tests on **iPhone 17 Pro Max**:

```sh
xcodebuild test -project PumpTally.xcodeproj -scheme PumpTally -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -parallel-testing-enabled NO
```

The test app uses isolated data and a simulated CloudKit environment; simulator iCloud sign-in is unnecessary. The [CI workflow](.github/workflows/ios.yml) includes additional persistence, migration, performance, and build-isolation checks. Example import files are available in [SampleData](SampleData).

See the [release notes](docs/ReleaseNotes.md) for the latest changes. Bulk iCloud replacement remains disabled for compatibility with older clients.

## License

MIT License
