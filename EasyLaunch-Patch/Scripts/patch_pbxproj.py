#!/usr/bin/env python3
"""
patch_pbxproj.py
────────────────
Добавляет файлы EasyLaunch в Unity-сгенерированный project.pbxproj:
  • PBXFileReference  — объявление каждого файла
  • PBXBuildFile      — запись для .m / .mm файлов
  • Группа Classes    — дочерние ссылки
  • PBXSourcesBuildPhase — источники компиляции
  • PBXFrameworksBuildPhase (UnityFramework) — бинарные зависимости

Использование:
  python3 patch_pbxproj.py <path/to/project.pbxproj> [file1 file2 ...]

Если список файлов не передан, используется встроенный PATCH_FILES.
"""

import sys
import re
import os
import hashlib

# ──────────────────────────────────────────────────────────────────────────────
# Набор файлов патча (используется если аргументы не переданы)
# ──────────────────────────────────────────────────────────────────────────────
DEFAULT_PATCH_FILES = [
    "EasyLaunchConfig.h",
    "CustomAppController.h",
    "CustomAppController.mm",
    "PreloadViewController.h",
    "PreloadViewController.mm",
    "PLServicesWrapper.h",
    "PLServicesWrapper.m",
    "WebViewController.h",
    "WebViewController.m",
    "WebViewConfig.h",
    "WebViewConfig.m",
    "NotificationPromptViewController.h",
    "NotificationPromptViewController.m",
    "ScreenCaptureBlocker.h",
    "ScreenCaptureBlocker.m",
]

# ──────────────────────────────────────────────────────────────────────────────
# Бинарные зависимости, которые нужно прилинковать к UnityFramework
# ──────────────────────────────────────────────────────────────────────────────
FRAMEWORKS_TO_LINK = [
    # FirebaseMessaging, FirebaseCore, AppsFlyerLib добавляются через SPM (add_spm_packages.py)
    {
        'name':       'WebKit.framework',
        'path':       'System/Library/Frameworks/WebKit.framework',
        'sourceTree': 'SDKROOT',
        'fileType':   'wrapper.framework',
    },
]

# ──────────────────────────────────────────────────────────────────────────────

def make_uuid(seed: str) -> str:
    """Детерминированный 24-символьный UUID (как в pbxproj) из seed-строки."""
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()


def file_type(name: str) -> str:
    ext = os.path.splitext(name)[1].lower()
    return {
        '.h':      'sourcecode.c.h',
        '.m':      'sourcecode.c.objc',
        '.mm':     'sourcecode.cpp.objcpp',
        '.png':    'image.png',
        '.jpg':    'image.jpeg',
        '.jpeg':   'image.jpeg',
        '.gif':    'image.gif',
        '.plist':  'text.plist.xml',
        '.xcassets': 'folder.assetcatalog',
        '.storyboard': 'file.storyboard',
        '.xib':    'file.xib',
        '.swift':  'sourcecode.swift',
        '.cpp':    'sourcecode.cpp.cpp',
        '.c':      'sourcecode.c.c',
    }.get(ext, 'file')


def is_source(name: str) -> bool:
    """Файл компилируется (.m / .mm)."""
    return os.path.splitext(name)[1] in ('.m', '.mm')


def is_resource(name: str) -> bool:
    """Файл является ресурсом — копируется в bundle, но не компилируется и не заголовок."""
    return os.path.splitext(name)[1].lower() in (
        '.png', '.jpg', '.jpeg', '.gif', '.webp',
        '.plist', '.xcassets', '.storyboard', '.xib',
        '.json', '.mp4', '.mov', '.wav', '.mp3',
        '.ttf', '.otf', '.xcprivacy', '.lproj',
    )


def _find_main_group_uuid(content: str) -> str | None:
    """Возвращает UUID mainGroup из PBXProject или None, если не найден."""
    m = re.search(r'mainGroup\s*=\s*([0-9A-Fa-f]{24})\s*;', content)
    if m:
        return m.group(1).upper()
    return None


def _find_file_ref_uuid(content: str, filename: str) -> str | None:
    """Возвращает UUID существующего PBXFileReference для filename, или None."""
    m = re.search(
        rf'([0-9A-Fa-f]{{24}}) /\* {re.escape(filename)} \*/ = \{{isa = PBXFileReference',
        content
    )
    return m.group(1).upper() if m else None


