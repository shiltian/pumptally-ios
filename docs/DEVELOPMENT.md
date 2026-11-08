# Development

Shared build settings live in `Config/`. The [CI workflow](../.github/workflows/ios.yml) defines the verified toolchain and commands for functional/UI tests, optimized persistence and performance tests, Thread Sanitizer, production analysis and Release builds.

## Local checks

Use **iPhone 17 Pro Max** as the build and test destination. The `PumpTally` scheme's Test action selects the isolated `Testing` configuration; do not override it with Debug or Release. Test storage, preferences and CloudKit responses are separate from the shipping app. Production builds exclude the test bootstrap and fixtures.

The `PumpTallyBenchmarks` scheme selects Release optimization with isolated test dependencies. Run performance cases separately from functional tests; the CI workflow lists the individual suites.

`VehicleHistoryPerformanceTests` measures cold fetch/index/chart preparation for single-vehicle histories of 800, 3,200 and 12,800 records, plus cached search and paging at 12,800. Fixture creation is excluded. The UI receives 50-row pages and at most 200 chart points per series; the background value catalog and exact chart summaries still cover the whole vehicle history. Search/sort/page requests reuse that catalog until a relevant save. Native save generation and request checks reject stale results. These measurements cover read preparation, not complete screen-rendering latency; preserve the result metrics rather than asserting a portable timing budget.

Check formatting on changed Swift lines, or add `--fix` to apply changes:

```sh
python3 scripts/swift_format.py
```

Persistence migrations use `VersionedSchema` and `SchemaMigrationPlan`. Test them with copies of the immutable stores in `PumpTallyTests/Fixtures`, preserving existing business values through save and reopen. Never run migration experiments against a live user store.

## Live CloudKit tests

The separate `CloudKitProtocol` scheme uses the `CloudKitProbe` app and only the Development container `iCloud.me.tianshilei.fuelio.CloudKitProbe`. It has no access to the PumpTally store. Tests create uniquely named synthetic zones and remove them after successful test scopes.

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
| `Vehicle` | `syncGenerationV1` (String) |
| `FuelingRecord` | `syncGenerationV1` (String) |

Preserve all existing record types and fields. The control uses direct record identifiers and needs no new query indexes. Verify migration behavior on the minimum supported iOS version before release.

Update or close older PumpTally clients before replacing iCloud data: they do not implement the generation guard. Replacement spans multiple guarded batches rather than one transaction over the entire dataset. Retained recovery snapshots are local to the app and are not included in CSV exports; CSV is an exchange format, not a complete application backup.
