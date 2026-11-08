# Development

Shared build settings live in `Config/`. The [CI workflow](../.github/workflows/ios.yml) defines the verified toolchain and commands for functional/UI tests, optimized persistence and performance tests, Thread Sanitizer, production analysis and Release builds.

## Local checks

Use **iPhone 17 Pro Max** as the build and test destination. The `PumpTally` scheme's Test action selects the isolated `Testing` configuration; do not override it with Debug or Release. Test storage, preferences and CloudKit responses are separate from the shipping app. Production builds exclude the test bootstrap and fixtures.

For compatibility checks, use the simulator runtimes installed through Xcode Settings → Components; no runtime file in Downloads is needed. Build the Testing app for iPhone 17 Pro Max, then run that same build sequentially on each supported installed runtime with `test-without-building`. Older runtimes require a compatible model (iPhone 15 Pro Max for iOS 17, iPhone 16 Pro Max for iOS 18). Use fresh disposable simulators and the Testing bundle; never use an existing user store. Explicitly boot each test device and wait for `xcrun simctl bootstatus <device-id> -b` before launching the test host, so rendered-query checks have a connected window scene. Include the complete unit/integration and UI suites, not just launch or migration checks.

The owned writer uses SwiftData's native main-queue model executor on iOS 17 because private-queue saves do not refresh existing `@Query` values there. iOS 18 and newer retain the background model executor. Each command still has a fresh context, serialized execution and one explicit commit. Read-only history and recovery actors remain in the background. On iOS 17, successful owned commits also publish container-scoped entity names through NotificationCenter because the native SwiftData save notification is absent. History and recovery views observe that value signal alongside native notifications; failed saves publish nothing. On iOS 17, failed command contexts are discarded with autosaving disabled to avoid native rollback traps. Newer runtimes roll back failed work before releasing the actor, as SwiftData requires. Both paths preserve unrelated UI drafts and use a fresh context for the next command.

The `PumpTallyBenchmarks` scheme selects Release optimization with isolated test dependencies. Run performance cases separately from functional tests; the CI workflow lists the individual suites.

`VehicleHistoryPerformanceTests` measures cold fetch/index/chart preparation for single-vehicle histories of 800, 3,200 and 12,800 records, plus cached search and paging at 12,800. Fixture creation is excluded. The UI receives 50-row pages and at most 200 chart points per series; the background value catalog and exact chart summaries still cover the whole vehicle history. Search/sort/page requests reuse that catalog until a relevant save. Native save generation and request checks reject stale results. These measurements cover read preparation, not complete screen-rendering latency; preserve the result metrics rather than asserting a portable timing budget.

`SyncRecoveryReadPerformanceTests` measures fresh retained-inbox decoding and recovery assessment at 800, 3,200 and 12,800 pending changes, plus one pending change among 12,800 local records. Fixture writes are excluded. Read/decode counters assert one inbox load per operation, one archive decode per modification, and local fetches scoped to referenced records. Multi-parent deletion, retained raw payloads, rollback and stale assessment checks run in `SyncRecoveryReadTests`. The decoded inbox is operation-scoped; separate sync operations reread current state. These are preparation measurements, not full Settings rendering or network timings.

Check formatting on changed Swift lines, or add `--fix` to apply changes:

```sh
python3 scripts/swift_format.py
```

Persistence migrations use `VersionedSchema` and `SchemaMigrationPlan`. Test them with copies of the immutable stores in `PumpTallyTests/Fixtures`, preserving existing business values through save and reopen. Never run migration experiments against a live user store.

### Verified simulator matrix — November 8, 2026

The Xcode 27.2 (27B52) matrix covers the same 584 distinct functional cases on each runtime:

| iOS runtime | Simulator model | Unit/integration | UI |
| --- | --- | --- | --- |
| 17.5 (21F79) | iPhone 15 Pro Max | 541 passed | 43 passed |
| 18.6 (22G86) | iPhone 16 Pro Max | 541 passed | 43 passed |
| 26.5 (23F77) | iPhone 17 Pro Max | 541 passed | 43 passed |
| 27.2 (24B8117) | iPhone 17 Pro Max | 541 passed | 43 passed |

