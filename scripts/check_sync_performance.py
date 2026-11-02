#!/usr/bin/env python3
"""Read native XCTest metrics; enforce budgets only on their calibrated runner."""

import argparse
import json
import math
import statistics
import subprocess
import sys
from pathlib import Path


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", type=Path, help="Dedicated optimized SyncPerformanceTests.xcresult")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--budgets", type=Path, help="Calibrated runner profile")
    mode.add_argument(
        "--report-only", action="store_true", help="Record measurements without asserting timing budgets"
    )
    args = parser.parse_args()
    summary = json.loads(
        command("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(args.result))
    )
    metrics = json.loads(
        command("xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", str(args.result))
    )
    expected = {
        f"SyncPerformanceTests/test{direction}{count}()"
        for direction in ("Upload", "Download")
        for count in (800, 3200, 12800)
    }
    if summary["totalTestCount"] != 6 or summary["passedTests"] != 6 or summary["skippedTests"] != 0:
        raise ValueError("Use a dedicated result with all six performance tests passing and no skips")
    if {test["testIdentifier"] for test in metrics} != expected:
        raise ValueError("The result must contain all six scaling scenarios")

    budget = json.loads(args.budgets.read_text()) if args.budgets else None
    if budget:
        if command("sysctl", "-n", "hw.model") != budget["hostModel"]:
            raise ValueError("Runner hardware differs from the calibrated profile; use --report-only and calibrate it")
        if command("xcodebuild", "-version").splitlines()[-1] != f"Build version {budget['xcodeBuild']}":
            raise ValueError("Xcode differs from the calibrated profile")
        if "PumpTallyBenchmarks" not in summary["environmentDescription"]:
            raise ValueError("Budgets require the optimized PumpTallyBenchmarks scheme")
        destinations = summary["devicesAndConfigurations"]
        if len(destinations) != 1 or any(
            destinations[0]["device"][key] != budget[key]
            for key in ("deviceName", "platform", "osVersion")
        ):
            raise ValueError("Simulator destination differs from the calibrated profile")

    failures = []
    for test in sorted(metrics, key=lambda item: item["testIdentifier"]):
        if len(test["testRuns"]) != 1:
            raise ValueError("Expected a single test run per scenario")
        values = {metric["identifier"]: metric for metric in test["testRuns"][0]["metrics"]}
        clock = values["com.apple.dt.XCTMetric_Clock.time.monotonic"]
        memory = values["com.apple.dt.XCTMetric_Memory.physical_peak"]
        if clock["unitOfMeasurement"] != "s" or memory["unitOfMeasurement"] != "kB":
            raise ValueError("Unexpected metric units")
        for metric in (clock, memory):
            samples = metric["measurements"]
            if len(samples) < (budget["minimumMeasurements"] if budget else 5) or not all(
                math.isfinite(value) and value >= 0 for value in samples
            ):
                raise ValueError("Missing or invalid performance samples")
        mean = statistics.fmean(clock["measurements"])
        peak = max(memory["measurements"])
        print(f"{test['testIdentifier']}: mean {mean * 1000:.2f} ms; reported peak {peak / 1024:.2f} MiB")
        if budget and (mean > budget["meanTimeSeconds"] or peak > budget["peakMemoryKB"]):
            failures.append(test["testIdentifier"])
    if failures:
        raise ValueError("Performance budget exceeded: " + ", ".join(failures))
    print("Calibrated time/memory budgets passed" if budget else "Report only; runner budgets have not been asserted")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Performance check failed: {error}", file=sys.stderr)
        sys.exit(1)
