"""Select an available iPhone from `xcrun simctl list devices available --json`."""
import json
import sys


def select_destination(inventory):
    candidates = [
        device
        for runtime, devices in inventory.get("devices", {}).items()
        if ".iOS-" in runtime
        for device in devices
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone")
    ]
    if not candidates:
        raise ValueError("No available iPhone simulator; install an iOS runtime in Xcode.")
    candidates.sort(key=lambda device: (device.get("state") != "Booted", device["name"], device["udid"]))
    return "platform=iOS Simulator,id=" + candidates[0]["udid"]


if __name__ == "__main__":
    try:
        print(select_destination(json.load(sys.stdin)))
    except (ValueError, KeyError) as error:
        sys.exit(str(error))
