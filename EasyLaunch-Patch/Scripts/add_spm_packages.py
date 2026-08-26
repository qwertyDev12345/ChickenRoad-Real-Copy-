#!/usr/bin/env python3
"""
add_spm_packages.py
────────────────────
Добавляет SPM-зависимости Firebase и AppsFlyer в Unity-сгенерированный
project.pbxproj (без Xcode).

Добавляет в pbxproj:
  • XCRemoteSwiftPackageReference   — для каждого репозитория
  • XCSwiftPackageProductDependency — для каждого product (framework)
  • packageProductDependencies      — в тело таргета UnityFramework
  • Frameworks build phase          — записи PBXBuildFile в фазе UnityFramework

Использование:
  python3 add_spm_packages.py <path/to/project.pbxproj>

Пакеты:
  Firebase SDK  — https://github.com/firebase/firebase-ios-sdk
    products: FirebaseCore, FirebaseMessaging
  AppsFlyer SDK — https://github.com/AppsFlyerSDK/AppsFlyerFramework-Static
    products: AppsFlyerLib-Static
"""

import sys
import re
import hashlib

# ──────────────────────────────────────────────────────────────────────────────
# Описание пакетов и их products
# ──────────────────────────────────────────────────────────────────────────────
SPM_PACKAGES = [
    {
        "url":      "https://github.com/firebase/firebase-ios-sdk",
        "version":  "11.0.0",   # минимальная версия (up_to_next_major)
        "products": ["FirebaseCore", "FirebaseMessaging"],
    },
    {
        "url":      "https://github.com/AppsFlyerSDK/AppsFlyerFramework-Static",
        "version":  "6.14.0",
        "products": ["AppsFlyerLib-Static"],
    },
]

# ──────────────────────────────────────────────────────────────────────────────

def make_uuid(seed: str) -> str:
    return hashlib.md5(('spm_' + seed).encode()).hexdigest()[:24].upper()


def already_has_package(content: str, url: str) -> bool:
    return url in content


def _find_unityframework_frameworks_phase(content: str) -> str | None:
    """
    Возвращает UUID секции PBXFrameworksBuildPhase, принадлежащей
    таргету UnityFramework, или None если не найдено.
    """
    target_m = re.search(
        r'/\* UnityFramework \*/ = \{[^}]*?isa = PBXNativeTarget;.*?buildPhases = \((.*?)\);',
        content, re.DOTALL
    )
    if not target_m:
        return None

    phase_uuids = re.findall(r'([0-9A-F]{24})', target_m.group(1))

    for uuid in phase_uuids:
        pat = re.compile(
            rf'{uuid}\b.*?isa\s*=\s*PBXFrameworksBuildPhase\b',
            re.DOTALL
        )
        if pat.search(content):
            return uuid

    return None


