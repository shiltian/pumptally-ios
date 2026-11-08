#!/usr/bin/env python3
"""Install real historical apps, populate through UI, then upgrade without uninstalling.

Only disposable simulators and an entitlement-free, isolated bundle ID are used.
The old application sources are extracted verbatim from Git tags. The current
application uses its normal Release bootstrap, default disk store and preferences.
No migration experiments run on a physical device or an existing simulator.
"""

import argparse
import copy
import hashlib
import io
import json
from pathlib import Path
import plistlib
import shutil
import sqlite3
import struct
import subprocess
import tarfile
import uuid


REPO = Path(__file__).resolve().parents[1]
BUNDLE = "me.tianshilei.fuelio.upgrade"
BUILD_DESTINATION = "platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest"
RUNTIMES = {
    "17.5": ("iPhone-15-Pro-Max", "iOS-17-5"),
    "18.6": ("iPhone-16-Pro-Max", "iOS-18-6"),
    "26.5": ("iPhone-17-Pro-Max", "iOS-26-5"),
    "27.2": ("iPhone-17-Pro-Max", "iOS-27-2"),
}
TAGS = ["v1.1", "v1.2", "v1.3", "v1.4", "v1.5"]


def run(arguments, log=None):
    if log:
        with Path(log).open("w") as output:
            result = subprocess.run(arguments, cwd=REPO, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}); see {log}")
        return ""
    return subprocess.check_output(arguments, cwd=REPO, text=True).strip()


def json_write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def scalar(value):
    if isinstance(value, float):
        return {"doubleBits": struct.pack(">d", value).hex()}
    if isinstance(value, bytes):
        return {"bytes": value.hex()}
    return value


