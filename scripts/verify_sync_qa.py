#!/usr/bin/env python3
"""Verify full-app live-sync isolation before installing on a physical phone."""

import argparse
from pathlib import Path
import plistlib
import subprocess
import sys


def verify(derived: Path):
    configuration = "SyncQA"
    app = derived / "Build" / "Products" / (configuration + "-iphoneos") / "PumpTally.app"
    bundle = "me.tianshilei.fuelio.SyncQA"
    container = "iCloud.me.tianshilei.fuelio.CloudKitProbe"
    info = plistlib.loads((app / "Info.plist").read_bytes())
    expected_info = {
        "CFBundleIdentifier": bundle,
        "CFBundleDisplayName": "PumpTally Sync QA",
        "DTPlatformName": "iphoneos",
    }
    for key, value in expected_info.items():
        if info.get(key) != value:
            raise ValueError(f"Unexpected app setting: {key}")
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    entitlements = plistlib.loads(subprocess.check_output(
        ["codesign", "--display", "--entitlements", "-", "--xml", str(app)], stderr=subprocess.DEVNULL))
    expected_entitlements = {
        "com.apple.developer.icloud-container-identifiers": [container],
        "com.apple.developer.icloud-container-environment": "Development",
        "com.apple.developer.icloud-services": ["CloudKit"],
        "aps-environment": "development",
    }
    for key, value in expected_entitlements.items():
        if entitlements.get(key) != value:
            raise ValueError(f"Unexpected signed entitlement: {key}")
    if not entitlements.get("application-identifier", "").endswith("." + bundle):
        raise ValueError("Unexpected signed application identifier")
    for key in ["com.apple.security.application-groups", "com.apple.developer.ubiquity-container-identifiers"]:
        if entitlements.get(key):
            raise ValueError(f"Unexpected shared data entitlement: {key}")
    if not (app / "embedded.mobileprovision").is_file():
        raise ValueError("Missing development provisioning profile")
    build = derived / "Build" / "Intermediates.noindex" / "PumpTally.build" / (configuration + "-iphoneos") / "PumpTally.build"
    lists = list(build.glob("**/PumpTally.SwiftFileList"))
    if not lists:
        raise ValueError("Missing compiler input list")
    for filelist in lists:
        sources = filelist.read_text().splitlines()
        if not any(Path(source).name == "SyncQAAppBootstrap.swift" for source in sources):
            raise ValueError("The QA app must explicitly select the isolated native container")
        if any(Path(source).name == "ProductionAppBootstrap.swift" for source in sources):
            raise ValueError("The QA app must not infer a container from its different bundle ID")
        if any(Path(source).name.startswith("Testing") or "CloudSyncMappingHarness" in source for source in sources):
            raise ValueError("A fake transport or test fixture was compiled into the app")
    binaries = [app / info["CFBundleExecutable"], *app.glob("*.debug.dylib")]
    forbidden = [b"--ui-testing", b"UI Test Vehicle", b"TestingCloudSyncEnvironment", b"TestingRecoveryScenario", b"isolated-test-account"]
    for binary in binaries:
        strings = subprocess.check_output(["strings", "-a", str(binary)])
        if any(value in strings for value in forbidden):
            raise ValueError(f"Test bootstrap or fake transport found in {binary.name}")
    print("PumpTally Sync QA: signed full app, native transport, separate bundle and Development test container verified")
    print(app)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("derived_data", type=Path)
    args = parser.parse_args()
    try:
        verify(args.derived_data)
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f"Live-sync app verification failed: {error}", file=sys.stderr)
        sys.exit(1)