def patch(pbxproj_path: str) -> None:
    with open(pbxproj_path, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()

    pkg_ref_block    = ''   # XCRemoteSwiftPackageReference
    prod_dep_block   = ''   # XCSwiftPackageProductDependency
    build_file_block = ''   # PBXBuildFile (Frameworks phase)

    pkg_ref_uuids    = []   # for packageReferences in project
    prod_dep_uuids   = []   # for packageProductDependencies in target
    framework_uuids  = []   # for Frameworks build phase

    for pkg in SPM_PACKAGES:
        url = pkg["url"]

        if already_has_package(content, url):
            print(f"  · Already present: {url}")
            continue

        pkg_uuid = make_uuid(url)
        pkg_ref_uuids.append(pkg_uuid)

        pkg_ref_block += (
            f'\t\t{pkg_uuid} /* XCRemoteSwiftPackageReference "{url.split("/")[-1]}" */ = {{\n'
            f'\t\t\tisa = XCRemoteSwiftPackageReference;\n'
            f'\t\t\trequirement = {{\n'
            f'\t\t\t\tkind = upToNextMajorVersion;\n'
            f'\t\t\t\tminimumVersion = {pkg["version"]};\n'
            f'\t\t\t}};\n'
            f'\t\t\trepositoryURL = "{url}";\n'
            f'\t\t}};\n'
        )

        for product in pkg["products"]:
            prod_uuid  = make_uuid(url + product)
            build_uuid = make_uuid('fw_' + url + product)

            prod_dep_uuids.append(prod_uuid)
            framework_uuids.append((build_uuid, prod_uuid, product))

            prod_dep_block += (
                f'\t\t{prod_uuid} /* {product} */ = {{\n'
                f'\t\t\tisa = XCSwiftPackageProductDependency;\n'
                f'\t\t\tpackage = {pkg_uuid} /* XCRemoteSwiftPackageReference "{url.split("/")[-1]}" */;\n'
                f'\t\t\tproductName = {product};\n'
                f'\t\t}};\n'
            )

            build_file_block += (
                f'\t\t{build_uuid} /* {product} in Frameworks */ = {{'
                f'isa = PBXBuildFile; '
                f'productRef = {prod_uuid} /* {product} */; }};\n'
            )

        print(f"  ✓  Добавлен пакет: {url} → {pkg['products']}")

    if not pkg_ref_uuids and not prod_dep_uuids:
        print("  → Все пакеты уже присутствуют в pbxproj — изменений не требуется.")
        return

    # ── Вставка блоков ────────────────────────────────────────────────────────

    # 1. XCRemoteSwiftPackageReference section
    if pkg_ref_block:
        if '/* Begin XCRemoteSwiftPackageReference section */' in content:
            content = re.sub(
                r'(/\* Begin XCRemoteSwiftPackageReference section \*/\n)',
                r'\1' + pkg_ref_block,
                content, count=1
            )
        else:
            # Секции нет — создаём перед закрывающей скобкой objects
            # Находим последнюю секцию перед закрытием
            insert_pos = content.rfind('\n/* End XCConfigurationList section */')
            if insert_pos != -1:
                # Найдем конец этой строки
                insert_pos = content.find('\n', insert_pos + 1)
                content = (
                    content[:insert_pos] +
                    '\n\n/* Begin XCRemoteSwiftPackageReference section */\n'
                    + pkg_ref_block +
                    '/* End XCRemoteSwiftPackageReference section */'
                    + content[insert_pos:]
                )
            else:
                print("  ⚠  Не могу найти место для вставки XCRemoteSwiftPackageReference")

    # 2. XCSwiftPackageProductDependency section
    if prod_dep_block:
        if '/* Begin XCSwiftPackageProductDependency section */' in content:
            content = re.sub(
                r'(/\* Begin XCSwiftPackageProductDependency section \*/\n)',
                r'\1' + prod_dep_block,
                content, count=1
            )
        else:
            # Вставить после XCRemoteSwiftPackageReference section
            insert_pos = content.rfind('/* End XCRemoteSwiftPackageReference section */')
            if insert_pos != -1:
                insert_pos = content.find('\n', insert_pos) + 1
                content = (
                    content[:insert_pos] +
                    '\n/* Begin XCSwiftPackageProductDependency section */\n'
                    + prod_dep_block +
                    '/* End XCSwiftPackageProductDependency section */'
                    + content[insert_pos:]
                )
            else:
                print("  ⚠  Не могу найти место для вставки XCSwiftPackageProductDependency")

    # 3. PBXBuildFile (Frameworks)
    if build_file_block:
        content = re.sub(
            r'(/\* Begin PBXBuildFile section \*/\n)',
            r'\1' + build_file_block,
            content, count=1
        )

    # 4. packageReferences в PBXProject (top-level only)
    # ──────────────────────────────────────────────────────────────────────
    # Robust line-based approach:
    #  a) Remove any wrongly placed packageReferences (inside attributes/
    #     SystemCapabilities) left by previous runs.
    #  b) Collect ALL XCRemoteSwiftPackageReference UUIDs now in the file
    #     (both pre-existing and freshly inserted above).
    #  c) If packageReferences array is missing from PBXProject body,
    #     inject it before 'targets = ('. If it exists, add missing UUIDs.
    # ──────────────────────────────────────────────────────────────────────

    # a) Strip wrongly placed packageReferences (inside com.apple.* / attributes)
    wrong_pkg_pat = re.compile(
        r'(com\.apple\.\S+\s*=\s*\{[^}]*?enabled\s*=\s*1;\s*)'
        r'(packageReferences\s*=\s*\(.*?\);\s*)',
        re.DOTALL
    )
    if wrong_pkg_pat.search(content):
        content = wrong_pkg_pat.sub(r'\1', content)
        print('  ✓  Удалён ошибочно размещённый packageReferences из блока attributes')

    # b) Collect all unique XCRemoteSwiftPackageReference UUIDs
    all_pkg_uuids = []
    seen_uuids = set()
    for u in re.findall(
        r'([0-9A-F]{24})\s*/\*\s*XCRemoteSwiftPackageReference\s+"',
        content
    ):
        if u not in seen_uuids:
            seen_uuids.add(u)
            all_pkg_uuids.append(u)

    if all_pkg_uuids:
        file_lines = content.splitlines(keepends=True)

        # Find bounds of PBXProject body
        proj_start = None
        targets_idx = None
        end_proj_idx = None
        for i, line in enumerate(file_lines):
            if proj_start is None and 'isa = PBXProject;' in line:
                proj_start = i
            if proj_start is not None:
                if '/* End PBXProject section */' in line:
                    end_proj_idx = i
                    break
                if re.match(r'\s+targets\s*=\s*\(', line):
                    targets_idx = i

        # Find existing packageReferences within PBXProject body
        pkg_ref_line = None
        if proj_start is not None and targets_idx is not None:
            for i in range(proj_start, targets_idx):
                if 'packageReferences' in file_lines[i]:
                    pkg_ref_line = i
                    break

        if pkg_ref_line is not None:
            # Array exists — find closing ');' and insert any missing UUIDs
            close_idx = None
            for i in range(pkg_ref_line + 1, len(file_lines)):
                if re.match(r'\s+\);', file_lines[i]):
                    close_idx = i
                    break
            if close_idx is not None:
                existing = ''.join(file_lines[pkg_ref_line:close_idx])
                indent_m = re.match(r'(\s+)', file_lines[close_idx])
                ind = (indent_m.group(1) if indent_m else '                        ') + '\t'
                to_add_uuids = [u for u in all_pkg_uuids if u not in existing]
                for u in reversed(to_add_uuids):
                    file_lines.insert(close_idx, f'{ind}{u} /* XCRemoteSwiftPackageReference */,\n')
                if to_add_uuids:
                    print(f'  ✓  Добавлены {len(to_add_uuids)} UUID в packageReferences')
        elif targets_idx is not None:
            # No array — inject before targets = (
            indent_m = re.match(r'(\s+)targets', file_lines[targets_idx])
            ind = indent_m.group(1) if indent_m else '                        '
            inject = (
                [f'{ind}packageReferences = (\n'] +
                [f'{ind}\t{u} /* XCRemoteSwiftPackageReference */,\n' for u in all_pkg_uuids] +
                [f'{ind});\n']
            )
            for line in reversed(inject):
                file_lines.insert(targets_idx, line)
            print(f'  ✓  Создан packageReferences ({len(all_pkg_uuids)} refs) в PBXProject')
        else:
            print('  ⚠  Не удалось найти место для packageReferences в PBXProject — добавьте вручную')

        content = ''.join(file_lines)

    # 5. packageProductDependencies в таргете UnityFramework
    if prod_dep_uuids:
        # Find UnityFramework target
        target_pat = re.compile(
            r'(\/\*\s*UnityFramework\s*\*\/\s*=\s*\{[^}]*?packageProductDependencies\s*=\s*\()(.*?)(\);)',
            re.DOTALL
        )
        m = target_pat.search(content)
        if m:
            insert = ''
            for uuid in prod_dep_uuids:
                insert += f'\n\t\t\t\t{uuid} /* XCSwiftPackageProductDependency */,'
            content = content[:m.start(2)] + insert + content[m.start(2):]
            print("  ✓  Добавлены packageProductDependencies в таргет UnityFramework")
        else:
            # Inject array into target body
            target_body_pat = re.compile(
                r'(\/\*\s*UnityFramework\s*\*\/\s*=\s*\{[^}]*?isa\s*=\s*PBXNativeTarget)(.*?)(};)',
                re.DOTALL
            )
            mb = target_body_pat.search(content)
            if mb:
                deps_str = '\n'.join(
                    f'\t\t\t\t{uuid} /* XCSwiftPackageProductDependency */,'
                    for uuid in prod_dep_uuids
                )
                inject = (
                    f'\t\t\tpackageProductDependencies = (\n'
                    f'{deps_str}\n'
                    f'\t\t\t);\n'
                )
                content = content[:mb.end(2)] + inject + content[mb.end(2):]
                print("  ✓  Создан packageProductDependencies в таргете UnityFramework")
            else:
                print("  ⚠  Таргет UnityFramework не найден — добавьте packageProductDependencies вручную")

    # 6. Frameworks build phase (UnityFramework)
    if framework_uuids:
        phase_uuid = _find_unityframework_frameworks_phase(content)
        if phase_uuid:
            fw_phase_pat = re.compile(
                rf'({re.escape(phase_uuid)}\b.*?files\s*=\s*\()(.*?)(\);)',
                re.DOTALL
            )
            m = fw_phase_pat.search(content)
            if m:
                insert = ''
                for (build_uuid, prod_uuid, product) in framework_uuids:
                    insert += f'\n\t\t\t\t{build_uuid} /* {product} in Frameworks */,'
                content = content[:m.start(2)] + insert + content[m.start(2):]
                print("  ✓  Добавлены SPM-frameworks в UnityFramework Frameworks build phase")
            else:
                print(f"  ⚠  Не удалось найти файловый список для phase {phase_uuid}")
        else:
            # Fallback: первая попавшаяся PBXFrameworksBuildPhase
            fw_phase_pat = re.compile(
                r'(\/\* Begin PBXFrameworksBuildPhase section \*\/.*?files\s*=\s*\()(.*?)(\);)',
                re.DOTALL
            )
            m = fw_phase_pat.search(content)
            if m:
                insert = ''
                for (build_uuid, prod_uuid, product) in framework_uuids:
                    insert += f'\n\t\t\t\t{build_uuid} /* {product} in Frameworks */,'
                content = content[:m.start(2)] + insert + content[m.start(2):]
                print("  ✓  Добавлены SPM-frameworks в PBXFrameworksBuildPhase (fallback)")
            else:
                print("  ⚠  PBXFrameworksBuildPhase не найдена — добавьте frameworks вручную")

    with open(pbxproj_path, 'w', encoding='utf-8') as f:
        f.write(content)

    print(f"  → Saved: {pbxproj_path}")


# ──────────────────────────────────────────────────────────────────────────────

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <path/to/project.pbxproj>")
        sys.exit(1)
    patch(sys.argv[1])
