"""Drive the Stride app in the iOS Simulator: build, launch on a screen, screenshot, read computed state.

Runs as an MCP server (registered in .mcp.json) or as a CLI:

    uv run tools/stride-mcp/server.py cli launch --demo --route workout:latest-run
    uv run tools/stride-mcp/server.py cli screenshot /tmp/shot.png

The app reads debug-only launch arguments (see Stride/AppModel+Debug.swift) and writes what it computed
to Documents/debug-state.json, so checks can look at numbers as well as pixels.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "Stride.xcodeproj"
DERIVED = ROOT / "build" / "sim"
APP = DERIVED / "Build" / "Products" / "Debug-iphonesimulator" / "Stride.app"
BUNDLE_ID = "com.afritzsch.stride"
DEVICE_NAME = "Stride Test"
DEVICE_TYPE_NAME = "iPhone 18 Pro"


def run(*args: str, check: bool = True, timeout: int = 900) -> subprocess.CompletedProcess:
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        # CalledProcessError hides stderr, which is the part that says why simctl failed.
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"{' '.join(args)} failed ({result.returncode}): {detail}")
    return result


def simctl(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return run("xcrun", "simctl", *args, check=check)


# MARK: - Simulator

def device_udid() -> str:
    """The dedicated test simulator, created on first use so the user's own simulators stay untouched."""
    devices = json.loads(simctl("list", "devices", "-j").stdout)["devices"]
    for runtime, entries in devices.items():
        for device in entries:
            if device["name"] == DEVICE_NAME and device.get("isAvailable", True):
                return device["udid"]

    runtimes = json.loads(simctl("list", "runtimes", "-j").stdout)["runtimes"]
    ios = [r for r in runtimes if r["platform"] == "iOS" and r["isAvailable"]]
    if not ios:
        raise RuntimeError("No iOS Simulator runtime installed (Xcode > Settings > Components).")
    runtime = ios[-1]
    types = {t["name"]: t["identifier"] for t in runtime.get("supportedDeviceTypes", [])}
    device_type = types.get(DEVICE_TYPE_NAME) or next(v for k, v in reversed(list(types.items())) if k.startswith("iPhone"))
    return simctl("create", DEVICE_NAME, device_type, runtime["identifier"]).stdout.strip()


def boot() -> str:
    udid = device_udid()
    simctl("bootstatus", udid, "-b")  # boots the device if needed, then waits until it's ready
    return udid


def data_container(udid: str) -> Path | None:
    result = simctl("get_app_container", udid, BUNDLE_ID, "data", check=False)
    return Path(result.stdout.strip()) if result.returncode == 0 else None


# MARK: - Tools

def build() -> str:
    """Build the app for the Simulator. Returns 'BUILD SUCCEEDED' or the compiler errors."""
    result = run(
        "xcodebuild", "-project", str(PROJECT), "-scheme", "Stride",
        "-destination", "generic/platform=iOS Simulator",
        # Simulator builds are signed locally (no provisioning) so HealthKit entitlements apply.
        "-derivedDataPath", str(DERIVED), "build",
        check=False,
    )
    lines = (result.stdout + result.stderr).splitlines()
    errors = sorted({line.strip() for line in lines if "error:" in line})
    if result.returncode == 0:
        warnings = sorted({line.strip() for line in lines if "warning:" in line and "appintents" not in line})
        return "BUILD SUCCEEDED" + ("\n" + "\n".join(warnings) if warnings else "")
    return "BUILD FAILED\n" + "\n".join(errors[:40] or lines[-40:])


