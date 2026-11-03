#!/usr/bin/env python3
"""Verify the signed, physical-device probe before any live CloudKit tests."""

import argparse
import plistlib
import subprocess
import sys
from pathlib import Path


def verify(app: Path):
    expected_container = "iCloud.me.tianshilei.fuelio.CloudKitProbe"
    with (app / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != "me.tianshilei.fuelio.CloudKitProbe":
        raise ValueError("This is not the separate CloudKitProbe application")
    if info.get("CloudKitTestContainer") != expected_container:
        raise ValueError("The probe must use the approved, separate test container")
    if info.get("DTPlatformName") != "iphoneos":
        raise ValueError("Use the signed physical-device build")
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    signed = subprocess.check_output(
        ["codesign", "--display", "--entitlements", "-", "--xml", str(app)],
        stderr=subprocess.DEVNULL,
    )
    entitlements = plistlib.loads(signed)
    expected = {
        "com.apple.developer.icloud-container-identifiers": [expected_container],
        "com.apple.developer.icloud-container-environment": "Development",
        "com.apple.developer.icloud-services": ["CloudKit"],
    }
    for key, value in expected.items():
        if entitlements.get(key) != value:
            raise ValueError(f"Unexpected signed entitlement: {key}")
    if not (app / "embedded.mobileprovision").is_file():
        raise ValueError("The signed development provisioning profile is missing")
    print("CloudKitProbe: signed device build, isolated container and Development environment verified")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Signed CloudKitProbe.app built for the iPhone")
    args = parser.parse_args()
    try:
        verify(args.app)
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f"CloudKit probe verification failed: {error}", file=sys.stderr)
        sys.exit(1)