Counts combine full runs and focused reruns after fixture and native input-gesture corrections. Follow-up regressions cover the final failed-command cleanup on iOS 18 and newer. Tests use disposable stores and fake CloudKit transport. Copied-store checks cover released v1.1, v1.2, v1.3 and v1.5 layouts plus retained sync/recovery state through V6 migration, full-row writes and reopening.

On both iOS 17.5 and 27.2, 216 optimized persistence/migration checks and 121 Thread Sanitizer checks passed with no reported runtime issues or race reports. Production Release compilation, Debug complete-concurrency analysis and Debug/Release/Benchmark fixture isolation also passed.

Full UI runs retain SwiftUI invalid-frame diagnostics. iOS 18 and 26 also report internal QoS priority-inversion diagnostics in three unit cases. These diagnostics remain visible in the result bundles. Simulator checks complement the physical-device and production CloudKit release checks below.

## Compatibility with released versions

Apple's [public version history](https://apps.apple.com/us/app/pumptally/id6756544340) shows v1.1 on April 14, v1.2 on May 12 and v1.3 on June 4; v1.1 is the earliest version visible there. Tag v1.1 used an unversioned store matching historical schema V1. Tags v1.2 through v1.5 use schema V2. Keep V1 and V2 historical definitions compatible with those models and retain the complete migration path to the current schema. `SchemaMigrationTests` copies independent `ReleasedV11.store`, `ReleasedV12.store`, `ReleasedV13.store` and `ReleasedV15.store` fixtures generated from each tag's unchanged sources. The v1.1–v1.3 fixtures retain the original `Fuelio` module name, so they also exercise the app rename to `PumpTally`. Each contains 800 records across imperial and metric vehicles over five years. Tests compare every stored numeric field bit for bit and verify metadata and ownership through migration, full-row writes and reopening. Separate tests also rebuild startup caches and merge the v1.1–v1.3 copies, then check original business values after reopening. The exact first distributed binary has not been inspected; source-tag fixtures and public version labels do not prove that binary’s provenance. These checks cover upgrades on the tested simulator runtime and do not establish that an older app can reopen an already migrated store. The minimum deployment target remains iOS 17.0; record the exact tested patch runtimes when reporting coverage. A check on iOS 17.5 does not establish coverage of iOS 17.0.

Schema V6 replaces the required SwiftData vehicle relationship with optional backing storage mapped from the original `vehicle` name. The app-facing `vehicle` accessor and CloudKit wire fields remain unchanged. This lets iOS 17 maintain the inverse when creating records for an already managed vehicle. Frozen V5 definitions preserve the preceding store layout; the explicit V5→V6 custom stage rejects missing ownership rather than guessing or dropping a record. Vehicle deletion explicitly detaches and deletes children in the same transaction, because iOS 17's cascade can leave them behind. Tests preserve every numeric bit and retained sync/recovery byte through migration, full-row writes and reopening, using the independent V5 fixture as well as all earlier released fixtures.

Preserve the existing CloudKit record types, identifiers, scalar fields and measurement basis. New measurement envelopes and display preferences are additive. Older clients can read the original scalar values. Incoming legacy numeric edits or storage-unit changes that cannot be interpreted safely remain in the durable inbox for explicit unit confirmation; they must never be guessed or discarded. Mixed-version sync can therefore require review rather than applying every old-client edit automatically. Wire-contract and legacy-writer cases run in `CloudSyncServiceTests` and `SyncSafetyTests`.

Assume older released clients remain active; their installed count is unknown. They share the existing CloudKit zone and cannot honor the new generation guard. The app therefore refuses bulk iCloud replacement before changing either data copy, preferences or receipts. Settings offers merge and use-iCloud choices, and sync details offers counts; neither offers replacement. The direct replacement API and the initial replacement strategy both reject the operation, with no confirmation or preference that bypasses the restriction. Pending replacement receipts and backups remain intact; startup stops sync and reports the restriction instead of resuming their publication. Completed receipts do not block normal activation. The retained coordinator protocol is exercised directly by isolated tests and has no app-service publication path.