def sqlite_snapshot(store, destination):
    """Read a stopped app's actual SQLite/WAL store without running migration."""
    source = sqlite3.connect(store.as_uri() + "?mode=ro", uri=True)
    backup = sqlite3.connect(destination)
    try:
        source.backup(backup)
        backup.row_factory = sqlite3.Row
        assert [r[0] for r in backup.execute("PRAGMA integrity_check")] == ["ok"]
        tables = {r[0] for r in backup.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        assert {"ZVEHICLE", "ZFUELINGRECORD"} <= tables
        vehicles = [dict(r) for r in backup.execute("SELECT * FROM ZVEHICLE")]
        records = [dict(r) for r in backup.execute("SELECT * FROM ZFUELINGRECORD")]
        owners = {v["Z_PK"]: v["ZID"].hex() for v in vehicles}
        business = {"vehicles": {}, "records": {}}
        caches = {"vehicles": {}, "records": {}}
        for kind, rows, fields in [
            ("vehicles", vehicles, ["ZNAME", "ZMAKE", "ZMODEL", "ZYEAR", "ZCREATEDAT", "ZMODIFIEDAT", "ZUNITSYSTEMRAW"]),
            ("records", records, ["ZDATE", "ZODOMETER", "ZPRICEPERFUELUNIT", "ZFUELAMOUNT", "ZTOTALCOST", "ZFILLUPTYPERAW", "ZNOTES", "ZCREATEDAT", "ZMODIFIEDAT"]),
        ]:
            for row in rows:
                identifier = row["ZID"].hex()
                values = {key: scalar(row.get(key)) for key in fields}
                if kind == "records":
                    owner = row.get("ZVEHICLERELATIONSHIP", row.get("ZVEHICLE"))
                    assert owner in owners, f"Unowned persisted record {identifier}"
                    values["ownerID"] = owners[owner]
                business[kind][identifier] = values
                caches[kind][identifier] = {
                    key: scalar(value) for key, value in row.items()
                    if key.startswith("ZCACHED") or key == "ZCACHELASTUPDATED"
                }
            assert len(business[kind]) == len(rows), f"Duplicate {kind} identifiers"
        counts = {table: backup.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
                  for table in tables if table.startswith("Z") and not table.startswith("Z_")}
        return {"business": business, "caches": caches, "entityCounts": counts}
    finally:
        backup.close()
        source.close()


def data_container(device):
    path = Path(run(["xcrun", "simctl", "get_app_container", device, BUNDLE, "data"]))
    assert "CoreSimulator/Devices/" in str(path)
    return path


def snapshot(device, destination):
    container = data_container(device)
    stores = list((container / "Library" / "Application Support").glob("*.store"))
    assert len(stores) == 1, stores
    destination.mkdir(parents=True, exist_ok=True)
    value = sqlite_snapshot(stores[0], destination / "database.store")
    prefs = container / "Library" / "Preferences" / (BUNDLE + ".plist")
    preferences = plistlib.loads(prefs.read_bytes()) if prefs.exists() else {}
    value["preferences"] = {key: scalar(v) for key, v in preferences.items()}
    marker = container / "Documents" / "upgrade-sentinel.json"
    value["sentinel"] = json.loads(marker.read_text()) if marker.exists() else None
    value["storeRelativePath"] = str(stores[0].relative_to(container))
    json_write(destination / "snapshot.json", value)
    return value


def restore_population(device, source):
    """Restore only a synthetic store previously created by the full old app.

    The historical app rebuilt with the current SDK traps in its required
    relationship setter during CSV import on iOS 17. Keep that evidence and
    explicitly label this separate, restored-state installation-upgrade path.
    """
    baseline = json.loads((source / "snapshot.json").read_text())
    container = data_container(device)
    relative = Path(baseline["storeRelativePath"])
    assert relative.parts[:2] == ("Library", "Application Support")
    assert (container / relative).resolve().is_relative_to(container.resolve())
    store = container / relative
    assert not store.exists(), "Restore only into a fresh, never-launched installation"
    store.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source / "database.store", store)
    marker = container / "Documents" / "upgrade-sentinel.json"
    marker.parent.mkdir(parents=True, exist_ok=True)
    json_write(marker, baseline["sentinel"])
    preferences = {}
    for key, value in baseline["preferences"].items():
        preferences[key] = bytes.fromhex(value["bytes"]) if isinstance(value, dict) and "bytes" in value else value
    prefs = container / "Library" / "Preferences" / (BUNDLE + ".plist")
    prefs.parent.mkdir(parents=True, exist_ok=True)
    prefs.write_bytes(plistlib.dumps(preferences, fmt=plistlib.FMT_BINARY))
    return baseline


def compare(before, after, edited=False, added=False):
    """Every legacy business value must survive; only explicit UI edits differ."""
    expected = before["business"]
    actual = after["business"]
    assert before["sentinel"] == after["sentinel"]
    assert before["storeRelativePath"] == after["storeRelativePath"]
    assert expected["vehicles"] == actual["vehicles"], "Vehicle business values changed"
    original_ids = set(expected["records"])
    new_ids = set(actual["records"]) - original_ids
    assert original_ids <= set(actual["records"]), "Existing records were removed"
    assert len(new_ids) == int(added), new_ids
    changed_notes = 0
    for identifier, original in expected["records"].items():
        current = dict(actual["records"][identifier])
        if edited and original["ZNOTES"] == "UPGRADE Metric record 399":
            note = current["ZNOTES"]
            assert isinstance(note, str) and "[upgrade reviewed]" in note
            assert original["ZNOTES"] in note
            assert current["ZMODIFIEDAT"] is not None
            current["ZNOTES"] = original["ZNOTES"]
            current["ZMODIFIEDAT"] = original["ZMODIFIEDAT"]
            changed_notes += 1
        assert current == original, f"Existing record changed: {identifier}: {original} -> {current}"
    assert changed_notes == int(edited)
    if not added:
        assert before["caches"] == after["caches"], "Startup or a notes-only edit rewrote cached values"
    if added:
        new = actual["records"][next(iter(new_ids))]
        assert new["ZODOMETER"] == scalar(500000.987654321)
        assert new["ZPRICEPERFUELUNIT"] == scalar(3.5)
        assert new["ZFUELAMOUNT"] == scalar(10.0)
        assert new["ZTOTALCOST"] == scalar(35.0)
        metric_id = next(key for key, vehicle in expected["vehicles"].items() if vehicle["ZNAME"] == "Upgrade Metric")
        assert new["ownerID"] == metric_id
    # The UI visits the same last-viewed vehicle, and the user's existing unit
    # preferences and sync settings remain intact. Runtime-owned new keys may be added.
    for key, value in before["preferences"].items():
        if key == "lastViewedVehicleID" or key.startswith("metricEfficiencyFormat") or key in ["iCloudSyncEnabled", "initialSyncCompleted"]:
            assert after["preferences"].get(key) == value, (key, value, after["preferences"].get(key))
    assert not after["preferences"].get("iCloudSyncEnabled", False)


