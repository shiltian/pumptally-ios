# In-place installation upgrade checks

`scripts/test_in_place_upgrades.py` tests complete historical applications and the current Release application. It complements the immutable copied-store tests in `SchemaMigrationTests`.

## What runs

The harness extracts the complete v1.1–v1.5 source tags and builds them with the installed Xcode SDK. Historical Swift source bytes are checked against their Git archives. Their original `Fuelio` or `PumpTally` module names remain intact. The current build includes `ProductionAppBootstrap` and excludes test factories. All applications use the same isolated bundle identifier, `me.tianshilei.fuelio.upgrade`, with signing and iCloud entitlements disabled.

Only disposable simulators created by the harness are used. Each independent version case starts with an empty installation. Within a case, the current application is installed over the historical application **without uninstalling**. An app-data sentinel, database values and preferences are compared before its first launch.

For direct UI population, the historical application creates two vehicles through its own forms, imports 400 precision-sensitive records per vehicle through its CSV screen, and saves one additional fill through its record form. The 801-record baseline includes imperial/metric storage, over five years of record dates, full/partial/reset fills, fractional values, Unicode and empty notes. v1.5 also exercises a nondefault per-vehicle fuel-economy preference.

After replacement, the current application must:

1. Open its normal default store and restore the last-viewed vehicle.
2. Preserve every original business number bit for bit, plus UUIDs, dates, notes, ownership, vehicle metadata and existing relevant preferences.
3. Preserve all cached values during startup and a notes-only edit.
4. Save the explicit notes edit without rewriting any other legacy business field.
5. Add one new record, keeping all 801 original records intact.
6. Reopen after termination with the same saved state, 802 records and exactly two new outgoing intents.

The comparison reads the stopped application's actual SQLite/WAL store through SQLite's read-only backup API. It does not open a second SwiftData container or run a different migration before checking the result. SQLite integrity and unique business identifiers are checked as well. UI labels provide additional startup/navigation evidence; the numeric assertions use stored IEEE-754 bits.

## Verified results — November 8, 2026

All 20 installation upgrades passed using Xcode 27.2 (27B52), from the five source tags to the current v1.6/build 16 Release application at `7483568`. No production application, persistence or schema changes were needed for these checks.

| Historical version | iOS 17.5 | iOS 18.6 | iOS 26.5 | iOS 27.2 |
| --- | --- | --- | --- | --- |
| v1.1, unversioned V1 | Passed, restored state | Passed, UI populated | Passed, UI populated | Passed, UI populated |
| v1.2, V2 | Passed, restored state | Passed, UI populated | Passed, UI populated | Passed, UI populated |
| v1.3, V2 | Passed, restored state | Passed, UI populated | Passed, UI populated | Passed, UI populated |
| v1.4, V2 | Passed, restored state | Passed, UI populated | Passed, UI populated | Passed, UI populated |
| v1.5, V2 | Passed, restored state | Passed, UI populated | Passed, UI populated | Passed, UI populated |

These are **15 direct UI-populated cases and five explicitly restored historical-state cases**, comprising 100 passing UI phases and 120 checked database snapshots. Every case preserved the 801 original records' business numbers bit for bit, plus ownership and metadata, apart from the one intentional notes/modified-date edit. Each ended with 802 records, two outgoing intents and all checked values unchanged after a cold relaunch. SQLite integrity and duplicate-ID checks passed throughout. Result summaries reported no runtime test issues; raw simulator/framework diagnostics remain in the logs. A historical-app screenshot and upgraded history screenshots from all four runtimes were inspected.

Builds used iPhone 17 Pro Max; execution used iPhone 15 Pro Max on 17.5 (21F79), iPhone 16 Pro Max on 18.6 (22G86), and iPhone 17 Pro Max on 26.5 (23F77) and 27.2 (24B8117). This does not establish patch-level coverage of iOS 17.0. All six disposable test/diagnostic simulators were removed; the original simulator and downloaded runtimes were retained.

Evidence under `/private/tmp/pumptally-inplace-upgrade`:

- `report-f1ee4d77.json`: five direct iOS 27.2 cases. The separate failed historical iOS 17 population attempt is explained below.
- `report-2e402377.json`: ten direct iOS 18.6/26.5 cases.
- `report-d31b8412.json`: five restored-state iOS 17.5 cases, with their population evidence linked explicitly.
- `final-audit.json`: all 20 unique version/runtime pairs, phase results, snapshot counts and verified historical Swift-source hashes/commits.

Result bundles, phase logs, read-only database copies and preference snapshots accompany those reports. Temporary evidence may disappear after a restart; this matrix and the committed harness retain the scope and method.

## Running the direct cases

Install the required runtimes through Xcode, then run from the repository root:

```sh
python3 scripts/test_in_place_upgrades.py --runtimes 27.2 18.6 26.5
```

The script builds for iPhone 17 Pro Max and runs tests sequentially. `--build-destination` can select a specific iPhone 17 Pro Max destination if needed. It records the exact builds, compiler inputs, executable hashes, original source hashes, per-phase result bundles and database snapshots under `/private/tmp/pumptally-inplace-upgrade`. Each completed runtime's disposable simulator is removed by default. Failed cases retain their simulator and evidence for diagnosis. No user simulator or downloaded runtime is removed.

`InPlaceUpgradeUITests` is excluded from the ordinary test action. The orchestration script explicitly selects each phase and controls installation order. Its UI runner's normal `.testing` target is a different bundle from the historical/current `.upgrade` application and cannot replace that application's data.

## iOS 17 population limitation and restored-state cases

Rebuilt v1.1 source crashes on iOS 17.5 in SwiftData's required `FuelingRecord.vehicle` setter when the original CSV callback reassigns ownership. This occurs inside the historical app before upgrading; that attempt wrote no imported records. A separate form-entry diagnostic persisted one owned record, while its historical summary sheet rendered blank. These findings are retained separately from successful upgrade results. Historical model or application source is not modified to bypass them.

For large-store iOS 17 coverage, use the explicit restored-state mode with a report containing successful UI-populated iOS 27.2 cases:

```sh
python3 scripts/test_in_place_upgrades.py --runtimes 17.5 \
  --restore-population-report /private/tmp/pumptally-inplace-upgrade/report-<run-id>.json
```

This restores the database, preferences and sentinel created by the complete historical app into a fresh installation of that same old app on iOS 17. The unchanged old app must launch, display its records and leave the entire baseline unchanged before the current application is installed over it. The subsequent startup/edit/add/relaunch checks are identical. Reports explicitly distinguish the population runtime and `restored-old-app-state` mode from direct UI-populated cases.

These are source-tag rebuilds using the current SDK. The exact originally distributed App Store binaries and their original SDK-generated code are unavailable. The tests establish the recorded installation/store transitions and do not establish every possible shipped binary, every user database, or mixed-version live iCloud behavior. All cloud work remains disabled during these upgrade checks.
