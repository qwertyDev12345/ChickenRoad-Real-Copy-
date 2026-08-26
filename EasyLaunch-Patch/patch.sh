#!/usr/bin/env bash
# =============================================================================
# EasyLaunch patch.sh
# =============================================================================
# Патчит Unity-сгенерированный Xcode-проект: добавляет кастомный preload-экран
# с Firebase, AppsFlyer и WebView-редиректом.
#
# Использование:
#   ./patch.sh <путь к Xcode-проекту>
#
# Пример:
#   ./patch.sh ~/MyGame/iOS/MyGame
#
# Требования:
#   - macOS с python3 в PATH
#   - Unity 2020.3+ Xcode-проект
# =============================================================================

set -euo pipefail

# ── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[EasyLaunch]${NC} $*"; }
success() { echo -e "${GREEN}[EasyLaunch]${NC} $*"; }
warn()    { echo -e "${YELLOW}[EasyLaunch] WARN:${NC} $*"; }
error()   { echo -e "${RED}[EasyLaunch] ERROR:${NC} $*"; exit 1; }

# ── Директория скрипта ───────────────────────────────────────────────────────
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SOURCES_DIR="$SCRIPT_DIR/Sources/Classes"
SCRIPTS_DIR="$SCRIPT_DIR/Scripts"

# ── Аргументы ────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    echo ""
    echo "  Использование: $0 <путь к Xcode-проекту>"
    echo ""
    echo "  <path> — папка, содержащая Classes/, Unity-iPhone.xcodeproj и т.д."
    echo "  Пример: $0 ~/MyGame/iOS/MyGame"
    echo ""
    exit 1
fi

XCODE_ROOT="$1"

# ── Проверки ──────────────────────────────────────────────────────────────────
[[ -d "$XCODE_ROOT" ]]              || error "Директория не найдена: $XCODE_ROOT"
CLASSES_DIR="$XCODE_ROOT/Classes"
[[ -d "$CLASSES_DIR" ]]             || error "Classes/ не найдена внутри $XCODE_ROOT"
MAIN_MM="$CLASSES_DIR/main.mm"
[[ -f "$MAIN_MM" ]]                 || error "Classes/main.mm не найден"

PLUGINBASE_DIR="$CLASSES_DIR/PluginBase"
APPDELEGATELISTENER_H="$PLUGINBASE_DIR/AppDelegateListener.h"
if [[ ! -f "$APPDELEGATELISTENER_H" ]]; then
    warn "AppDelegateListener.h не найден в $PLUGINBASE_DIR - пропускаем патчинг этого файла"
    APPDELEGATELISTENER_H=""
fi

XCODEPROJ="$(find "$XCODE_ROOT" -maxdepth 2 -name "*.xcodeproj" | head -1)"
[[ -n "$XCODEPROJ" ]]              || error ".xcodeproj не найден внутри $XCODE_ROOT"
PBXPROJ="$XCODEPROJ/project.pbxproj"
[[ -f "$PBXPROJ" ]]               || error "project.pbxproj не найден: $PBXPROJ"

info "Xcode-проект : $XCODE_ROOT"
info "Classes      : $CLASSES_DIR"
info "pbxproj      : $PBXPROJ"
echo ""

# ── Список файлов для копирования ────────────────────────────────────────────
declare -a PATCH_FILES=(
    "EasyLaunchConfig.h"
    "CustomAppController.h"
    "CustomAppController.mm"
    "PreloadViewController.h"
    "PreloadViewController.mm"
    "PLServicesWrapper.h"
    "PLServicesWrapper.m"
    "WebViewController.h"
    "WebViewController.m"
    "WebViewConfig.h"
    "WebViewConfig.m"
    "NotificationPromptViewController.h"
    "NotificationPromptViewController.m"
    "ScreenCaptureBlocker.h"
    "ScreenCaptureBlocker.m"
)

# Дополнительные ресурсы (изображения и plist)
PATCH_FILES+=(
    "AppLogo.png"
    "LaunchBackground.png"
    "GoogleService-Info.plist"
)

# ── Загрузка конфига ──────────────────────────────────────────────────────────
CONFIG_FILE="$SCRIPT_DIR/easylaunch.config"
EL_APPSFLYER_DEV_KEY="YOUR_APPSFLYER_DEV_KEY"
EL_APPLE_APP_ID="YOUR_APPLE_APP_ID"
EL_ENDPOINT_URL="https://your-server.com"
EL_LOADING_TITLE="Loading"

