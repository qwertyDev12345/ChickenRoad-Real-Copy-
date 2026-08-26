#!/usr/bin/env python3
"""
add_entitlements.py — adds CODE_SIGN_ENTITLEMENTS to the Unity-iPhone target
build configurations in project.pbxproj.

Identifies configs that belong to the main app target by looking for
  PRODUCT_BUNDLE_IDENTIFIER = <bundle_id>;
where <bundle_id> does NOT contain ".NotificationService" or "unity3d".

Usage:
    python3 add_entitlements.py <path/to/project.pbxproj> <entitlements_relative_path>

Example:
    python3 add_entitlements.py ./Build/Unity-iPhone.xcodeproj/project.pbxproj \
        "Unity-iPhone/Unity-iPhone.entitlements"
"""

import sys
import re

SETTING_KEY = "CODE_SIGN_ENTITLEMENTS"


def add_entitlements(pbxproj_path: str, entitlements_path: str) -> None:
    with open(pbxproj_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Split into XCBuildConfiguration blocks.
    # Each block starts with a UUID line and ends with `};` + optional comment line.
    # We process the content block-by-block via regex substitution.

    # Match a full XCBuildConfiguration section:
    #   <UUID> /* <name> */ = { isa = XCBuildConfiguration; buildSettings = { ... }; name = ...; };
    # We capture the whole block and replace it only when needed.

    block_pattern = re.compile(
        r'(\t\t[0-9A-F]{24} /\* [^\*]+ \*/ = \{\s*isa = XCBuildConfiguration;'
        r'.*?'
        r'\t\t\};)',
        re.DOTALL
    )

    modified = 0

    def patch_block(m: re.Match) -> str:
        nonlocal modified
        block = m.group(0)

        # Only patch main app target configs — they have PRODUCT_BUNDLE_IDENTIFIER
        # without a sub-product suffix (not NotificationService, not unity3d test target).
        bundle_match = re.search(
            r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);', block
        )
        if not bundle_match:
            return block

        bundle_id = bundle_match.group(1).strip().strip('"')
        if "NotificationService" in bundle_id or "unity3d" in bundle_id:
            return block

        # Skip if already present
        if SETTING_KEY in block:
            return block

        # Insert CODE_SIGN_ENTITLEMENTS right after `buildSettings = {`
        replacement = (
            f'\t\t\t\t{SETTING_KEY} = "{entitlements_path}";\n'
        )
        patched = re.sub(
            r'(buildSettings = \{\n)',
            r'\1' + replacement,
            block,
            count=1
        )
        if patched != block:
            modified += 1
        return patched

    new_content = block_pattern.sub(patch_block, content)

    if modified == 0:
        print(f"[add_entitlements] {SETTING_KEY} already present or no matching configs found — skipping.")
        return

    with open(pbxproj_path, "w", encoding="utf-8") as f:
        f.write(new_content)

    print(f"[add_entitlements] Added {SETTING_KEY} to {modified} build configuration(s).")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <project.pbxproj> <entitlements_relative_path>")
        sys.exit(1)

    add_entitlements(sys.argv[1], sys.argv[2])