def _find_unityframework_frameworks_phase(content: str) -> str | None:
    """
    Возвращает UUID секции PBXFrameworksBuildPhase, принадлежащей
    таргету UnityFramework, или None если не найдено.
    """
    # Находим блок PBXNativeTarget с name = UnityFramework
    target_m = re.search(
        r'/\* UnityFramework \*/ = \{[^}]*?isa = PBXNativeTarget;.*?buildPhases = \((.*?)\);',
        content, re.DOTALL
    )
    if not target_m:
        return None

    phase_uuids = re.findall(r'([0-9A-F]{24})', target_m.group(1))

    # Ищем среди них тот, у которого isa = PBXFrameworksBuildPhase
    for uuid in phase_uuids:
        pat = re.compile(
            rf'{uuid}\b.*?isa\s*=\s*PBXFrameworksBuildPhase\b',
            re.DOTALL
        )
        if pat.search(content):
            return uuid

    return None


def patch_link_frameworks(pbxproj_path: str, frameworks: list = None) -> None:
    """
    Добавляет PBXFileReference + PBXBuildFile для каждого фреймворка/XCFramework
    из списка frameworks и прописывает их в PBXFrameworksBuildPhase таргета
    UnityFramework.
    """
    if frameworks is None:
        frameworks = FRAMEWORKS_TO_LINK

    with open(pbxproj_path, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()

    # Фильтруем уже присутствующие
    to_add = [
        fw for fw in frameworks
        if not re.search(r'path = ' + re.escape(fw['path']) + r'\b', content)
    ]

    if not to_add:
        print("  · Все зависимости уже присутствуют в pbxproj — изменений не требуется.")
        return

    print(f"  → Линкуем {len(to_add)} зависимост(ей): {', '.join(fw['name'] for fw in to_add)}")

    ref_uuids   = {fw['name']: make_uuid('fwref_'   + fw['name']) for fw in to_add}
    build_uuids = {fw['name']: make_uuid('fwbuild_' + fw['name']) for fw in to_add}

    # ── PBXFileReference ─────────────────────────────────────────────────────
    ref_lines = ''
    for fw in to_add:
        uuid = ref_uuids[fw['name']]
        ref_lines += (
            f'\t\t{uuid} /* {fw["name"]} */ = {{'
            f'isa = PBXFileReference; '
            f'lastKnownFileType = {fw["fileType"]}; '
            f'name = {fw["name"]}; path = {fw["path"]}; '
            f'sourceTree = {fw["sourceTree"]}; }};\n'
        )

    content = re.sub(
        r'(/\* Begin PBXFileReference section \*/\n)',
        r'\1' + ref_lines,
        content, count=1
    )

    # ── PBXBuildFile ─────────────────────────────────────────────────────────
    build_lines = ''
    for fw in to_add:
        b_uuid = build_uuids[fw['name']]
        r_uuid = ref_uuids[fw['name']]
        build_lines += (
            f'\t\t{b_uuid} /* {fw["name"]} in Frameworks */ = {{'
            f'isa = PBXBuildFile; fileRef = {r_uuid} /* {fw["name"]} */; }};\n'
        )

    content = re.sub(
        r'(/\* Begin PBXBuildFile section \*/\n)',
        r'\1' + build_lines,
        content, count=1
    )

    # ── PBXFrameworksBuildPhase (UnityFramework) ──────────────────────────────
    phase_uuid = _find_unityframework_frameworks_phase(content)
    if phase_uuid:
        fw_phase_pat = re.compile(
            rf'({re.escape(phase_uuid)}\b.*?files\s*=\s*\()(.*?)(\);)',
            re.DOTALL
        )
        m = fw_phase_pat.search(content)
        if m:
            new_entries = ''
            for fw in to_add:
                new_entries += f'\n\t\t\t\t{build_uuids[fw["name"]]} /* {fw["name"]} in Frameworks */,'
            content = content[:m.start(2)] + new_entries + content[m.start(2):]
            print("  ✓  Добавлены зависимости в UnityFramework Frameworks build phase")
        else:
            print(f"  ⚠  Не удалось найти файловый список для phase {phase_uuid}")
    else:
        # Fallback: первая попавшаяся PBXFrameworksBuildPhase
        fw_fallback = re.compile(
            r'(isa = PBXFrameworksBuildPhase;.*?files\s*=\s*\()(.*?)(\);)',
            re.DOTALL
        )
        m = fw_fallback.search(content)
        if m:
            new_entries = ''
            for fw in to_add:
                new_entries += f'\n\t\t\t\t{build_uuids[fw["name"]]} /* {fw["name"]} in Frameworks */,'
            content = content[:m.start(2)] + new_entries + content[m.start(2):]
            print("  ✓  Добавлены зависимости в PBXFrameworksBuildPhase (fallback)")
        else:
            print("  ⚠  PBXFrameworksBuildPhase не найдена — добавьте зависимости вручную")

    with open(pbxproj_path, 'w', encoding='utf-8') as f:
        f.write(content)

    for fw in to_add:
        print(f"    ✓  {fw['name']}")


def _find_unityiphone_resources_phase(content: str, target_name: str = 'Unity-iPhone') -> str | None:
    targ_m = re.search(
        rf'/\* {re.escape(target_name)} \*/ = \{{[^}}]*?isa = PBXNativeTarget;.*?buildPhases = \((.*?)\);',
        content, re.DOTALL
    )
    if not targ_m:
        return None
    phase_uuids = re.findall(r'([0-9A-F]{24})', targ_m.group(1))
    for uuid in phase_uuids:
        pat = re.compile(rf'{uuid}\b.*?isa\s*=\s*PBXResourcesBuildPhase\b', re.DOTALL)
        if pat.search(content):
            return uuid
    return None


def _ensure_resources_in_groups(content: str, resource_files: list) -> str:
    """
    Убеждается что каждый файл из resource_files:
      1. присутствует в mainGroup (корень проекта) ровно один раз;
      2. присутствует в PBXResourcesBuildPhase таргета Unity-iPhone ровно один раз.
    Дубликаты убирает. Отсутствующие — добавляет.
    """
    if not resource_files:
        return content

    # ── 0. Исправляем lastKnownFileType для ресурсов, если он неверный ────────
    for f in resource_files:
        correct_type = file_type(f)
        # Заменяем только если тип установлен как sourcecode.c.c (ошибка предыдущих версий)
        content = re.sub(
            rf'([0-9A-Fa-f]{{24}} /\* {re.escape(f)} \*/ = \{{[^}}]*?lastKnownFileType = )sourcecode\.c\.c(;)',
            rf'\g<1>{correct_type}\2',
            content
        )

    # ── 1. mainGroup ──────────────────────────────────────────────────────────
    main_group_uuid = _find_main_group_uuid(content)
    if main_group_uuid:
        root_group_pat = re.compile(
            rf'({re.escape(main_group_uuid)}\s*=\s*\{{[^}}]*?children\s*=\s*\()(.*?)(\);)',
            re.DOTALL
        )
        def _fix_root(m: re.Match) -> str:
            children = m.group(2)
            for f in resource_files:
                escaped = re.escape(f)
                # Дедуплицируем: оставляем только первое вхождение
                children = re.sub(
                    rf'\n\s*[0-9A-Fa-f]{{24}} /\* {escaped} \*/,',
                    lambda mo, _state={'seen': False}: (
                        mo.group(0) if not _state['seen'] and not _state.update({'seen': True})
                        else ''
                    ),
                    children
                )
                if not re.search(rf'/\* {escaped} \*/', children):
                    # Используем уже существующий UUID из PBXFileReference, иначе генерируем
                    uuid = _find_file_ref_uuid(content, f) or make_uuid('fileref_' + f)
                    children += f'\n\t\t\t\t{uuid} /* {f} */,'
                    print(f"  ✓  Добавлен ресурс в корневую группу: {f}")
            return m.group(1) + children + m.group(3)

        content = root_group_pat.sub(_fix_root, content, count=1)
    else:
        print("  ⚠  mainGroup не найден — ресурсы в корневую группу добавьте вручную")

    # ── 2. Unity-iPhone Resources build phase ────────────────────────────────
    res_phase_uuid = _find_unityiphone_resources_phase(content)
    if res_phase_uuid:
        res_pat = re.compile(
            rf'({re.escape(res_phase_uuid)}\b.*?files\s*=\s*\()(.*?)(\);)',
            re.DOTALL
        )
        def _fix_phase(m: re.Match) -> str:
            files_str = m.group(2)
            for f in resource_files:
                escaped = re.escape(f)
                # Дедупликация: оставляем первое вхождение
                files_str = re.sub(
                    rf'\n\s*[0-9A-F]{{24}} /\* {escaped} in Resources \*/,?\s*',
                    lambda mo, _state={'seen': False}: (
                        mo.group(0) if not _state['seen'] and not _state.update({'seen': True})
                        else '\n'
                    ),
                    files_str
                )
                if not re.search(rf'/\* {escaped} in Resources \*/', files_str):
                    # Ищем существующий PBXBuildFile UUID, иначе генерируем
                    bm = re.search(
                        rf'([0-9A-Fa-f]{{24}}) /\* {re.escape(f)} in Resources \*/ = \{{isa = PBXBuildFile',
                        content
                    )
                    build_uuid = bm.group(1).upper() if bm else make_uuid('buildfile_' + f)
                    files_str += f'\n\t\t\t\t{build_uuid} /* {f} in Resources */,'
                    print(f"  ✓  Добавлен ресурс в Unity-iPhone Resources phase: {f}")
            return m.group(1) + files_str + m.group(3)

        content = res_pat.sub(_fix_phase, content, count=1)
    else:
        print("  ⚠  PBXResourcesBuildPhase Unity-iPhone не найдена")

    # ── 3. Убеждаемся, что PBXBuildFile существует для каждого ресурса ───────
    build_section_pat = re.compile(r'(/\* Begin PBXBuildFile section \*/\n)', re.DOTALL)
    for f in resource_files:
        if not re.search(rf'/\* {re.escape(f)} in Resources \*/ = \{{isa = PBXBuildFile', content):
            uuid = make_uuid('buildfile_' + f)
            ref_uuid = make_uuid('fileref_' + f)
            line = (
                f'\t\t{uuid} /* {f} in Resources */ = {{'
                f'isa = PBXBuildFile; fileRef = {ref_uuid} /* {f} */; }};\n'
            )
            content = build_section_pat.sub(r'\1' + line, content, count=1)
            print(f"  ✓  Создан PBXBuildFile для ресурса: {f}")

    return content


def patch(pbxproj_path: str, patch_files: list) -> None:
    with open(pbxproj_path, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()

    # ── Делим файлы патча на исходники и ресурсы один раз ───────────────────
    all_resource_files = [f for f in patch_files if is_resource(f)]

    # ── Фильтруем файлы, которых ещё нет в pbxproj ───────────────────────────
    already = set()
    for name in patch_files:
        if re.search(r'path\s*=\s*"?' + re.escape(name) + r'"?\s*;', content):
            already.add(name)

    to_add = [f for f in patch_files if f not in already]

    if not to_add:
        print("  · Новых файлов нет — проверяем группы и фазы для ресурсов …")
        content = _ensure_resources_in_groups(content, all_resource_files)
        with open(pbxproj_path, 'w', encoding='utf-8') as f:
            f.write(content)
        return

    print(f"  → Добавляем {len(to_add)} файл(ов): {', '.join(to_add)}")

    file_ref_uuids  = {f: make_uuid('fileref_'  + f) for f in to_add}
    # У нас будут PBXBuildFile как для .m/.mm (Sources), так и для ресурсов (.png, .plist и т.д.)
    build_file_uuids = {f: make_uuid('buildfile_' + f) for f in to_add}

    # ── PBXFileReference ─────────────────────────────────────────────────────
    ref_lines = ''
    for f in to_add:
        ftype = file_type(f)
        uuid  = file_ref_uuids[f]
        ref_lines += (
            f'\t\t{uuid} /* {f} */ = {{'
            f'isa = PBXFileReference; fileEncoding = 4; '
            f'lastKnownFileType = {ftype}; name = {f}; path = {f}; '
            f'sourceTree = "<group>"; }};\n'
        )

    content = re.sub(
        r'(/\* Begin PBXFileReference section \*/\n)',
        r'\1' + ref_lines,
        content, count=1
    )

    # ── PBXBuildFile ─────────────────────────────────────────────────────────
    build_lines = ''
    for f in to_add:
        uuid     = build_file_uuids[f]
        ref_uuid = file_ref_uuids[f]
        if is_source(f):
            build_lines += (
                f'\t\t{uuid} /* {f} in Sources */ = {{'
                f'isa = PBXBuildFile; fileRef = {ref_uuid} /* {f} */; }};\n'
            )
        elif is_resource(f):
            build_lines += (
                f'\t\t{uuid} /* {f} in Resources */ = {{'
                f'isa = PBXBuildFile; fileRef = {ref_uuid} /* {f} */; }};\n'
            )

    if build_lines:
        content = re.sub(
            r'(/\* Begin PBXBuildFile section \*/\n)',
            r'\1' + build_lines,
            content, count=1
        )

    # ── Раскладываем file references по группам Xcode ───────────────────────
    source_files_to_add = [f for f in to_add if is_source(f)]

    classes_pat = re.compile(
        r'(/\* Classes \*/\s*=\s*\{[^}]*?children\s*=\s*\()(.*?)(\);)',
        re.DOTALL
    )

    classes_stats = {'added_sources': 0, 'removed_resources': 0}

    def _update_classes_children(m: re.Match) -> str:
        children = m.group(2)

        for f in all_resource_files:
            pat = re.compile(rf'\n\s*[0-9A-F]{{24}} /\* {re.escape(f)} \*/,\s*')
            children, removed = pat.subn('\n', children)
            classes_stats['removed_resources'] += removed

        for f in source_files_to_add:
            if re.search(rf'/\* {re.escape(f)} \*/', children):
                continue
            children += f'\n\t\t\t\t{file_ref_uuids[f]} /* {f} */,'
            classes_stats['added_sources'] += 1

        return m.group(1) + children + m.group(3)

    content, classes_updated = classes_pat.subn(_update_classes_children, content, count=1)
    if classes_updated:
        if classes_stats['added_sources']:
            print("  ✓  Добавлены исходники в группу Classes")
        if classes_stats['removed_resources']:
            print("  ✓  Убраны ресурсы из группы Classes")
    elif source_files_to_add:
        print("  ⚠  Группа Classes не найдена — исходники добавьте вручную")

    # ── PBXSourcesBuildPhase ─────────────────────────────────────────────────
    unityfw_sources_pat = re.compile(
        r'(9D25AB98213FB47800354C27 /\* Sources \*/ = \{[^}]*?files\s*=\s*\()(.*?)(\);)',
        re.DOTALL
    )
    m = unityfw_sources_pat.search(content)
    if m:
        new_sources = ''
        for f in to_add:
            if not is_source(f):
                continue
            new_sources += f'\n\t\t\t\t{build_file_uuids[f]} /* {f} in Sources */, '
        if new_sources:
            content = content[:m.start(2)] + new_sources + content[m.start(2):]
            print("  ✓  Добавлены .m/.mm в UnityFramework target")
    else:
        sources_pat = re.compile(
            r'(/\* Begin PBXSourcesBuildPhase section \*/.*?files\s*=\s*\()(.*?)(\);)',
            re.DOTALL
        )
        m = sources_pat.search(content)
        if m:
            new_sources = ''
            for f in to_add:
                if not is_source(f):
                    continue
                new_sources += f'\n\t\t\t\t{build_file_uuids[f]} /* {f} in Sources */,'
            if new_sources:
                content = content[:m.start(2)] + new_sources + content[m.start(2):]
            print("  ✓  Добавлены .m/.mm в PBXSourcesBuildPhase")
        else:
            print("  ⚠  PBXSourcesBuildPhase не найдена — добавьте .m/.mm файлы вручную")

    # ── Группы и фазы для ресурсов (mainGroup + Unity-iPhone Resources) ──────
    content = _ensure_resources_in_groups(content, all_resource_files)

    with open(pbxproj_path, 'w', encoding='utf-8') as f:
        f.write(content)

    for fname in to_add:
        print(f"    ✓  {fname}")


# ──────────────────────────────────────────────────────────────────────────────

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <project.pbxproj> [file1 file2 ...]")
        sys.exit(1)

    pbxproj   = sys.argv[1]
    provided  = sys.argv[2:]
    files     = provided if provided else DEFAULT_PATCH_FILES

    print("  [pass 1/2] Применение изменений в project.pbxproj...")
    patch(pbxproj, files)
    print()
    print("  [pass 1/2][frameworks] Линковка бинарных зависимостей к UnityFramework...")
    patch_link_frameworks(pbxproj)

    print()
    print("  [pass 2/2] Повторная валидация и добивка ссылок/фаз...")
    patch(pbxproj, files)
    print()
    print("  [pass 2/2][frameworks] Контрольная проверка зависимостей UnityFramework...")
    patch_link_frameworks(pbxproj)