def launch(
    route: str = "dashboard",
    demo: bool | None = None,
    fixture: str | None = None,
    scroll_to: str | None = None,
    analyze: bool = False,
    reinstall: bool = False,
    wait: float = 7.0,
    sheet: str | None = None,
) -> dict:
    """Install and (re)launch the app on a screen.

    route: dashboard | progress | coach | plan | settings | workouts | workout:<latest|latest-run|index|uuid> |
        metric:<load|acwr|sleep|restingHR|hrv|steps|weight>
    demo: force demo data on/off (None keeps the app's setting).
    fixture: path on this Mac to a HealthFixture JSON to replay instead of HealthKit; omit to clear.
    scroll_to: on the first workout opened, scroll to route | heart-rate | zones | splits | review | analysis.
    analyze: review the first workout opened (only workout routes support this).
    sheet: on the plan route, open week (week editor), edit:<n> or time:<n> for the day n days from today.
    """
    if not APP.exists():
        raise RuntimeError("App not built yet; run build first.")
    udid = boot()
    if reinstall:
        simctl("uninstall", udid, BUNDLE_ID, check=False)
    simctl("install", udid, str(APP))
    simctl("terminate", udid, BUNDLE_ID, check=False)

    container = data_container(udid)
    if container:
        documents = container / "Documents"
        documents.mkdir(parents=True, exist_ok=True)
        target = documents / "fixture.json"
        if fixture:
            shutil.copyfile(fixture, target)
        elif target.exists():
            target.unlink()
        (documents / "debug-state.json").unlink(missing_ok=True)

    args = ["-route", route]
    if demo is not None:
        args += ["-useDemoData", "YES" if demo else "NO"]
    if scroll_to:
        args += ["-scrollTo", scroll_to]
    if analyze:
        args += ["-analyze", "YES"]
    if sheet:
        args += ["-planSheet", sheet]
    out = simctl("launch", udid, BUNDLE_ID, *args).stdout.strip()
    pid = int(out.split(":")[-1].strip()) if ":" in out else None

    time.sleep(wait)
    running = pid is not None and run("ps", "-p", str(pid), check=False).returncode == 0
    result = {"launched": out, "running": running, "args": args}
    if not running:
        result["crashLog"] = logs(seconds=30)
    return result


def screenshot(path: str | None = None) -> str:
    """Save a PNG of the Simulator screen and return its path."""
    udid = boot()
    path = path or os.path.join(tempfile.gettempdir(), f"stride-{int(time.time())}.png")
    simctl("io", udid, "screenshot", path)
    return path


def state(section: str | None = None) -> dict:
    """The app's Documents/debug-state.json: indicators, workouts, and the opened workout's splits, zones and AI prompt."""
    udid = boot()
    container = data_container(udid)
    path = container / "Documents" / "debug-state.json" if container else None
    if not path or not path.exists():
        return {"error": "No debug state yet. Launch the app (debug build) first."}
    data = json.loads(path.read_text())
    return data.get(section, {"error": f"No section {section!r}", "sections": list(data)}) if section else data


def logs(seconds: int = 60) -> str:
    """Recent log lines from the Stride process (prints, crashes, fatal errors)."""
    udid = boot()
    result = simctl(
        "spawn", udid, "log", "show", "--last", f"{seconds}s", "--style", "compact",
        "--predicate", 'process == "Stride"', check=False,
    )
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    return "\n".join(lines[-80:])


def export_fixture(output: str, demo: bool | None = True) -> str:
    """Have the app export what it reads (demo data by default, else its fixture or HealthKit) to a JSON fixture."""
    udid = boot()
    simctl("terminate", udid, BUNDLE_ID, check=False)
    container = data_container(udid)
    source = container / "Documents" / "export.json" if container else None
    if container:
        # A fixture left by `launch --fixture` would be exported instead of demo data, and an export left
        # by an earlier timed-out run would be picked up before the app writes the new one.
        if demo:
            (container / "Documents" / "fixture.json").unlink(missing_ok=True)
        source.unlink(missing_ok=True)
    args = ["-exportFixture", "YES"]
    if demo is not None:
        args += ["-useDemoData", "YES" if demo else "NO"]
    simctl("launch", udid, BUNDLE_ID, *args)
    for _ in range(40):
        if source and source.exists():
            shutil.copyfile(source, output)
            source.unlink()
            return output
        time.sleep(0.5)
    raise RuntimeError("The app didn't write an export.")


def coarsen_fixture(source: str, output: str, hr_interval: int = 120, bucket_minutes: int = 15) -> str:
    """Rewrite a fixture so it looks like a watch app that shares little detail: heart rate only every
    `hr_interval` seconds and distance/steps in clock-aligned `bucket_minutes` chunks that spill past the
    workout's start and end. Useful for testing how the app copes with sparse data."""
    if bucket_minutes <= 0 or 60 % bucket_minutes:
        raise ValueError("bucket_minutes must divide 60 (e.g. 5, 10, 15, 30, 60)")
    fixture = json.loads(Path(source).read_text())

    def parse(value: str) -> datetime:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))

    def fmt(value: datetime) -> str:
        return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    for workout in fixture["workouts"]:
        heart_rate, last = [], None
        for sample in workout["heartRate"]:
            start = parse(sample["start"])
            if last is None or (start - last).total_seconds() >= hr_interval:
                heart_rate.append(sample)
                last = start
        workout["heartRate"] = heart_rate

        for key in ("distance", "steps"):
            buckets: dict[datetime, dict] = {}
            for sample in workout[key]:
                start = parse(sample["start"])
                bucket = start.replace(minute=start.minute - start.minute % bucket_minutes, second=0, microsecond=0)
                entry = buckets.setdefault(bucket, {"value": 0.0, "source": sample["source"]})
                entry["value"] += sample["value"]
            workout[key] = [
                {"start": fmt(b), "end": fmt(b + timedelta(minutes=bucket_minutes)), "value": e["value"], "source": e["source"]}
                for b, e in sorted(buckets.items())
            ]
    Path(output).write_text(json.dumps(fixture))
    return output


