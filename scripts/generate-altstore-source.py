#!/usr/bin/env python3
"""Generates the AltStore / SideStore source JSON that makes OTA updates work.

The release workflow runs this after building the IPA and uploads the result as
a release asset named `source.json`. Users add the stable URL

    https://github.com/<owner>/<repo>/releases/latest/download/source.json

to AltStore or SideStore once; both then re-sign and install new IPAs when the
first entry in `versions` changes. Earlier versions are carried over from the
previous source.json (pass it with --previous) so the history is preserved.
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

BUNDLE_ID = "com.example.slopWidget"


def build_source(args, previous):
    repo_url = f"https://github.com/{args.repo}"
    entry = {
        "version": args.version,
        "buildVersion": str(args.build),
        "date": args.date,
        "localizedDescription": args.notes or f"slopWidget {args.version}",
        "downloadURL": f"{repo_url}/releases/download/{args.tag}/{os.path.basename(args.ipa)}",
        "size": os.path.getsize(args.ipa),
        "minOSVersion": "17.0",
    }

    app = {
        "name": "slopWidget",
        "bundleIdentifier": BUNDLE_ID,
        "developerName": args.repo.split("/")[0],
        "subtitle": "AI coding-assistant usage on your home screen",
        "localizedDescription": (
            "Track Antigravity, Codex, OpenCode Go, and Claude usage in one "
            "dashboard and home-screen widgets."
        ),
        "iconURL": f"https://raw.githubusercontent.com/{args.repo}/main/assets/icon.png",
        "tintColor": "d97706",
        "appPermissions": {"entitlements": [], "privacy": {}},
        "versions": [entry],
    }

    source = {
        "name": "slopWidget",
        "identifier": f"io.github.{args.repo.split('/')[0].lower()}.slopwidget",
        "sourceURL": f"{repo_url}/releases/latest/download/source.json",
        "apps": [app],
    }

    # AltStore treats the first entry as the latest and never compares dates,
    # so the new version goes first and a re-run for the same tag replaces it.
    old = []
    if previous:
        for old_app in previous.get("apps", []):
            if old_app.get("bundleIdentifier") == BUNDLE_ID:
                old = old_app.get("versions", [])
    kept = [
        v for v in old
        if (v.get("version"), v.get("buildVersion"))
        != (entry["version"], entry["buildVersion"])
        and v.get("downloadURL") != entry["downloadURL"]
    ]
    app["versions"] = [entry] + kept
    return source


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo", required=True, help="owner/name")
    p.add_argument("--tag", required=True, help="release tag, e.g. v1.2.3")
    p.add_argument("--build", required=True, type=int, help="monotonic build number")
    p.add_argument("--ipa", required=True, help="path to the built IPA")
    p.add_argument("--previous", help="previous source.json to carry versions over from")
    p.add_argument("--notes", help="changelog text for this version")
    p.add_argument("--date", default=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    p.add_argument("--output", required=True)
    args = p.parse_args()

    match = re.fullmatch(r"v?(\d+(?:\.\d+){0,2}(?:[-+][0-9A-Za-z.-]+)?)", args.tag)
    if not match:
        sys.exit(f"error: tag {args.tag!r} is not a version like v1.2.3")
    args.version = match.group(1)

    previous = None
    if args.previous and os.path.exists(args.previous):
        try:
            with open(args.previous) as f:
                previous = json.load(f)
        except json.JSONDecodeError:
            print("warning: ignoring unreadable previous source.json", file=sys.stderr)

    with open(args.output, "w") as f:
        json.dump(build_source(args, previous), f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
