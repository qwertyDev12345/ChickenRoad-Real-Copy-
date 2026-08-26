#!/usr/bin/env python3
"""
patch_appdelegatelistener.py
─────────────────────────────
Заменяет содержимое Classes/PluginBase/AppDelegateListener.h на требуемый
заголовок (создаёт резервную копию <file>.bak).

Использование:
  python3 patch_appdelegatelistener.py <путь к AppDelegateListener.h>
"""

import sys
import os


DESIRED = '''#pragma once

#include "LifeCycleListener.h"


@protocol AppDelegateListener<LifeCycleListener>
@optional
// these do not have apple defined notifications, so we use our own notifications

// notification will be posted from
// - (BOOL)application:(UIApplication*)application openURL:(NSURL*)url sourceApplication:(NSString*)sourceApplication annotation:(id)annotation
// notification user data is the NSDictionary containing all the params
- (void)onOpenURL:(NSNotification*)notification;

// notification will be posted from
// - (BOOL)application:(UIApplication*)application willFinishLaunchingWithOptions:(NSDictionary*)launchOptions
// notification user data is the NSDictionary containing launchOptions
- (void)applicationWillFinishLaunchingWithOptions:(NSNotification*)notification;
// notification will be posted from
// - (void)application:(UIApplication*)application handleEventsForBackgroundURLSession:(nonnull NSString *)identifier completionHandler:(nonnull void (^)())completionHandler
// notification user data is NSDictionary with one item where key is session identifier and value is completion handler
- (void)onHandleEventsForBackgroundURLSession:(NSNotification*)notification;

// these are just hooks to existing notifications
- (void)applicationDidReceiveMemoryWarning:(NSNotification*)notification;
- (void)applicationSignificantTimeChange:(NSNotification*)notification;
@end

void UnityRegisterAppDelegateListener(id<AppDelegateListener> obj);
void UnityUnregisterAppDelegateListener(id<AppDelegateListener> obj);

#ifdef __cplusplus
extern "C" {
#endif

extern __attribute__((visibility("default"))) NSString* const kUnityDidRegisterForRemoteNotificationsWithDeviceToken;
extern __attribute__((visibility("default"))) NSString* const kUnityDidFailToRegisterForRemoteNotificationsWithError;
extern __attribute__((visibility("default"))) NSString* const kUnityDidReceiveRemoteNotification;
extern __attribute__((visibility("default"))) NSString* const kUnityOnOpenURL;
extern __attribute__((visibility("default"))) NSString* const kUnityWillFinishLaunchingWithOptions;
extern __attribute__((visibility("default"))) NSString* const kUnityHandleEventsForBackgroundURLSession;

#ifdef __cplusplus
}
#endif
'''


def patch(path: str) -> int:
    if not os.path.exists(path):
        print(f"  ✗  Ошибка: файл не найден: {path}", file=sys.stderr)
        return 1

    try:
        with open(path, 'r', encoding='utf-8') as f:
            src = f.read()
    except Exception as e:
        print(f"  ✗  Ошибка при чтении файла: {e}", file=sys.stderr)
        return 2

    # Нормализуем переводы строк для сравнения
    if src.replace('\r\n', '\n') == DESIRED.replace('\r\n', '\n'):
        print("  ·  No changes needed — file already matches desired content")
        return 0

    # Создаём резервную копию
    bak = path + '.bak'
    try:
        with open(bak, 'w', encoding='utf-8') as f:
            f.write(src)
        print(f"  ✓  Backup saved to: {bak}")
    except Exception as e:
        print(f"  ✗  Не удалось создать бэкап: {e}", file=sys.stderr)
        return 3

    # Записываем требуемое содержимое
    try:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(DESIRED)
        print(f"  → Saved: {path}")
        return 0
    except Exception as e:
        print(f"  ✗  Ошибка при записи файла: {e}", file=sys.stderr)
        return 4


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <path/to/Classes/PluginBase/AppDelegateListener.h>", file=sys.stderr)
        sys.exit(1)
    sys.exit(patch(sys.argv[1]))
