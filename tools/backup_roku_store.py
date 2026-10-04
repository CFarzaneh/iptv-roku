"""Back up the sideloaded Roku app's favorites before replacing its package."""

import argparse
import json
import os
from pathlib import Path
import re
import socket
import time
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]


def ecp(host, path, method="GET"):
    with urlopen(Request(f"http://{host}:8060{path}", method=method), timeout=6) as response:
        return response.read().decode("utf-8", "replace")


def last_store(window, key):
    matches = re.findall(rf"^\[STORE\] {key}=(.+)$", window, re.MULTILINE)
    if not matches:
        return None
    value = json.loads(matches[-1].strip())
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"Invalid {key} list on Roku")
    return value


def backup(host, timeout):
    with socket.create_connection((host, 8085), timeout=5) as console:
        console.settimeout(0.25)
        if 'id="dev"' in ecp(host, "/query/active-app"):
            ecp(host, "/keypress/Home", "POST")
            time.sleep(1.5)
        ecp(host, "/launch/dev", "POST")
        deadline = time.monotonic() + timeout
        raw = bytearray()
        last_data = time.monotonic()
        favorites = recents = None
        while time.monotonic() < deadline:
            try:
                chunk = console.recv(8192)
            except socket.timeout:
                chunk = b""
            if chunk:
                raw.extend(chunk)
                if len(raw) > 2_000_000:
                    raw = raw[-2_000_000:]
                last_data = time.monotonic()
            text = raw.decode("utf-8", "replace")
            fence = text.rfind("scrpt.ctx.run.enter")
            if fence < 0:
                continue
            window = text[fence:]
            try:
                favorites = last_store(window, "favorites")
                recents = last_store(window, "recents")
            except (json.JSONDecodeError, ValueError):
                continue
            if favorites is not None and recents is not None and time.monotonic() - last_data >= 3:
                break
        if favorites is None or recents is None:
            raise RuntimeError("No current-session favorites/recents capture; refusing to create an untrusted backup")
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime())
    directory = ROOT / "backups"
    directory.mkdir(mode=0o700, exist_ok=True)
    path = directory / f"store-{stamp}.json"
    with path.open("x", encoding="utf-8") as output:
        os.chmod(path, 0o600)
        json.dump({"capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                   "rokuIp": host, "favorites": favorites, "recents": recents}, output, ensure_ascii=False, indent=2)
    if favorites:
        seed = ROOT / "source/restore.json"
        temporary = seed.with_suffix(".json.tmp")
        with temporary.open("w", encoding="utf-8") as output:
            os.chmod(temporary, 0o600)
            json.dump({"capturedAt": stamp, "favorites": favorites,
                       "recents": [item for item in recents if '"' not in item]}, output, ensure_ascii=False)
        os.replace(temporary, seed)
    print(f"Saved current Roku store: {len(favorites)} favorites, {len(recents)} recents; {path}")
    if not favorites:
        print("No favorites found; existing restore seed was left untouched.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", help="Roku LAN IP address, without http://")
    parser.add_argument("--timeout", type=int, default=55)
    arguments = parser.parse_args()
    backup(arguments.host, arguments.timeout)
