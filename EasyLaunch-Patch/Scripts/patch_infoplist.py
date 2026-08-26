#!/usr/bin/env python3
"""
patch_infoplist.py — добавляет NSCameraUsageDescription и NSMicrophoneUsageDescription
в Info.plist если они ещё не присутствуют.

Использование:
    python3 patch_infoplist.py <path/to/Info.plist>
"""

import sys
import plistlib
import os

KEYS = {
    "NSCameraUsageDescription":     "This app requires access to the camera.",
    "NSMicrophoneUsageDescription": "This app requires access to the microphone.",
    "ITSAppUsesNonExemptEncryption": False,
}


def patch(plist_path: str) -> None:
    if not os.path.isfile(plist_path):
        print(f"[patch_infoplist] ERROR: file not found: {plist_path}", file=sys.stderr)
        sys.exit(1)

    with open(plist_path, "rb") as f:
        data = plistlib.load(f)

    changed = False
    for key, value in KEYS.items():
        if key not in data:
            data[key] = value
            print(f"[patch_infoplist]  + {key}")
            changed = True
        else:
            print(f"[patch_infoplist]  = {key} (уже присутствует, пропуск)")

    if changed:
        with open(plist_path, "wb") as f:
            plistlib.dump(data, f)
        print("[patch_infoplist] Info.plist обновлён.")
    else:
        print("[patch_infoplist] Info.plist не изменён.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Использование: {sys.argv[0]} <path/to/Info.plist>", file=sys.stderr)
        sys.exit(1)
    patch(sys.argv[1])
