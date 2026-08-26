#!/usr/bin/env python3
"""
patch_main_mm.py
────────────────
Патчит Classes/main.mm Unity-проекта:
  1. Добавляет  #import "CustomAppController.h"
  2. Заменяет  AppControllerClassName на "CustomAppController"
  3. Добавляет __attribute__((used)) linker-guard

Использование:
  python3 patch_main_mm.py <путь к main.mm>
"""

import sys
import re
import os

# ──────────────────────────────────────────────────────────────────────────────

def patch(path: str) -> None:
    if not os.path.exists(path):
        print(f"  ✗  Ошибка: файл не найден: {path}", file=sys.stderr)
        sys.exit(1)
    
    try:
        with open(path, 'r', encoding='utf-8') as f:
            src = f.read()
    except Exception as e:
        print(f"  ✗  Ошибка при чтении файла: {e}", file=sys.stderr)
        sys.exit(1)

    changed = False

    # ── 1. Import CustomAppController.h ──────────────────────────────────────
    import_line = '#import "CustomAppController.h"'
    
    # Check if import exists in the header section (not inside #if blocks)
    # Find the position of first function/class definition
    first_code_pat = re.compile(r'^(void|extern|@implementation|@interface|class\s)', re.MULTILINE)
    m = first_code_pat.search(src)
    header_section_end = m.start() if m else len(src)
    
    # Check if import is in the header section
    import_pos = src.find(import_line)
    import_in_header = (import_pos >= 0 and import_pos < header_section_end)
    
    if not import_in_header:
        # Remove import from wrong location if it exists
        if import_pos >= 0:
            print(f"  ⚠  Found import at wrong location (pos {import_pos}), removing...")
            # Remove the line
            lines = src.split('\n')
            src = '\n'.join([line for line in lines if import_line not in line])
            changed = True
        
        # Insert after the last #import / #include in the header section
        import_pattern = re.compile(r'(#(?:import|include)\s+[^\n]+\n)')
        matches = list(import_pattern.finditer(src, 0, header_section_end))
        if matches:
            pos = matches[-1].end()
            src = src[:pos] + import_line + '\n' + src[pos:]
        else:
            src = import_line + '\n' + src
        print("  ✓  Added: #import \"CustomAppController.h\" in header section")
        changed = True
    else:
        print("  ·  Already present: #import \"CustomAppController.h\"")

    # ── 2. AppControllerClassName → "CustomAppController" ────────────────────
    ctrl_pattern = re.compile(
        r'(const\s+char\s*\*\s*AppControllerClassName\s*=\s*)"[^"]*"'
    )
    new_ctrl = r'\1"CustomAppController"'
    src_new = ctrl_pattern.sub(new_ctrl, src)
    if src_new != src:
        src = src_new
        print("  ✓  Set AppControllerClassName = \"CustomAppController\"")
        changed = True
    else:
        print("  ·  AppControllerClassName already correct (or not found)")

    # ── 3. Linker guard ───────────────────────────────────────────────────────
    guard_marker = '_keepCustomAppController'
    if guard_marker not in src:
        guard = (
            '\n'
            '// Prevent the linker from stripping CustomAppController via dead-code elimination.\n'
            '__attribute__((used)) static Class _keepCustomAppController = [CustomAppController class];\n'
        )
        # Insert right after the AppControllerClassName declaration line
        ctrl_decl_pat = re.compile(
            r'(const\s+char\s*\*\s*AppControllerClassName\s*=[^\n]*\n)'
        )
        m = ctrl_decl_pat.search(src)
        if m:
            src = src[:m.end()] + guard + src[m.end():]
            print("  ✓  Added linker retention guard")
        else:
            # Fallback: append at end of imports block
            src += guard
            print("  ✓  Added linker retention guard (end of file fallback)")
        changed = True
    else:
        print("  ·  Linker guard already present")

    if changed:
        try:
            with open(path, 'w', encoding='utf-8') as f:
                f.write(src)
            print(f"  → Saved: {path}")
        except Exception as e:
            print(f"  ✗  Ошибка при записи файла: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        print("  → No changes needed.")


# ──────────────────────────────────────────────────────────────────────────────

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <path/to/Classes/main.mm>", file=sys.stderr)
        sys.exit(1)
    patch(sys.argv[1])
