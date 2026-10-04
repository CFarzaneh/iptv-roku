"""Build a private, device-specific Roku ZIP without changing the source tree.

This creates a package only. It never contacts or installs to a Roku.
"""

import argparse
import json
import os
from pathlib import Path
import re
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
DEVICE_ID = re.compile(r"^[a-z0-9-]{1,60}$")


def read_json(path):
    with path.open("r", encoding="utf-8") as source:
        return json.load(source)


def package(args):
    if not DEVICE_ID.fullmatch(args.device_id):
        raise ValueError("Device ID must be 1–60 lowercase letters, digits, or hyphens")
    dashboard = read_json(args.dashboard)
    if dashboard.get("deviceId") != args.device_id:
        raise ValueError("Dashboard identity belongs to a different device")
    if not str(dashboard.get("apiUrl", "")).startswith("https://"):
        raise ValueError("Dashboard URL must use HTTPS")
    if len(str(dashboard.get("secret", ""))) < 40:
        raise ValueError("Dashboard installation secret is missing")
    if args.empty_provider and args.provider_config:
        raise ValueError("Choose either --empty-provider or --provider-config")
    if not args.empty_provider and not args.provider_config:
        raise ValueError("Provide --provider-config or --empty-provider")
    if args.empty_provider:
        provider = {"playlistUrl": "", "epgUrl": "", "extraPlaylists": []}
    else:
        provider = read_json(args.provider_config)
        if not isinstance(provider, dict) or not provider.get("playlistUrl"):
            raise ValueError("Provider config must contain a playlistUrl")
    restore = None
    if args.restore_seed:
        restore = read_json(args.restore_seed)
        if (not isinstance(restore, dict) or not isinstance(restore.get("favorites"), list)
                or not all(isinstance(item, str) for item in restore["favorites"])):
            raise ValueError("Restore seed must contain a favorites array of strings")
    if args.require_restore and not restore:
        raise ValueError("This device requires an explicit restore seed")
    output = args.output.resolve()
    try:
        output.relative_to((ROOT / "builds").resolve())
    except ValueError as error:
        raise ValueError("Private package output must be under the ignored builds/ directory") from error
    if output.exists():
        raise FileExistsError(f"Refusing to overwrite existing package: {output}")
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    previous_umask = os.umask(0o077)
    try:
        with ZipFile(output, "x", ZIP_DEFLATED) as archive:
            archive.write(ROOT / "manifest", "manifest")
            for directory in ("source", "components", "images"):
                for path in sorted((ROOT / directory).rglob("*")):
                    if not path.is_file() or path.is_symlink():
                        continue
                    name = path.relative_to(ROOT).as_posix()
                    if name in {"source/dashboard.json", "source/restore.json"}:
                        continue
                    if any(part.startswith(".") for part in path.relative_to(ROOT).parts):
                        continue
                    archive.write(path, name)
            archive.writestr("config.json", json.dumps(provider, ensure_ascii=False))
            archive.writestr("source/dashboard.json", json.dumps(dashboard, ensure_ascii=False))
            if restore:
                archive.writestr("source/restore.json", json.dumps(restore, ensure_ascii=False))
        os.chmod(output, 0o600)
        with ZipFile(output) as archive:
            names = set(archive.namelist())
            if archive.testzip() or not {"manifest", "config.json", "source/dashboard.json"}.issubset(names):
                raise ValueError("Package validation failed")
            if not any(name.startswith("components/") for name in names):
                raise ValueError("Package has no SceneGraph components")
        print(f"Built private Roku package for {args.device_id}: {output}")
        print("No Roku was contacted or changed.")
    except FileExistsError:
        raise
    except Exception:
        output.unlink(missing_ok=True)
        raise
    finally:
        os.umask(previous_umask)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device_id")
    parser.add_argument("--dashboard", required=True, type=Path, help="This device's private dashboard.json")
    provider = parser.add_mutually_exclusive_group(required=True)
    provider.add_argument("--provider-config", type=Path, help="This device's provider config.json")
    provider.add_argument("--empty-provider", action="store_true", help="Set provider later in the dashboard")
    parser.add_argument("--restore-seed", type=Path, help="This device's private favorites recovery file")
    parser.add_argument("--require-restore", action="store_true", help="Refuse a package without a restore seed")
    parser.add_argument("--output", required=True, type=Path, help="New ignored ZIP path under builds/")
    package(parser.parse_args())