# MARK: - Entry points

def serve() -> None:
    from mcp.server.fastmcp import FastMCP, Image

    mcp = FastMCP("stride-simulator")

    @mcp.tool(name="build")
    def build_tool() -> str:
        """Build the Stride app for the iOS Simulator."""
        return build()

    @mcp.tool(name="launch")
    def launch_tool(
        route: str = "dashboard", demo: bool | None = None, fixture: str | None = None,
        scroll_to: str | None = None, analyze: bool = False, reinstall: bool = False, sheet: str | None = None,
    ) -> dict:
        """Install and relaunch Stride on a screen. route: dashboard | progress | coach | chat | plan | settings | workouts |
        workout:<latest|latest-run|index|uuid> | metric:<load|acwr|sleep|restingHR|hrv|steps|weight>. fixture: Mac path of a HealthFixture JSON to replay.
        scroll_to: route | heart-rate | zones | splits | review | analysis; adherence on plan.
        sheet: on plan, week | edit:<n> | time:<n> (n = days from today)."""
        return launch(route, demo, fixture, scroll_to, analyze, reinstall, sheet=sheet)

    @mcp.tool(name="screenshot")
    def screenshot_tool() -> Image:
        """Screenshot of the Simulator screen."""
        return Image(path=screenshot())

    @mcp.tool(name="state")
    def state_tool(section: str | None = None) -> dict:
        """What the app computed (debug-state.json). Sections: indicators, workouts, detail, ..."""
        return state(section)

    @mcp.tool(name="logs")
    def logs_tool(seconds: int = 60) -> str:
        """Recent Stride log lines, including crashes."""
        return logs(seconds)

    @mcp.tool(name="export_fixture")
    def export_fixture_tool(output: str, demo: bool | None = True) -> str:
        """Export what the app reads (demo data by default) to a fixture JSON at `output`."""
        return export_fixture(output, demo)

    @mcp.tool(name="coarsen_fixture")
    def coarsen_fixture_tool(source: str, output: str, hr_interval: int = 120, bucket_minutes: int = 15) -> str:
        """Make a fixture look like sparse watch data (heart rate every N s, distance/steps in M-minute chunks)."""
        return coarsen_fixture(source, output, hr_interval, bucket_minutes)

    mcp.run()


def cli(argv: list[str]) -> None:
    parser = argparse.ArgumentParser(prog="stride-mcp cli")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("build")
    p = sub.add_parser("launch")
    p.add_argument("--route", default="dashboard")
    p.add_argument("--demo", action="store_true", default=None)
    p.add_argument("--no-demo", dest="demo", action="store_false")
    p.add_argument("--fixture")
    p.add_argument("--scroll-to")
    p.add_argument("--analyze", action="store_true")
    p.add_argument("--reinstall", action="store_true")
    p.add_argument("--sheet")
    p = sub.add_parser("screenshot")
    p.add_argument("path", nargs="?")
    p = sub.add_parser("state")
    p.add_argument("section", nargs="?")
    p = sub.add_parser("logs")
    p.add_argument("--seconds", type=int, default=60)
    p = sub.add_parser("export-fixture")
    p.add_argument("output")
    # Without demo data the app exports its fixture, or HealthKit when there's none.
    p.add_argument("--no-demo", dest="demo", action="store_const", const=None, default=True)
    p = sub.add_parser("coarsen-fixture")
    p.add_argument("source")
    p.add_argument("output")
    p.add_argument("--hr-interval", type=int, default=120)
    p.add_argument("--bucket-minutes", type=int, default=15)
    args = parser.parse_args(argv)

    match args.command:
        case "build": print(build())
        case "launch":
            print(json.dumps(launch(args.route, args.demo, args.fixture, args.scroll_to, args.analyze, args.reinstall, sheet=args.sheet), indent=2))
        case "screenshot": print(screenshot(args.path))
        case "state": print(json.dumps(state(args.section), indent=2))
        case "logs": print(logs(args.seconds))
        case "export-fixture": print(export_fixture(args.output, args.demo))
        case "coarsen-fixture": print(coarsen_fixture(args.source, args.output, args.hr_interval, args.bucket_minutes))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "cli":
        cli(sys.argv[2:])
    else:
        serve()
