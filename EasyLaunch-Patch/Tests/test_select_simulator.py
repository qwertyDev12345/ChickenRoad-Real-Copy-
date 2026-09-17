import unittest

from select_simulator import select_destination


class SimulatorSelectionTests(unittest.TestCase):
    def test_prefers_booted_iphone(self):
        inventory = {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-4": [
            {"name": "iPhone 16", "udid": "off", "isAvailable": True, "state": "Shutdown"},
            {"name": "iPhone 16 Pro", "udid": "on", "isAvailable": True, "state": "Booted"},
        ]}}
        self.assertEqual(select_destination(inventory), "platform=iOS Simulator,id=on")

    def test_excludes_unavailable_and_non_ios(self):
        inventory = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.tvOS-18-4": [
                {"name": "iPhone fake", "udid": "tv", "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-4": [
                {"name": "iPhone 16", "udid": "bad", "isAvailable": False},
                {"name": "iPad", "udid": "pad", "isAvailable": True},
                {"name": "iPhone 17", "udid": "good", "isAvailable": True}],
        }}
        self.assertEqual(select_destination(inventory), "platform=iOS Simulator,id=good")

    def test_missing_runtime_is_an_explicit_failure(self):
        with self.assertRaisesRegex(ValueError, "No available iPhone"):
            select_destination({"devices": {}})