def extract_tag(root, tag):
    target = root / "sources" / tag
    target.mkdir(parents=True, exist_ok=True)
    content = subprocess.check_output(["git", "archive", "--format=tar", tag], cwd=REPO)
    with tarfile.open(fileobj=io.BytesIO(content)) as archive:
        swift_sources = {}
        for entry in archive.getmembers():
            assert (target / entry.name).resolve().is_relative_to(target.resolve())
            assert entry.isfile() or entry.isdir()
            if entry.isfile() and entry.name.endswith(".swift"):
                swift_sources[entry.name] = hashlib.sha256(archive.extractfile(entry).read()).hexdigest()
        archive.extractall(target)
    for name, checksum in swift_sources.items():
        assert hashlib.sha256((target / name).read_bytes()).hexdigest() == checksum
    json_write(root / (tag + "-source-hashes.json"), swift_sources)
    project = next(target.glob("*.xcodeproj"))
    return project, project.stem


def verify_app(app, old_version=None):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == BUNDLE
    assert info["DTPlatformName"] == "iphonesimulator"
    if old_version:
        assert info["CFBundleShortVersionString"] == old_version.removeprefix("v")
    assert not (app / "embedded.mobileprovision").exists()
    signed = subprocess.run(["codesign", "--display", "--entitlements", "-", "--xml", str(app)],
                            capture_output=True)
    if signed.stdout:
        entitlements = plistlib.loads(signed.stdout)
        assert not any("icloud" in key.lower() or "application-groups" in key.lower() for key in entitlements)
    return {key: info.get(key) for key in ["CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion", "DTSDKName", "DTXcodeBuild"]}


def build(root, tag, destination):
    if tag == "current":
        project, scheme = REPO / "PumpTally.xcodeproj", "PumpTally"
    else:
        project, scheme = extract_tag(root, tag)
    derived = root / "builds" / tag
    app = derived / "Build" / "Products" / "Release-iphonesimulator" / (scheme + ".app")
    # Always ask Xcode to build the requested sources. Its incremental cache is
    # reusable; an existing .app alone is never proof that it matches the code.
    run(["xcodebuild", "-project", str(project), "-scheme", scheme, "-configuration", "Release",
         "-destination", destination, "-derivedDataPath", str(derived),
         "build", f"PRODUCT_BUNDLE_IDENTIFIER={BUNDLE}", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGN_ENTITLEMENTS=",
         "SWIFT_EMIT_LOC_STRINGS=NO"], root / f"build-{tag}-release.log")
    filelist = next((derived / "Build" / "Intermediates.noindex").rglob(f"Release-iphonesimulator/{scheme}.build/Objects-normal/arm64/{scheme}.SwiftFileList"))
    sources = filelist.read_text().splitlines()
    assert all("/PumpTallyTests/" not in path and "/FuelioTests/" not in path for path in sources)
    if tag == "current":
        assert any(path.endswith("/ProductionAppBootstrap.swift") for path in sources)
        assert not any(Path(path).name.startswith("Testing") for path in sources)
    info = verify_app(app, None if tag == "current" else tag)
    info["sourceCommit"] = run(["git", "rev-parse", "HEAD" if tag == "current" else tag])
    info["executableSHA256"] = hashlib.sha256((app / info["CFBundleExecutable"]).read_bytes()).hexdigest()
    info["compilerSources"] = sources
    return app, info


