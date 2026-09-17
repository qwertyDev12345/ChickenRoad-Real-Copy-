"""Narrow portable guard for owned-family object getters; not an ObjC compiler."""
from pathlib import Path
import re
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "Sources" / "Classes"


def owned_family(name):
    return re.match(r"^_*(?:alloc|new|copy|mutableCopy)(?:$|[^a-z])", name) is not None


class ObjectPropertyNamingTests(unittest.TestCase):
    def test_family_boundary(self):
        for name in ("copyDiagnosticButton", "newButton", "mutableCopy", "_allocView"):
            self.assertTrue(owned_family(name), name)
        for name in ("diagnosticCopyButton", "copying", "newspaper", "pl_copyDiagnostics"):
            self.assertFalse(owned_family(name), name)

    def test_strong_object_properties_do_not_use_owned_getters(self):
        checked = 0
        for path in SOURCE.iterdir():
            if path.suffix not in (".h", ".m", ".mm"):
                continue
            for declaration in re.findall(r"@property\s*\([^)]*\)[^;]+;", path.read_text(encoding="utf-8")):
                if not re.search(r"\b(?:strong|retain|copy)\b", declaration.split(")", 1)[0]):
                    continue
                name = re.search(r"\*\s*([A-Za-z_]\w*)\s*;", declaration)
                if not name:  # This small guard checks ordinary object pointers, not blocks.
                    continue
                getter = re.search(r"getter\s*=\s*([A-Za-z_]\w*)", declaration)
                selector = getter.group(1) if getter else name.group(1)
                checked += 1
                self.assertFalse(owned_family(selector), f"{path.name}: {declaration}")
        self.assertGreater(checked, 0)
