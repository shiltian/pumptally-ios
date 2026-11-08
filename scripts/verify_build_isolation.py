#!/usr/bin/env python3
"""Reject test bootstrap sources, fixture strings or bundle IDs in production builds."""
import plistlib
import subprocess
import sys
from pathlib import Path

derived = Path(sys.argv[1])
for configuration in sys.argv[2:] or ("Debug", "Release"):
    build = derived / "Build/Intermediates.noindex/PumpTally.build" / f"{configuration}-iphonesimulator/PumpTally.build"
    lists = list(build.glob("**/PumpTally.SwiftFileList"))
    assert lists, f"Missing compiler source list for {configuration}"
    isolated = configuration == "Benchmark"
    for file_list in lists:
        sources = file_list.read_text()
        assert "CloudSyncMappingHarness.swift" not in sources, f"Unit-only harness in application: {configuration}"
        assert "SyncQAAppBootstrap.swift" not in sources, f"Live QA container in ordinary application: {configuration}"
        assert ("ProductionAppBootstrap.swift" in sources) != isolated, f"Incorrect composition: {configuration}"
        assert ("TestingAppBootstrap.swift" in sources) == isolated, f"Incorrect test composition: {configuration}"
        assert ("TestingCloudSyncEnvironment.swift" in sources) == isolated, f"Incorrect transport: {configuration}"
        assert ("TestingRecoveryScenario.swift" in sources) == isolated, f"Incorrect recovery fixture composition: {configuration}"
    app = derived / "Build/Products" / f"{configuration}-iphonesimulator/PumpTally.app"
    with (app / "Info.plist").open("rb") as source:
        expected_bundle = "me.tianshilei.fuelio.benchmark" if isolated else "me.tianshilei.fuelio"
        assert plistlib.load(source)["CFBundleIdentifier"] == expected_bundle
    for binary in [app / "PumpTally", *app.glob("PumpTally.debug.dylib")]:
        strings = subprocess.check_output(["strings", "-a", str(binary)])
        for unit_only in (b"CloudSyncMappingHarness", b"observeOnMainActor", b"iCloud.me.tianshilei.fuelio.CloudKitProbe"):
            assert unit_only not in strings, f"Unit-only harness in {binary}: {unit_only!r}"
        for forbidden in (b"--ui-testing", b"UI Test Vehicle", b"TestingCloudSyncEnvironment", b"TestingRecoveryScenario", b"Recovery test checkpoint", b"isolated-test-account"):
            if not isolated:
                assert forbidden not in strings, f"Fixture found in {binary}: {forbidden!r}"
    print(f"{configuration}: composition and binary isolation verified")