def run_ui(root, device, name, method):
    products = root / "runner" / "Build" / "Products"
    original = plistlib.loads(next(products.glob("*.xctestrun")).read_bytes())
    target = copy.deepcopy(original["PumpTallyUITests"])

    def expand(value):
        if isinstance(value, str):
            return value.replace("__TESTROOT__", str(products))
        if isinstance(value, list):
            return [expand(x) for x in value]
        if isinstance(value, dict):
            return {k: expand(v) for k, v in value.items()}
        return value

    target = expand(target)
    target["SkipTestIdentifiers"] = []
    target["OnlyTestIdentifiers"] = ["InPlaceUpgradeUITests/" + method]
    configuration = root / (name + ".xctestrun")
    configuration.write_bytes(plistlib.dumps({"PumpTallyUITests": target, "__xctestrun_metadata__": original["__xctestrun_metadata__"]}))
    result = root / (name + ".xcresult")
    run(["xcodebuild", "test-without-building", "-xctestrun", str(configuration),
         "-destination", f"platform=iOS Simulator,id={device}", "-resultBundlePath", str(result),
         "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
         "-default-test-execution-time-allowance", "300", "-maximum-test-execution-time-allowance", "360"],
        root / (name + ".log"))
    summary = json.loads(run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)]))
    json_write(root / (name + "-summary.json"), summary)
    assert (summary["passedTests"], summary["failedTests"], summary["skippedTests"]) == (1, 0, 0)
    return str(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, default=Path("/private/tmp/pumptally-inplace-upgrade"))
    parser.add_argument("--tags", nargs="+", choices=TAGS, default=TAGS)
    parser.add_argument("--runtimes", nargs="+", choices=RUNTIMES, default=["27.2", "18.6", "26.5"])
    parser.add_argument("--build-destination", default=BUILD_DESTINATION,
                        help="Xcode build destination; defaults to iPhone 17 Pro Max on the latest runtime")
    parser.add_argument("--restore-population-report", type=Path,
                        help="Explicit iOS 17 restored-state coverage using successful UI-populated iOS 27 cases")
    parser.add_argument("--keep-simulators", action="store_true")
    args = parser.parse_args()
    root = args.work_dir.resolve()
    assert root.is_relative_to(Path("/private/tmp")), "Use an isolated temporary work directory"
    root.mkdir(parents=True, exist_ok=True)
    population = {}
    if args.restore_population_report:
        assert args.runtimes == ["17.5"], "Keep restored-state coverage separate and explicitly labelled"
        prior = json.loads(args.restore_population_report.read_text())
        for tag in args.tags:
            case = next(c for c in prior["cases"] if c["tag"] == tag and c["runtime"] == "27.2" and c["passed"])
            source_name = Path(case["results"][0]).name.removesuffix("-seed.xcresult")
            population[tag] = args.restore_population_report.parent / source_name / "before"
    run_id = uuid.uuid4().hex[:8]
    apps = {tag: build(root, tag, args.build_destination) for tag in args.tags + ["current"]}
    run(["xcodebuild", "-project", str(REPO / "PumpTally.xcodeproj"), "-scheme", "PumpTally",
         "-configuration", "Testing", "-destination", args.build_destination,
         "-derivedDataPath", str(root / "runner"), "build-for-testing", "CODE_SIGNING_ALLOWED=NO",
         "SWIFT_EMIT_LOC_STRINGS=NO"], root / "build-runner.log")
    report = {"sourceCommit": run(["git", "rev-parse", "HEAD"]), "buildDestination": args.build_destination,
              "runID": run_id, "cases": [], "devices": []}
    report_path = root / ("report-" + run_id + ".json")
    for runtime in args.runtimes:
        model, system = RUNTIMES[runtime]
        device = run(["xcrun", "simctl", "create", f"PumpTally Upgrade Validation {run_id} iOS {runtime}",
                      "com.apple.CoreSimulator.SimDeviceType." + model, "com.apple.CoreSimulator.SimRuntime." + system])
        report["devices"].append(device)
        json_write(report_path, report)
        run(["xcrun", "simctl", "boot", device])
        run(["xcrun", "simctl", "bootstatus", device, "-b"], root / f"boot-{run_id}-{runtime}.log")
        for index, tag in enumerate(args.tags):
            # Independent cases start empty. NEVER uninstall between the old app
            # and the current app within a case.
            if index:
                run(["xcrun", "simctl", "uninstall", device, BUNDLE])
            name = f"{run_id}-{runtime}-{tag}"
            directory = root / name
            print(f"Starting full installation upgrade {tag} -> current on iOS {runtime}", flush=True)
            run(["xcrun", "simctl", "install", device, str(apps[tag][0])])
            if population:
                restored = restore_population(device, population[tag])
                seed = run_ui(root, device, name + "-historical-read", "testReadRestoredHistoricalInstallation")
            else:
                container = data_container(device)
                marker = container / "Documents" / "upgrade-sentinel.json"
                marker.parent.mkdir(parents=True, exist_ok=True)
                json_write(marker, {"runID": run_id, "sourceTag": tag, "nonce": str(uuid.uuid4())})
                seed = run_ui(root, device, name + "-seed", "testPopulateHistoricalInstallation")
            before = snapshot(device, directory / "before")
            if population:
                assert before == restored, "The historical app changed restored state before upgrade"
            assert len(before["business"]["vehicles"]) == 2
            assert len(before["business"]["records"]) == 801
            assert not before["preferences"].get("iCloudSyncEnabled", False)
            run(["xcrun", "simctl", "install", device, str(apps["current"][0])])
            installed = snapshot(device, directory / "installed-before-launch")
            assert installed == before, "Installation changed persisted files before first launch"
            opened = run_ui(root, device, name + "-open", "testOpenUpgradedInstallation")
            after_open = snapshot(device, directory / "after-open")
            compare(before, after_open)
            edited = run_ui(root, device, name + "-edit", "testEditUpgradedInstallation")
            after_edit = snapshot(device, directory / "after-edit")
            compare(before, after_edit, edited=True)
            added = run_ui(root, device, name + "-add", "testAddRecordAfterUpgrade")
            after_add = snapshot(device, directory / "after-add")
            compare(before, after_add, edited=True, added=True)
            reopened = run_ui(root, device, name + "-reopen", "testReopenSavedUpgrade")
            after_reopen = snapshot(device, directory / "after-reopen")
            compare(before, after_reopen, edited=True, added=True)
            assert after_reopen == after_add, "Cold relaunch changed saved values or sync state"
            assert after_open["entityCounts"]["ZSYNCCHANGE"] == 0
            assert after_edit["entityCounts"]["ZSYNCCHANGE"] == 1
            assert after_reopen["entityCounts"]["ZSYNCCHANGE"] == 2
            case = {"runtime": runtime, "tag": tag, "oldBuild": apps[tag][1], "newBuild": apps["current"][1],
                    "legacyRecords": 801, "finalRecords": 802, "results": [seed, opened, edited, added, reopened], "passed": True}
            case["populationMode"] = "restored-old-app-state" if population else "historical-app-UI"
            case["populationRuntime"] = "27.2" if population else runtime
            if population:
                case["populationEvidence"] = str(population[tag])
            report["cases"].append(case)
            json_write(report_path, report)
            print(f"PASS {tag} / iOS {runtime}: 801 legacy records preserved exactly; edit and new save reopened", flush=True)
        run(["xcrun", "simctl", "shutdown", device])
        if not args.keep_simulators:
            run(["xcrun", "simctl", "delete", device])
    print(f"Completed {len(report['cases'])} in-place upgrade cases; evidence: {report_path}", flush=True)


if __name__ == "__main__":
    main()
