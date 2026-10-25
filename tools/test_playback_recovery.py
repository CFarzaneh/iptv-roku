"""Run deterministic BrightScript recovery tests without contacting a Roku/provider.

Requires the brs@0.45.0 interpreter (pass its executable with --brs).
"""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CASES = [
    (["source/PlaybackRecovery.brs", "tools/tests/playback_recovery.brs"],
     "Playback recovery checks passed:"),
    (["source/PlaybackRecovery.brs", "components/PlayerRecovery.brs", "components/PlayerResolution.brs", "source/ResolutionPolicy.brs", "tools/tests/player_recovery.brs"],
     "Player recovery controller checks passed:"),
    (["source/DashboardModel.brs", "components/PlayerTelemetry.brs", "components/PlayerResolution.brs", "source/ResolutionPolicy.brs", "tools/tests/dashboard_telemetry.brs"],
     "Dashboard telemetry checks passed"),
    (["source/ResolutionParser.brs", "source/ResolutionPolicy.brs", "tools/tests/resolution_parser.brs"],
     "Resolution parser checks passed:"),
    (["source/DashboardModel.brs", "components/PlayerResolution.brs", "source/ResolutionPolicy.brs", "tools/tests/player_resolution.brs"],
     "Player resolution checks passed:"),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--brs", default="brs", help="brs interpreter executable")
    args = parser.parse_args()
    for files, success in CASES:
        # Some interpreter runtime errors exit zero, so require the completion marker.
        result = subprocess.run([args.brs, "--root", "tools/tests", *files], cwd=ROOT,
                                capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        if result.returncode or success not in output or "FAILED:" in output:
            print(output, end="")
            return 1
        print(output.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