if [[ -f "$CONFIG_FILE" ]]; then
    info "Загрузка конфигурации из easylaunch.config …"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    warn "easylaunch.config не найден — используются placeholder-значения."
    warn "Скопируйте easylaunch.config.example → easylaunch.config и заполните ключи."
fi

# =============================================================================
# ШАГ 1 — Копирование исходников
# =============================================================================
info "Шаг 1/6 → Копирование файлов EasyLaunch в $CLASSES_DIR …"

for f in "${PATCH_FILES[@]}"; do
    # Возможные расположения исходных файлов
    src_candidates=(
        "$SOURCES_DIR/$f"
        "$SCRIPT_DIR/$f"
        "$SCRIPT_DIR/../$f"
        "$XCODE_ROOT/$f"
    )
    src=""
    for c in "${src_candidates[@]}"; do
        if [[ -f "$c" ]]; then
            src="$c"
            break
        fi
    done

    if [[ -z "$src" ]]; then
        warn "Исходный файл не найден, пропуск: $f"
        continue
    fi

    # Куда копируем: исходники идут в Classes/, ресурсы — в корень Xcode-проекта
    if [[ "$f" == *.png || "$f" == *.plist ]]; then
        dst="$XCODE_ROOT/$f"
    else
        dst="$CLASSES_DIR/$f"
    fi

    cp "$src" "$dst"
    echo "    ✓  $f -> ${dst#${XCODE_ROOT}/}"
done
success "Файлы скопированы."

# =============================================================================
# ШАГ 2 — Подстановка конфига в EasyLaunchConfig.h
# =============================================================================
info "Шаг 2/6 → Применение конфигурации в EasyLaunchConfig.h …"

DEST_CONFIG="$CLASSES_DIR/EasyLaunchConfig.h"

# sed -i синтаксис: macOS требует '' после -i, Linux — нет
if [[ "$(uname)" == "Darwin" ]]; then
    SED_I=(sed -i '')
else
    SED_I=(sed -i)
fi

"${SED_I[@]}" \
    -e "s|#define EL_APPSFLYER_DEV_KEY.*|#define EL_APPSFLYER_DEV_KEY        @\"${EL_APPSFLYER_DEV_KEY}\"|" \
    -e "s|#define EL_APPLE_APP_ID.*|#define EL_APPLE_APP_ID             @\"${EL_APPLE_APP_ID}\"|" \
    -e "s|#define EL_ENDPOINT_URL.*|#define EL_ENDPOINT_URL             @\"${EL_ENDPOINT_URL}\"|" \
    -e "s|#define EL_LOADING_TITLE.*|#define EL_LOADING_TITLE            @\"${EL_LOADING_TITLE}\"|" \
    "$DEST_CONFIG"

success "EasyLaunchConfig.h обновлён."

# =============================================================================
# ШАГ 3 — Патч Classes/main.mm
# =============================================================================
info "Шаг 3/6 → Патчинг Classes/main.mm …"
if python3 "$SCRIPTS_DIR/patch_main_mm.py" "$MAIN_MM"; then
    success "main.mm обработан."
else
    error "Ошибка при патчинге main.mm"
fi

# =============================================================================
# ШАГ 4 — Патч Classes/PluginBase/AppDelegateListener.h
# =============================================================================
if [[ -n "$APPDELEGATELISTENER_H" ]]; then
    info "Шаг 4/6 → Патчинг AppDelegateListener.h …"
    if python3 "$SCRIPTS_DIR/patch_appdelegatelistener.py" "$APPDELEGATELISTENER_H"; then
        success "AppDelegateListener.h обработан."
    else
        error "Ошибка при патчинге AppDelegateListener.h"
    fi
else
    info "Шаг 4/6 → Пропущен (AppDelegateListener.h не найден)"
fi

# =============================================================================
# ШАГ 5 — Обновление project.pbxproj
# =============================================================================
info "Шаг 5/6 → Обновление project.pbxproj …"

# 5a. Добавляем файлы EasyLaunch
python3 "$SCRIPTS_DIR/patch_pbxproj.py" "$PBXPROJ" "${PATCH_FILES[@]}"

# 5b. Добавляем SPM-пакеты (Firebase + AppsFlyer)
# Выполняется ДО добавления NotificationService Extension, чтобы Ruby-скрипт
# мог найти Firebase package reference и прилинковать FirebaseMessaging к extension
python3 "$SCRIPTS_DIR/add_spm_packages.py" "$PBXPROJ"

