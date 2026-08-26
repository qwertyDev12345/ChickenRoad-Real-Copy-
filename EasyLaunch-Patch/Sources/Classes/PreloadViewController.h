#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Completion blocks
// ─────────────────────────────────────────────────────────────────────────────

/// Вызывается когда все проверки пройдены и решение — продолжать запуск Unity.
typedef void (^PreloadCompletionBlock)(void);

/// Вызывается когда эндпоинт вернул URL — нужно показать WebView/SafariVC
/// вместо Unity. Передаётся абсолютный URL.
typedef void (^PreloadOpenURLBlock)(NSURL *url);

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Конфигурация сервисов, используемых на экране загрузки.
@interface PreloadConfig : NSObject

/// Dev-ключ AppsFlyerr (из панели AppsFlyer).
@property (nonatomic, copy) NSString *appsDevKey;

/// Apple App ID (числовой идентификатор приложения в App Store).
@property (nonatomic, copy) NSString *appleAppId;

/// Базовый URL эндпоинта без завершающего слэша, например @"https://example.com".
@property (nonatomic, copy) NSString *endpointURL;

/// Таймаут ожидания данных атрибуции AppsFlyerr (секунды). По умолчанию 15.
@property (nonatomic, assign) NSTimeInterval appsflyerTimeout;

/// HTTP-таймаут запроса к эндпоинту (секунды). По умолчанию 10.
@property (nonatomic, assign) NSTimeInterval endpointTimeout;

+ (instancetype)configWithAppsDevKey:(NSString *)devKey
                          appleAppId:(NSString *)appleId
                         endpointURL:(NSString *)endpoint;

@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PreloadViewController
// ─────────────────────────────────────────────────────────────────────────────

/// Экран загрузки, который последовательно выполняет:
///   1. Проверку сети
///   2. Инициализацию Firebase
///   3. Инициализацию AppsFlyerr + ожидание данных атрибуции
///   4. Запрос к эндпоинту с данными атрибуции
///
/// По результату вызывается либо `onComplete` (запускать Unity),
/// либо `onOpenURL` (показать WebView).
@interface PreloadViewController : UIViewController

/// Конфигурация сервисов. Установите до появления экрана.
@property (nonatomic, strong, nullable) PreloadConfig *config;

/// Вызывается на главном потоке — запускать Unity / нативный контент.
@property (nonatomic, copy, nullable) PreloadCompletionBlock onComplete;

/// Вызывается на главном потоке — показать WebView с переданным URL.
@property (nonatomic, copy, nullable) PreloadOpenURLBlock onOpenURL;

/// Запустить цепочку проверок вручную (вызывается автоматически в viewDidAppear).
- (void)startChecks;

/// URL из тела push-уведомления, по которому было открыто приложение.
/// Если установлен до viewDidAppear — цепочка проверок пропускается и сразу
/// вызывается onOpenURL с этим URL.
@property (nonatomic, strong, nullable) NSURL *pendingPushURL;

@end

NS_ASSUME_NONNULL_END
