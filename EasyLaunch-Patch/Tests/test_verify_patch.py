import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "Scripts" / "verify_patch.py"
SPEC = importlib.util.spec_from_file_location("verify_patch", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SOURCE = SCRIPT.parents[1] / "Sources" / "Classes"


class VerifyPatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.export = Path(self.temp.name)
        (self.export / "Classes").mkdir()
        for path in SOURCE.iterdir():
            if path.suffix in {".h", ".m", ".mm"}:
                shutil.copyfile(path, self.export / "Classes" / path.name)
        with (self.export / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "test.app", "ExistingSetting": True}, stream)

    def test_current_sources_stamp_commit_and_preserve_settings(self):
        result = MODULE.verify(SOURCE, self.export, "test-commit")
        with (self.export / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        self.assertEqual(info["EasyLaunchSourceCommit"], "test-commit")
        self.assertEqual(info["EasyLaunchPatchSHA256"], result["native_sources_sha256"])
        self.assertTrue(info["ExistingSetting"])
        self.assertEqual(json.loads((self.export / "easylaunch-build.json").read_text()), result)
        self.assertEqual(MODULE.verify(SOURCE, self.export, "test-commit"), result)

    def test_stale_controller_fails_before_any_stamp(self):
        (self.export / "Classes" / "WebViewController.m").write_text("stale build")
        original = (self.export / "Info.plist").read_bytes()
        with self.assertRaisesRegex(ValueError, "different WebViewController.m"):
            MODULE.verify(SOURCE, self.export)
        self.assertEqual((self.export / "Info.plist").read_bytes(), original)
        self.assertFalse((self.export / "easylaunch-build.json").exists())

    def test_missing_native_file_fails(self):
        (self.export / "Classes" / "PLServicesWrapper.m").unlink()
        with self.assertRaisesRegex(ValueError, "missing PLServicesWrapper.m"):
            MODULE.verify(SOURCE, self.export)

    def test_generated_credentials_are_not_in_manifest(self):
        (self.export / "Classes" / "EasyLaunchConfig.h").write_text("generated private configuration")
        result = MODULE.verify(SOURCE, self.export)
        self.assertNotIn("EasyLaunchConfig.h", result["files"])
        self.assertNotIn("private configuration", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
