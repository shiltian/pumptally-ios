# Two-device app sync checks

Use the separate **SyncQA** scheme for full-application live sync checks. It uses the real application's models, migration plan, writer, lifecycle, UI and native CloudKit transport. Its local app identifier is `me.tianshilei.fuelio.SyncQA`, display name **PumpTally Sync QA**, and only signed cloud container is `iCloud.me.tianshilei.fuelio.CloudKitProbe` in **Development**. Ordinary Debug/Release/Testing configurations exclude the QA bootstrap. The Testing app uses a fake cloud transport and cannot establish live delivery.

The compile-time QA bootstrap explicitly constructs `CKContainer(identifier:)` for that test container and supplies it to the existing native environment. Do not rely on `CKContainer.default()` when using a different bundle identifier: the first setup attempt requested a nonexistent `iCloud.me.tianshilei.fuelio.SyncQA` container despite the restricted entitlements, so activation failed before delivery. The shipping bootstrap remains unchanged. No runtime switch, fake transport, fixture hook or production schema change is needed. The native protocol probe shares this test container but uses its own app and uniquely named zones; the full QA app uses its ordinary `FuelioZone`. Use only synthetic test records here.

## Prepare and verify

Both phones need the same iCloud Apple Account, networking, Developer Mode, and pairing/trust with Xcode. Keep their existing OS versions and record the exact model/build; “latest” alone is not a reproducible version. Do not switch the owner's iCloud account for these checks. Account-transition testing requires a separate planned test setup.

Build for the iPhone 17 Pro Max, using its device identifier:

```sh
xcodebuild -project PumpTally.xcodeproj -scheme SyncQA -configuration SyncQA \
  -destination 'platform=iOS,id=<iPhone-17-Pro-Max-identifier>' \
  -derivedDataPath /private/tmp/pumptally-sync-qa \
  -allowProvisioningUpdates clean build SWIFT_EMIT_LOC_STRINGS=NO
python3 scripts/verify_sync_qa.py /private/tmp/pumptally-sync-qa
```

A newly registered test phone also needs inclusion in the development provisioning profile. Xcode can register it using that phone's destination with `-allowProvisioningDeviceRegistration -allowProvisioningUpdates`. Rebuild cleanly and rerun verification after profile updates. Confirm `ProvisionedDevices` includes both phones before installation.

Verification rejects the shipping bundle, a production cloud environment/container, shared app-data entitlements, an invalid signature, a missing profile, the default-container bootstrap, test composition and fake-transport strings. Install only after it passes. The QA scheme is for running/analyzing; use the ordinary PumpTally scheme for the isolated automated tests. Production/benchmark isolation checks also reject the QA bootstrap and test-container string.

Install the verified app on each phone:

```sh
xcrun devicectl device install app --device <phone-identifier> \
  /private/tmp/pumptally-sync-qa/Build/Products/SyncQA-iphoneos/PumpTally.app
```

## Check sequence

Record pass/fail, exact build, both device OS versions and any error text for each step. A synced status label alone is insufficient; inspect the receiving data and compare QA-store snapshots/exports where available.

1. **Initial delivery:** enable iCloud Sync in the QA app on both phones, choosing Merge Both if prompted. Create an Imperial vehicle named Sync Check on the 17 Pro Max and a fill with odometer 1000, fuel 10, price 3.50, total 35.00. Confirm the vehicle and fill reach the SE with the same values.
2. **Reverse edits:** edit that fill's note on the SE. Confirm it reaches the 17 Pro Max without altering numbers, date or ownership. Add a second fill on the SE and confirm delivery in the reverse direction.
3. **Deletion:** delete only the second synthetic fill. Confirm both devices retain the first fill and agree about the deletion after reopening. Test a separate disposable vehicle's deletion and confirm its children disappear together.
4. **Offline/reconnect:** disconnect the SE from both Wi-Fi and cellular. Make distinct synthetic edits on each phone, then reconnect. Confirm both sets arrive without loss/duplication. Exercise concurrent edits separately and verify the app's conflict/review behavior, preserving the original snapshots.
5. **Restart:** terminate/relaunch the QA apps after an acknowledged sync. Recheck data, record identities, ownership and pending/error state. Retain SQLite/WAL files together when copying the stopped QA app's store; never open or copy the published app's store for these experiments.
6. **Mixed clients:** prepare an unchanged historical source-tag app against the same isolated QA bundle/container. An old binary must start with a fresh QA local installation: it must not be installed over the current V6 store. Retain the synthetic data first, remove only that device's QA app, install the old build, then test old/new delivery and edits. Preserve unknown measurement semantics for review rather than guessing. Source-tag rebuilds do not prove exact original App Store binary behavior.
7. **Device workflows:** check CSV export/import through Files and sharing on both screen sizes, then recheck precise stored values. CSV does not contain the complete recovery/inbox state.

Do not reenable bulk iCloud replacement for these tests. It remains blocked because unknown legacy clients cannot honor its generation guard. Production schema deployment and a production-environment/TestFlight smoke test remain separate release gates even after Development delivery passes.

## Current setup — November 8, 2026

- iPhone 17 Pro Max: iOS 27.2 (24B119).
- Connected SE: Xcode identifies it as **iPhone SE (3rd generation)**, iOS 27.0 (24A437), rather than the initially reported second generation. Developer Mode was enabled during setup.
- Current v1.6/build 16 QA app: signed isolation verified, provisioned, installed and launched on both phones. The initial default-container activation failed; the corrected QA-only explicit native-container bootstrap has been rebuilt, verified and installed over both QA apps, retaining their test data. No shipping-app installation or production CloudKit schema/data was changed.
- All 34 focused `ApplicationEnvironmentLoaderTests` and `CloudSyncRuntimeTests` passed on the iPhone 17 Pro Max simulator, with no failures/skips/reported runtime issues. The ordinary Release build and its source/binary isolation checks passed, excluding both the QA bootstrap and the test-container string. The shipping bootstrap and all stored models remain unchanged.
- Initial 17 Pro Max → SE delivery passed. Both stopped QA apps' stores were copied and read through SQLite's backup API. The one vehicle and one fill matched exactly across phones: UUIDs, ownership, every business number's IEEE-754 bits, dates, notes and metadata. SQLite integrity checks passed; both stores had zero outgoing changes and zero retained incoming changes. Evidence: `/private/tmp/pumptally-sync-qa-evidence/first-delivery`, including `comparison.json` and each device's `snapshot.json`/SQLite copies.
- Reverse edits, deletion, offline/reconnect, mixed-client, account-transition and device file-workflow results remain pending. Initial delivery alone does not complete the release gate.

Build, install, launch and device-detail artifacts use `/private/tmp/pumptally-sync-qa*`. These files are temporary; retain actual test outcomes here before release.