This gate prevents the new app from initiating the unsafe replacement. It cannot stop an older app from deleting or replacing the shared zone itself; new-client generation/zone-deletion checks must continue to pause sync and preserve local values when that happens. Ordinary sync and explicit merge remain available. Do not re-enable bulk replacement based on a usage count, a client-version registry, or an instruction to update or close other devices: offline or unknown legacy clients cannot be ruled out that way.

## Live CloudKit tests

The separate `CloudKitProtocol` scheme uses the `CloudKitProbe` app and only the Development container `iCloud.me.tianshilei.fuelio.CloudKitProbe`. It has no access to the PumpTally store. Tests create uniquely named synthetic zones and remove them after successful test scopes.

On November 8, 2026, all nine native protocol tests passed on a physical iPhone 17 Pro Max running iOS 27.2 (24B119), built with Xcode 27.2 (27B52). There were no failures, skips or reported runtime warnings. Signed-binary isolation verification passed before installation. All nine synthetic zone scopes acknowledged cleanup.

The live checks cover exact Double and wire-date values, fresh/stale guarded saves and deletes, 800-record bounded publication, SDK-sized batches of 250/250/250/54 changes, cancellation at a held delegate boundary and the production guarded adapter. Competing engines run on one phone. App-level two-device delivery, offline/reconnect and account-change scenarios remain separate release checks, alongside production schema verification. Passing the probe does not reenable bulk iCloud replacement.

Connect and unlock an iPhone 17 Pro Max with Developer Mode enabled and an existing iCloud sign-in. A second account and simulator sign-in are unnecessary. Provision the probe's separate container using the settings in `Config/CloudKitProbe.xcconfig`.

Find the phone identifier with `xcodebuild -project PumpTally.xcodeproj -scheme CloudKitProtocol -showdestinations`. Build the probe, verify its actual signed entitlements, and run only after verification succeeds:

```sh
xcodebuild build-for-testing -project PumpTally.xcodeproj -scheme CloudKitProtocol -destination 'platform=iOS,id=<phone-identifier>' -derivedDataPath /private/tmp/pumptally-cloudkit-probe -allowProvisioningUpdates
python3 scripts/verify_cloudkit_probe.py /private/tmp/pumptally-cloudkit-probe/Build/Products/Testing-iphoneos/CloudKitProbe.app
xcodebuild test-without-building -project PumpTally.xcodeproj -scheme CloudKitProtocol -destination 'platform=iOS,id=<phone-identifier>' -derivedDataPath /private/tmp/pumptally-cloudkit-probe -resultBundlePath /private/tmp/pumptally-cloudkit-protocol.xcresult -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 240
```

Choose a new result-bundle path for each run. Missing configuration or account access fails explicitly. Keep test runs sequential. These live tests are excluded from the ordinary offline suite and do not deploy production schema changes.

## Production CloudKit schema

Before releasing the generation-guarded sync implementation, deploy these additive fields to the application's production container:

| Record type | Fields |
| --- | --- |
| `PumpTallySyncControl` | `version` (Int64), `generation`, `phase`, `transaction` (String) |
| `Vehicle` | `displayUnitSystemRaw`, `syncGenerationV1` (String) |
| `FuelingRecord` | `measurementsV1` (Bytes), `syncGenerationV1` (String) |

Preserve all existing record types and fields. The control uses direct record identifiers and needs no new query indexes. Verify migration behavior on the minimum supported iOS version before release.

Bulk replacement remains disabled even after these fields are deployed. The retained protocol spans multiple guarded batches and cannot fence older writers. Retained recovery snapshots are local to the app and are not included in CSV exports; CSV is an exchange format, not a complete application backup.
