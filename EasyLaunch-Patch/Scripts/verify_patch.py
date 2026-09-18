#!/usr/bin/env python3
"""Reject stale/missing exported native sources and stamp their identity in the app."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib


def verify(source_root: Path, xcode_root: Path, commit: str = "local") -> dict:
    sources = sorted(p for p in source_root.iterdir()
                     if p.suffix in {".h", ".m", ".mm"} and p.name != "EasyLaunchConfig.h")
    if not sources or not any(p.name == "CustomAppController.mm" for p in sources):
        raise ValueError("EasyLaunch native source directory is incomplete")
    hashes = {}
    for source in sources:
        exported = xcode_root / "Classes" / source.name
        if not exported.is_file():
            raise ValueError(f"Export is missing {source.name}; apply the current patch before building")
        original = source.read_bytes()
        if exported.read_bytes() != original:
            raise ValueError(f"Export contains a different {source.name}; refusing a stale build")
        hashes[source.name] = hashlib.sha256(original).hexdigest()

    fingerprint = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    manifest = {"source_commit": commit, "native_sources_sha256": fingerprint, "files": hashes}
    plist_path = xcode_root / "Info.plist"
    with plist_path.open("rb") as stream:
        info = plistlib.load(stream)
    ats = info.get("NSAppTransportSecurity", {})
    if not isinstance(ats, dict) or ats.get("NSAllowsArbitraryLoadsInWebContent") is not True:
        raise ValueError("Export is missing WebView ATS policy; run patch_infoplist.py before building")
    manifest["web_ats_exception"] = True
    info["EasyLaunchSourceCommit"] = commit
    info["EasyLaunchPatchSHA256"] = fingerprint
    with plist_path.open("wb") as stream:
        plistlib.dump(info, stream)
    (xcode_root / "easylaunch-build.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--xcode-root", type=Path, required=True)
    parser.add_argument("--commit", default="local")
    args = parser.parse_args()
    result = verify(args.source_root, args.xcode_root, args.commit)
    print(f"Verified {len(result['files'])} native files; commit={result['source_commit']}; "
          f"patch_sha256={result['native_sources_sha256']}")
