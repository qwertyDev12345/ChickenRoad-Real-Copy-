#!/usr/bin/env python3
"""
patch_infoplist.py — добавляет разрешения камеры/микрофона и политику ATS
для встроенного браузера. Применяется только к основному приложению.

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

    # Match the reference browser's HTTP navigation support, including HTTPS
    # redirects to HTTP. Do NOT add NSAllowsArbitraryLoads or relax URLSession,
    # media, certificate validation, or the notification-service extension.
    # Existing domain-specific exceptions remain authoritative and untouched.
    ats = data.get("NSAppTransportSecurity", {})
    if not isinstance(ats, dict):
        raise ValueError("NSAppTransportSecurity must be a dictionary")
    changed = False
    if ats.get("NSAllowsArbitraryLoadsInWebContent") is not True:
        ats["NSAllowsArbitraryLoadsInWebContent"] = True
        data["NSAppTransportSecurity"] = ats
        changed = True
        print("[patch_infoplist] WebView ATS: allow HTTP web content (App Store justification required)")
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
