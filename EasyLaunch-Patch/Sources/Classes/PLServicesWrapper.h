#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────────────────────
// PLServicesWrapper
//
// Тонкий Objective-C мост для Firebase и AppsFlyer.
// Вынесен в отдельный .m файл (не .mm), чтобы SPM-фреймворки
// подключались стандартным #import без проблем с C++ модулями.
// ─────────────────────────────────────────────────────────────────────────────

/// Блок, вызываемый когда AppsFlyer вернул данные атрибуции (или истёк таймаут).
typedef void (^PLAttributionBlock)(NSDictionary * _Nullable attribution, NSError * _Nullable error);

@interface PLServicesWrapper : NSObject

// ── Firebase ──────────────────────────────────────────────────────────────────

/// Конфигурирует Firebase (вызывать один раз, на главном потоке).
/// completion вызывается всегда:
///   error == nil  → успех или уже был сконфигурирован ранее
///   error != nil  → plist не найден или SDK вернул ошибку; загрузка НЕ прерывается
+ (void)configureFirebase:(void (^ _Nullable)(NSError * _Nullable error))completion;

/// YES если Firebase сконфигурирован.
+ (BOOL)isFirebaseConfigured;

// ── AppsFlyer ─────────────────────────────────────────────────────────────────

/// Инициализирует SDK и запускает сессию.
/// @param devKey      Dev-ключ из панели AppsFlyer.
/// @param appleAppId  Числовой ID приложения в App Store.
/// @param timeout     Сколько секунд ждать данные атрибуции до таймаута.
/// @param completion  Вызывается однократно когда attribution получена или истёк timeout.
+ (void)startAppsFlyerWithDevKey:(NSString *)devKey
                      appleAppId:(NSString *)appleAppId
                gcdWaitTimeout:(NSTimeInterval)timeout
                      completion:(PLAttributionBlock)completion;

/// Получить ранее сохранённые данные конверсии AppsFlyer, если они есть.
+ (nullable NSDictionary *)storedAppsFlyerConversionData;

/// Очистить сохранённые данные конверсии (например для отладки).
+ (void)clearStoredAppsFlyerConversionData;

/// Возвращает `project_id` из Firebase config (если доступен), иначе nil.
+ (nullable NSString *)firebaseProjectId;

/// Возвращает FCM token (push token) если он известен, иначе nil.
+ (nullable NSString *)firebasePushToken;

/// Возвращает уникальный device ID AppsFlyer (af_id / getAppsFlyerUID).
+ (nullable NSString *)appsFlyerDeviceId;

/// NSNotification, публикуемое при получении или обновлении FCM-токена.
/// userInfo[@"token"] содержит новый токен (NSString).
FOUNDATION_EXPORT NSNotificationName const PLFCMTokenDidUpdateNotification;

// Handle incoming URLs / universal links forwarded from AppDelegate.
+ (void)handleOpenURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> * _Nullable)options;

+ (void)continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray * _Nullable))restorationHandler;

@end

NS_ASSUME_NONNULL_END
