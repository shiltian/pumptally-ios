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

1. Open `PumpTally.xcodeproj` in Xcode.
2. Configure your development team and CloudKit container under **Signing & Capabilities**.
3. Build and run on your device or simulator.

## Development

PumpTally uses SwiftUI, SwiftData and CloudKit's CKSyncEngine. Persistence uses serialized writes and versioned schema migrations. CSV parsing uses the pinned [SwiftCSV dependency](ThirdParty/SwiftCSV/UPSTREAM.md).

Run the functional and UI tests on **iPhone 17 Pro Max**:

```sh
xcodebuild test -project PumpTally.xcodeproj -scheme PumpTally -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -parallel-testing-enabled NO
```

The test app uses isolated data and a simulated CloudKit environment; simulator iCloud sign-in is unnecessary. See the [development guide](docs/DEVELOPMENT.md) for additional checks, live CloudKit tests and production schema setup.

The [v1.6 release checklist and release notes](docs/RELEASE_1.6.md) record completed verification and remaining distribution steps. Bulk iCloud replacement remains disabled for compatibility with older clients.

## License

MIT License