success "project.pbxproj обновлён."

# =============================================================================
# ДОПОЛНИТЕЛЬНО 5c — Entitlements (aps-environment для push-уведомлений)
# =============================================================================
info "Добавление entitlements для push-уведомлений …"

ENTITLEMENTS_SRC="$SCRIPT_DIR/Sources/Unity-iPhone.entitlements"
ENTITLEMENTS_DST_DIR="$XCODE_ROOT/Unity-iPhone"
ENTITLEMENTS_DST="$ENTITLEMENTS_DST_DIR/Unity-iPhone.entitlements"
ENTITLEMENTS_PROJ_PATH="Unity-iPhone/Unity-iPhone.entitlements"

if [[ -f "$ENTITLEMENTS_SRC" ]]; then
    mkdir -p "$ENTITLEMENTS_DST_DIR"
    cp "$ENTITLEMENTS_SRC" "$ENTITLEMENTS_DST"
    echo "    ✓  Unity-iPhone.entitlements -> Unity-iPhone/"
    python3 "$SCRIPTS_DIR/add_entitlements.py" "$PBXPROJ" "$ENTITLEMENTS_PROJ_PATH"
    success "Entitlements добавлены."
else
    warn "Sources/Unity-iPhone.entitlements не найден — пропуск."
fi

# =============================================================================
# ДОПОЛНИТЕЛЬНО — Добавление Notification Service Extension таргета
# (после 5b, чтобы Firebase уже присутствовал в packageReferences)
# =============================================================================
info "Добавление Notification Service Extension таргета …"
MAIN_TARGET_NAME="Unity-iPhone"
EXT_TARGET_NAME="NotificationService"
if ruby "$SCRIPTS_DIR/add_notification_extension_service.rb" "$XCODEPROJ" "$MAIN_TARGET_NAME" "$EXT_TARGET_NAME"; then
    success "Notification Service Extension добавлен."
else
    warn "Ошибка при добавлении Notification Service Extension. Продолжаем..."
fi

# =============================================================================
# ДОПОЛНИТЕЛЬНО — Патч Info.plist: разрешения камеры и микрофона
# =============================================================================
info "Добавление разрешений камеры/микрофона в Info.plist …"

INFOPLIST_PATH="$XCODE_ROOT/Info.plist"
if [[ -f "$INFOPLIST_PATH" ]]; then
    if python3 "$SCRIPTS_DIR/patch_infoplist.py" "$INFOPLIST_PATH"; then
        success "Info.plist обновлён."
    else
        warn "Ошибка при патчинге Info.plist — продолжаем."
    fi
else
    warn "Info.plist не найден по пути $INFOPLIST_PATH — пропуск."
fi

# =============================================================================
# ШАГ 6 — Разрешение SPM-зависимостей
# =============================================================================
info "Шаг 6/6 → Загрузка SPM-пакетов (xcodebuild -resolvePackageDependencies) …"
info "  Это может занять несколько минут при первом запуске."
echo ""

if xcodebuild \
    -resolvePackageDependencies \
    -project "$XCODEPROJ" \
    2>&1; then
    success "SPM-пакеты успешно разрешены."
else
    RESOLVE_EXIT=$?
    error "xcodebuild -resolvePackageDependencies завершился с кодом $RESOLVE_EXIT."
fi

# =============================================================================
# ШАГ 7 — Повторный патч после resolvePackageDependencies
# =============================================================================
info "Шаг 7/7 → Повторный прогон patch_pbxproj.py после разрешения зависимостей …"
if python3 "$SCRIPTS_DIR/patch_pbxproj.py" "$PBXPROJ" "${PATCH_FILES[@]}"; then
    success "Повторный пост-resolve патч project.pbxproj выполнен."
else
    error "Ошибка при повторном пост-resolve патчинге project.pbxproj"
fi

# =============================================================================
# Итог
# =============================================================================
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  EasyLaunch patch применён успешно!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Следующие шаги:"
echo ""
echo "  1. Проверьте EasyLaunchConfig.h — все ключи должны быть заполнены."
echo ""
echo "  2. Убедитесь что GoogleService-Info.plist добавлен в таргет."
echo ""
echo "  3. При необходимости добавьте NSUserTrackingUsageDescription"
echo "     в Info.plist ATT iOS 14+."
echo ""
echo "  4. Откройте $XCODEPROJ и собирайте проект."
echo ""
