# PumpTally: Fuel & Car Log

A native iOS app built with SwiftUI and SwiftData to track your vehicle's fuel consumption, costs, and efficiency.

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/us/app/id6756544340)

## Features

### Multi-Vehicle Support
- Track multiple vehicles, each with its own dashboard, history, and settings
- Per-vehicle unit system: Imperial (miles / gallons / MPG) or Metric (km / liters), with a device-local choice of L/100 km or km/L for each Metric vehicle
- Automatic conversion of all existing records when switching a vehicle's unit system

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
- Incremental sync with CloudKit change tokens
- Automatic push on local changes, pull on app launch and foreground
- Background sync at utility priority to avoid blocking the UI

### CSV Import / Export
- Export a vehicle's fueling history as a CSV file (via native Save to Files picker)
- Import CSV files to add records to a vehicle
- Round-trip compatible format

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
- CKSyncEngine-backed CloudKit integration (local SwiftData is the source of truth; CloudKit acts as a mirror)
- Statistics caching via `StatisticsCacheService` for O(1) dashboard reads
- Shared `FuelingRecordFormView` component used by both Add and Edit flows
- Centralized UI styling via `Font`, `LinearGradient`, and `CardModifier` extensions
- Structured logging with `os.Logger` throughout

## License

MIT License
