import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "Scripts" / "patch_infoplist.py"
SPEC = importlib.util.spec_from_file_location("patch_infoplist", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BrowserATSTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "Info.plist"

    def patch(self, info):
        self.path.write_bytes(plistlib.dumps(info))
        MODULE.patch(str(self.path))
        return plistlib.loads(self.path.read_bytes())

    def test_adds_only_web_exception(self):
        info = self.patch({"CFBundleIdentifier": "example.browser"})
        self.assertEqual(info["NSAppTransportSecurity"], {
            "NSAllowsArbitraryLoadsInWebContent": True,
        })
        self.assertEqual(info["CFBundleIdentifier"], "example.browser")

    def test_preserves_domain_rules_global_policy_and_existing_permissions(self):
        domains = {"private.example": {"NSIncludesSubdomains": True,
                                      "NSExceptionAllowsInsecureHTTPLoads": False}}
        info = self.patch({"NSAppTransportSecurity": {
            "NSAllowsArbitraryLoads": False, "NSExceptionDomains": domains,
        }, "NSCameraUsageDescription": "Existing permission text"})
        self.assertEqual(info["NSAppTransportSecurity"]["NSExceptionDomains"], domains)
        self.assertIs(info["NSAppTransportSecurity"]["NSAllowsArbitraryLoads"], False)
        self.assertEqual(info["NSCameraUsageDescription"], "Existing permission text")
        self.assertNotIn("NSAllowsArbitraryLoadsForMedia", info["NSAppTransportSecurity"])

    def test_overrides_disabled_web_exception(self):
        info = self.patch({"NSAppTransportSecurity": {
            "NSAllowsArbitraryLoadsInWebContent": False,
        }})
        self.assertIs(info["NSAppTransportSecurity"]["NSAllowsArbitraryLoadsInWebContent"], True)

    def test_idempotent(self):
        self.patch({})
        original = self.path.read_bytes()
        MODULE.patch(str(self.path))
        self.assertEqual(self.path.read_bytes(), original)

    def test_malformed_ats_fails_without_modifying_file(self):
        original = plistlib.dumps({"NSAppTransportSecurity": "invalid"})
        self.path.write_bytes(original)
        with self.assertRaisesRegex(ValueError, "must be a dictionary"):
            MODULE.patch(str(self.path))
        self.assertEqual(self.path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
