#import "PreloadViewController.h"
#import "PLServicesWrapper.h"        // Firebase + AppsFlyer bridge (.m, pure ObjC)
#import <UserNotifications/UserNotifications.h>
#import "NotificationPromptViewController.h"

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Персистентный наблюдатель FCM-токена
// ─────────────────────────────────────────────────────────────────────────────

/// Храним наблюдатель сильной ссылкой — живёт всё время жизни приложения.
static id        s_fcmTokenObserver  = nil;
/// URL эндпойнта, известный наблюдателю (не зависит от жизни VC).
static NSString *s_fcmEndpointURL   = nil;

/// Отправляет на сервер поля Firebase + данные конверсии AF.
/// Вызывается из блока наблюдателя (без ссылки на VC).
static void PL_sendFirebaseFields(NSString *endpointURL)
{
    NSString *pushToken       = [PLServicesWrapper firebasePushToken];
    if (pushToken.length == 0) return; // токен ещё недоступен

    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"bundle_id"]   = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    body[@"platform"]    = @"ios";
    body[@"os"]          = @"iOS";

    NSString *afId = [PLServicesWrapper appsFlyerDeviceId];
    if (afId.length)  body[@"af_id"] = afId;

    body[@"locale"] = [NSLocale preferredLanguages].firstObject ?: @"en";

    NSString *firebaseProject = [PLServicesWrapper firebaseProjectId];
    if (firebaseProject.length) body[@"firebase_project_id"] = firebaseProject;
    body[@"push_token"] = pushToken;

    // Данные конверсии AF (сохраняются персистентно)
    NSDictionary *afData = [PLServicesWrapper storedAppsFlyerConversionData];
    if (afData.count) [body addEntriesFromDictionary:afData];

    NSError *jsonErr = nil;
    NSData  *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (!jsonData) { NSLog(@"[PreloadVC] FCM-send JSON error: %@", jsonErr); return; }

    NSURL *url = [NSURL URLWithString:[endpointURL stringByAppendingString:@"/config.php"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 10.0;
    req.HTTPBody = jsonData;

    // Ответ сервера не важен
    [[NSURLSession.sharedSession dataTaskWithRequest:req
                                  completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)r;
        NSLog(@"[PreloadVC] FCM-send: status=%ld error=%@", (long)http.statusCode, e);
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PreloadConfig
// ─────────────────────────────────────────────────────────────────────────────

@implementation PreloadConfig

- (instancetype)init
{
    self = [super init];
    if (self) {
        _appsflyerTimeout = 15.0;
        _endpointTimeout  = 10.0;
    }
    return self;
}

+ (instancetype)configWithAppsDevKey:(NSString *)devKey
                          appleAppId:(NSString *)appleId
                         endpointURL:(NSString *)endpoint
{
    PreloadConfig *c      = [PreloadConfig new];
    c.appsDevKey          = devKey;
    c.appleAppId          = appleId;
    c.endpointURL         = endpoint;
    return c;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PreloadViewController private interface
// ─────────────────────────────────────────────────────────────────────────────

@interface PreloadViewController ()

/// Фоновое изображение
@property (nonatomic, strong) UIImageView              *backgroundImageView;

/// Логотип приложения
@property (nonatomic, strong) UIImageView              *logoImageView;

/// Спиннер — крутится всё время загрузки
@property (nonatomic, strong) UIActivityIndicatorView  *spinner;

/// Собранные данные атрибуции для передачи на эндпоинт
@property (nonatomic, strong, nullable) NSDictionary *attributionData;
// Guard to avoid presenting the custom notification prompt multiple times within the same call
@property (atomic, assign) BOOL isPresentingNotificationPrompt;
// Флаг сессии: уведомления уже спрашивались в рамках текущего запуска приложения (in-memory, не персистируется)
@property (atomic, assign) BOOL notificationPromptShownThisSession;
// Prevent repeated endpoint refresh attempts during a single preload run
@property (atomic, assign) BOOL endpointRefreshAttempted;
/// Используется для отображения ошибки подключения без presentViewController
@property (nonatomic, strong) UIView *noInternetView;
/// Полупрозрачный тёмный оверлей за экраном «Нет интернета»
@property (nonatomic, strong) UIView *noInternetOverlay;

@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation PreloadViewController

// ── Lifecycle ──────────────────────────────────────────────────────────────────

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self pl_setupBackground];
    [self pl_setupLogoAndSpinner];
    [self pl_setupNoInternetView];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    _backgroundImageView.frame = self.view.bounds;
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self startChecks];
}

// ── Public ─────────────────────────────────────────────────────────────────────

- (void)startChecks
{
    self.attributionData = nil;
    self.noInternetView.hidden = YES;
    self.noInternetOverlay.hidden = YES;

    // ── Push-путь: приложение открыто тапом по уведомлению с URL ──────────────
    if (self.pendingPushURL) {
        NSURL *pushURL = self.pendingPushURL;
        self.pendingPushURL = nil; // Сбрасываем после обработки
        NSLog(@"[PreloadVC] Using push URL: %@", pushURL);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onOpenURL) self.onOpenURL(pushURL);
            [self->_spinner stopAnimating];
        });
        return;
    }

    // Убедимся, что цепочка запуска не выполняется при наличии URL из пуша
    NSLog(@"[PreloadVC] No pending push URL, proceeding with config chain");

    // ── Быстрый путь: режим запуска уже определён при предыдущем запуске ──
    NSString *savedMode = [[NSUserDefaults standardUserDefaults] stringForKey:@"PLLaunchMode"];

    if ([savedMode isEqualToString:@"unity"]) {
        NSLog(@"[PreloadVC] Saved launch mode: Unity — waiting briefly for pending push before launch");
        // Задержка 0.5с даёт iOS время доставить didReceiveNotificationResponse
        // до того как мы зафиксируем запуск Unity.
        // На старте через push didReceiveNotificationResponse приходит чуть позже viewDidAppear,
        // и без задержки unity fast path успевает вызвать onComplete раньше.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self.pendingPushURL) {
                // Push пришёл пока ждали — открываем WebView вместо Unity
                NSURL *pushURL = self.pendingPushURL;
                self.pendingPushURL = nil;
                NSLog(@"[PreloadVC] Push URL intercepted before Unity launch — switching to WebView: %@", pushURL);
                [[NSUserDefaults standardUserDefaults] setObject:@"webview" forKey:@"PLLaunchMode"];
                [[NSUserDefaults standardUserDefaults] synchronize];
                [self pl_checkAndAskNotificationsIfNeededWithCompletion:^{
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self->_spinner stopAnimating];
                        if (self.onOpenURL) self.onOpenURL(pushURL);
                    });
                }];
                return;
            }
            [self->_spinner stopAnimating];
            if (self.onComplete) self.onComplete();
        });
        return;
    }
    // webview или первый запуск — всегда пробуем получить свежий URL через полную цепочку.
    // Сохранённый URL используется только как fallback внутри цепочки при ошибках.
    if (savedMode) {
        NSLog(@"[PreloadVC] Saved launch mode: %@ — running full chain to get fresh URL", savedMode);
    }

    // Полная цепочка    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self pl_step1_checkNetwork];
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UI Setup
// ─────────────────────────────────────────────────────────────────────────────

- (void)pl_setupBackground
{
    _backgroundImageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"LaunchBackground"]];
    _backgroundImageView.frame = self.view.bounds;
    _backgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
    _backgroundImageView.clipsToBounds = YES;
    [self.view insertSubview:_backgroundImageView atIndex:0];
}

- (void)pl_setupLogoAndSpinner
{
    UIView *v = self.view;

    // Логотип
    _logoImageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AppLogo"]];
    _logoImageView.contentMode = UIViewContentModeScaleAspectFit;
    _logoImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_logoImageView];

    // Спиннер
    _spinner = [[UIActivityIndicatorView alloc]
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _spinner.color = [UIColor whiteColor];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_spinner];
    [_spinner startAnimating];

    // Desired width — 55 % of view width (high priority, can yield).
    NSLayoutConstraint *logoWidthDesired =
        [_logoImageView.widthAnchor constraintEqualToAnchor:v.widthAnchor multiplier:0.55];
    logoWidthDesired.priority = UILayoutPriorityDefaultHigh; // 750

    // Hard caps so the logo never overflows in landscape.
    NSLayoutConstraint *logoWidthMax =
        [_logoImageView.widthAnchor constraintLessThanOrEqualToAnchor:v.widthAnchor multiplier:0.55];
    NSLayoutConstraint *logoHeightMax =
        [_logoImageView.heightAnchor constraintLessThanOrEqualToAnchor:v.safeAreaLayoutGuide.heightAnchor
                                                             multiplier:0.40];

    [NSLayoutConstraint activateConstraints:@[
        // Логотип — центрирован относительно безопасной области
        [_logoImageView.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
        [_logoImageView.centerYAnchor constraintEqualToAnchor:v.safeAreaLayoutGuide.centerYAnchor constant:-44],
        logoWidthDesired,
        logoWidthMax,
        logoHeightMax,
        // 1 : 1 — картинка квадратная
        [_logoImageView.heightAnchor constraintEqualToAnchor:_logoImageView.widthAnchor],

        // Спиннер — ниже логотипа
        [_spinner.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
        [_spinner.topAnchor     constraintEqualToAnchor:_logoImageView.bottomAnchor constant:24],
    ]];
}

- (void)pl_setupNoInternetView
{
    // Полупрозрачный тёмный фон
    UIView *overlay = [[UIView alloc] init];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    overlay.hidden = YES;
    [self.view addSubview:overlay];

    [NSLayoutConstraint activateConstraints:@[
        [overlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [overlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.hidden = YES;
    [self.view addSubview:container];

    UIImageView *iconView = [[UIImageView alloc] init];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:52 weight:UIImageSymbolWeightLight];
        iconView.image = [UIImage systemImageNamed:@"wifi.slash" withConfiguration:cfg];
    }
    iconView.tintColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:iconView];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"No Internet Connection";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:20];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:titleLabel];

    UILabel *messageLabel = [[UILabel alloc] init];
    messageLabel.text = @"Please check your network settings\nand try again.";
    messageLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    messageLabel.font = [UIFont systemFontOfSize:15];
    messageLabel.textAlignment = NSTextAlignmentCenter;
    messageLabel.numberOfLines = 0;
    messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:messageLabel];

    [NSLayoutConstraint activateConstraints:@[
        [container.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [container.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [container.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:40],
        [container.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-40],

        [iconView.topAnchor constraintEqualToAnchor:container.topAnchor],
        [iconView.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [iconView.widthAnchor constraintEqualToConstant:56],
        [iconView.heightAnchor constraintEqualToConstant:56],

        [titleLabel.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:16],
        [titleLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [titleLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [messageLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10],
        [messageLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [messageLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [messageLabel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    self.noInternetOverlay = overlay;
    self.noInternetView = container;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Этапы загрузки
// ─────────────────────────────────────────────────────────────────────────────
//
//   ┌─ Step 1 ──── Проверка сети              (0.00 → 0.15)
//   ├─ Step 2 ──── Инициализация Firebase      (0.15 → 0.40)
//   ├─ Step 3 ──── AppsFlyerr init + GCD wait  (0.40 → 0.70)
//   └─ Step 4 ──── Запрос к эндпоинту          (0.70 → 1.00)
//                   → onComplete  (Unity)
//                   → onOpenURL   (WebView)
//

// ── Step 1 : Сеть ─────────────────────────────────────────────────────────────

- (void)pl_step1_checkNetwork
{

    NSString *pingTarget = self.config.endpointURL ?: @"https://apple.com";
    NSURL *pingURL = [NSURL URLWithString:pingTarget];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:pingURL
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                   timeoutInterval:5.0];
    req.HTTPMethod = @"HEAD";

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (e == nil) {            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [strongSelf pl_step2_initFirebase];
            });
            return;
        }

        NSLog(@"[PreloadVC] Network check to %@ failed: %@", pingTarget, e);

        // If the configured endpoint is down (or blocked by ATS), try a known reliable host
        // before showing the "No Internet" UI. This avoids false negatives when only the
        // endpoint is unreachable.
        if (![pingTarget.lowercaseString containsString:@"apple.com"]) {
            NSURL *fallbackURL = [NSURL URLWithString:@"https://apple.com"];
            NSMutableURLRequest *fallbackReq = [NSMutableURLRequest requestWithURL:fallbackURL
                                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                                   timeoutInterval:5.0];
            fallbackReq.HTTPMethod = @"HEAD";

            [[[NSURLSession sharedSession] dataTaskWithRequest:fallbackReq
                                            completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                if (e2 == nil) {
                    NSLog(@"[PreloadVC] Fallback network check OK (apple.com)");                    
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        [strongSelf2 pl_step2_initFirebase];
                    });
                } else {
                    NSLog(@"[PreloadVC] Fallback network check failed: %@", e2);
                    [strongSelf2 pl_showNoInternetRetry];
                }
            }] resume];
        } else {
            [strongSelf pl_showNoInternetRetry];
        }
    }] resume];
}

// ── Step 2 : Firebase ─────────────────────────────────────────────────────────

- (void)pl_step2_initFirebase
{
    // Инициализируем Firebase напрямую — уведомления спрашиваем позже, только при WebView
    [PLServicesWrapper configureFirebase:^(NSError *fbError) {
        if (fbError) {
            NSLog(@"[PreloadVC] Firebase warning (non-fatal): %@", fbError.localizedDescription);            
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self pl_step3_initAppsFlyer];
        });
        // Регистрируем наблюдатель после Firebase init — к этому моменту
        // FIRMessaging.delegate уже выставлен и токен может прийти в любой момент.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pl_registerPersistentFCMTokenObserver];
        });
    }];
}

/// Регистрирует глобальный наблюдатель PLFCMTokenDidUpdateNotification.
/// Вызывать один раз — наблюдатель хранится статически (s_fcmTokenObserver) и не удаляется.
- (void)pl_registerPersistentFCMTokenObserver
{
    NSString *endpoint = self.config.endpointURL;
    if (endpoint.length == 0) return;

    // Обновляем сохранённый URL (может измениться между запусками)
    s_fcmEndpointURL = [endpoint copy];

    if (s_fcmTokenObserver) return; // уже зарегистрирован

    s_fcmTokenObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:PLFCMTokenDidUpdateNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
            NSString *ep = s_fcmEndpointURL;
            if (!ep.length) return;
            NSLog(@"[PreloadVC] FCM token update — sending firebase fields to server");
            PL_sendFirebaseFields(ep);
        }];
}


// Показывает запрос уведомлений если:
//   1. Пользователь ещё не ответил на этот вопрос в ТЕКУЩЕЙ сессии (notificationPromptShownThisSession == NO)
//   2. Статус системы — NotDetermined или Denied (с учётом 3-дневного кулдауна)
// После завершения (в любую сторону) вызывает completion на главном потоке.
- (void)pl_checkAndAskNotificationsIfNeededWithCompletion:(void(^)(void))completion
{
    if (!completion) completion = ^{};

    // Если в эту сессию уже спрашивали — пропускаем
    if (self.notificationPromptShownThisSession) {
        NSLog(@"[PreloadVC] Notification prompt already shown this session — skipping");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
        return;
    }

    if (@available(iOS 10.0, *)) {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
            UNAuthorizationStatus currentStatus = settings.authorizationStatus;
            BOOL shouldRequest = NO;
            if (currentStatus == UNAuthorizationStatusNotDetermined ||
                currentStatus == UNAuthorizationStatusDenied) {
                NSDate *lastDenied = [[NSUserDefaults standardUserDefaults] objectForKey:@"PLLastNotificationDeniedAt"];
                if (!lastDenied) {
                    shouldRequest = YES;
                } else {
                    NSTimeInterval since = [[NSDate date] timeIntervalSinceDate:lastDenied];
                    shouldRequest = (since >= (3 * 24 * 60 * 60)); // 3 дня
                }
            }

            if (!shouldRequest) {
                // Системное разрешение уже есть или кулдаун не истёк — помечаем сессию и продолжаем
                self.notificationPromptShownThisSession = YES;
                dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.isPresentingNotificationPrompt) {
                    completion();
                    return;
                }
                self.isPresentingNotificationPrompt = YES;

                __weak typeof(self) weakSelf = self;
                NotificationPromptViewController *np = [[NotificationPromptViewController alloc]
                    initWithTitle:@"Enable Notifications"
                    message:@"Would you like to receive important notifications about the app?"
                    backgroundImage:nil
                    allowHandler:^{
                        __strong typeof(weakSelf) strongSelf = weakSelf;
                        if (!strongSelf) return;
                        strongSelf.notificationPromptShownThisSession = YES;
                        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"PLAskedForNotifications"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                        if (currentStatus == UNAuthorizationStatusDenied) {
                            // Системное разрешение отозвано — iOS не покажет диалог повторно.
                            // Открываем настройки приложения, чтобы пользователь мог включить их вручную.
                            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"PLLastNotificationDeniedAt"];
                            [[NSUserDefaults standardUserDefaults] synchronize];
                            strongSelf.isPresentingNotificationPrompt = NO;
                            NSURL *settingsURL = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
                            if (settingsURL && [[UIApplication sharedApplication] canOpenURL:settingsURL]) {
                                [[UIApplication sharedApplication] openURL:settingsURL
                                                                   options:@{}
                                                         completionHandler:^(BOOL success) {
                                    completion();
                                }];
                            } else {
                                completion();
                            }
                        } else {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                UNAuthorizationOptions opts = (UNAuthorizationOptionBadge | UNAuthorizationOptionSound | UNAuthorizationOptionAlert);
                                [center requestAuthorizationWithOptions:opts completionHandler:^(BOOL granted, NSError * _Nullable err) {
                                    if (!granted) {
                                        [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:@"PLLastNotificationDeniedAt"];
                                    } else {
                                        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"PLLastNotificationDeniedAt"];
                                    }
                                    [[NSUserDefaults standardUserDefaults] synchronize];
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        strongSelf.isPresentingNotificationPrompt = NO;
                                        completion();
                                    });
                                }];
                            });
                        }
                    }
                    cancelHandler:^{
                        __strong typeof(weakSelf) strongSelf = weakSelf;
                        if (!strongSelf) return;
                        strongSelf.notificationPromptShownThisSession = YES;
                        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"PLAskedForNotifications"];
                        [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:@"PLLastNotificationDeniedAt"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                        strongSelf.isPresentingNotificationPrompt = NO;
                        completion();
                    }];

                [self presentViewController:np animated:YES completion:nil];
            });
        }];
    } else {
        self.notificationPromptShownThisSession = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
    }
}

// ── Step 3 : AppsFlyer ───────────────────────────────────────────────────────

- (void)pl_step3_initAppsFlyer
{
    NSString *devKey   = self.config.appsDevKey ?: @"";
    NSString *appleId  = self.config.appleAppId ?: @"";
    NSTimeInterval tmo = self.config ? self.config.appsflyerTimeout : 15.0;

    // PLServicesWrapper — чистый ObjC, без проблем с C++ модулями
    [PLServicesWrapper startAppsFlyerWithDevKey:devKey
                                     appleAppId:appleId
                               gcdWaitTimeout:tmo
                                     completion:^(NSDictionary *attribution, NSError *error) {
        NSLog(@"[PreloadVC] AppsFlyer attribution: %@", attribution);
        self.attributionData = attribution;        

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self pl_step4_requestEndpoint:attribution];
        });
    }];
}

// ── Step 4 : Запрос к эндпоинту ───────────────────────────────────────────────

- (void)pl_step4_requestEndpoint:(nullable NSDictionary *)attribution
{
    NSString *baseURL = self.config.endpointURL;
    if (baseURL.length == 0) {
        NSLog(@"[PreloadVC] endpointURL is empty — proceeding to Unity");
        [self pl_finishWithURL:nil];
        return;
    }


    // ── Формируем тело запроса ────────────────────────────────────────────────
    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    // Данные устройства
    body[@"bundle_id"]   = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    body[@"app_version"] = [[[NSBundle mainBundle] infoDictionary]
                            objectForKey:@"CFBundleShortVersionString"] ?: @"";
    body[@"platform"]    = @"ios";
    body[@"idfa"]        = [self pl_idfaString];

    // af_id — AppsFlyer Device ID (обязателен во всех запросах)
    NSString *afId = [PLServicesWrapper appsFlyerDeviceId];
    if (afId.length) body[@"af_id"] = afId;

    body[@"locale"] = [NSLocale preferredLanguages].firstObject ?: @"en";

    // Данные атрибуции AppsFlyerr
    // Передаём данные конверсии AppsFlyer без изменений, если они есть.
    // Приоритет: сначала сохранённые в PLServicesWrapper (persisted), затем текущие attribution.
    NSDictionary *storedAF = [PLServicesWrapper storedAppsFlyerConversionData];
    NSDictionary *afData = (storedAF && [storedAF isKindOfClass:[NSDictionary class]] && storedAF.count)
        ? storedAF
        : ((attribution && [attribution isKindOfClass:[NSDictionary class]] && attribution.count) ? attribution : nil);
    if (afData) {
        [body addEntriesFromDictionary:afData];
    }

    // Дополнительные обязательные поля
    body[@"os"] = @"iOS";
    // store_id берём из конфига (apple App Store id)
    body[@"store_id"] = self.config.appleAppId ?: @"";

    // Firebase fields: project id и push token (всегда включаем, пустая строка если недоступен)
    NSString *firebaseProject = [PLServicesWrapper firebaseProjectId];
    if (firebaseProject && firebaseProject.length) {
        body[@"firebase_project_id"] = firebaseProject;
    }
    NSString *pushToken = [PLServicesWrapper firebasePushToken];
    body[@"push_token"] = pushToken ?: @"";

    // ── HTTP запрос ───────────────────────────────────────────────────────────
    NSURL *url = [NSURL URLWithString:[baseURL stringByAppendingString:@"/config.php"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSTimeInterval timeout = self.config ? self.config.endpointTimeout : 10.0;
    req.timeoutInterval = timeout;

    NSError *jsonErr = nil;
    NSData  *jsonData = [NSJSONSerialization dataWithJSONObject:body
                                                        options:0
                                                          error:&jsonErr];
    if (jsonErr || !jsonData) {
        NSLog(@"[PreloadVC] JSON serialization error: %@", jsonErr);
        [self pl_finishWithURL:nil];
        return;
    }
    req.HTTPBody = jsonData;

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest  = timeout;
    cfg.timeoutIntervalForResource = timeout + 5;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithRequest:req
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        if (error) {
            NSLog(@"[PreloadVC] Endpoint request error: %@", error);
            // Сетевая ошибка — показываем экран отсутствия интернета
            [self pl_showNoInternetRetry];
            return;
        }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSLog(@"[PreloadVC] Endpoint status: %ld", (long)http.statusCode);
        

        // ── Разбираем ответ ───────────────────────────────────────────────────
        NSURL *redirectURL = nil;

        if (data.length) {
            NSError *parseErr = nil;
            id json = [NSJSONSerialization JSONObjectWithData:data
                                                     options:0
                                                       error:&parseErr];
            if (!parseErr && [json isKindOfClass:[NSDictionary class]]) {
                NSDictionary *dict = (NSDictionary *)json;


                // Новый формат — при ok == true берём url
                id okFlag = dict[@"ok"];
                NSString *urlString = nil;
                if (okFlag) {
                    BOOL ok = NO;
                    if ([okFlag isKindOfClass:[NSNumber class]]) ok = [(NSNumber *)okFlag boolValue];
                    else if ([okFlag isKindOfClass:[NSString class]]) ok = [(NSString *)okFlag boolValue];

                    if (ok) {
                        urlString = dict[@"url"];
                        // логируем + сохраняем expires при наличии
                        id expires = dict[@"expires"];
                        if (expires) {
                            NSLog(@"[PreloadVC] Endpoint expires: %@", expires);
                            // Normalize expires into a unix timestamp (seconds since 1970)
                            double expiresTS = 0;
                            if ([expires isKindOfClass:[NSNumber class]]) {
                                expiresTS = [(NSNumber *)expires doubleValue];
                            } else if ([expires isKindOfClass:[NSString class]]) {
                                // Try ISO8601 first
                                if (@available(iOS 10.0, *)) {
                                    NSISO8601DateFormatter *fmt = [NSISO8601DateFormatter new];
                                    NSDate *d = [fmt dateFromString:(NSString *)expires];
                                    if (d) expiresTS = [d timeIntervalSince1970];
                                }
                                if (expiresTS == 0) {
                                    // Fallback: parse as number string
                                    expiresTS = [(NSString *)expires doubleValue];
                                }
                            }
                            if (expiresTS > 0) {
                                [[NSUserDefaults standardUserDefaults] setDouble:expiresTS forKey:@"PLLastEndpointExpires"];
                                [[NSUserDefaults standardUserDefaults] synchronize];
                                // Reset per-run refresh flag when we get a fresh expires value
                                self.endpointRefreshAttempted = NO;
                            }
                        }
                    }
                }

                if (urlString.length) {
                    redirectURL = [NSURL URLWithString:urlString];
                    // Persist last endpoint URL so WebView can reuse it on next launch
                    if (redirectURL) {
                        [[NSUserDefaults standardUserDefaults] setObject:redirectURL.absoluteString forKey:@"PLLastEndpointURLString"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                    }
                }
            } else {
                NSLog(@"[PreloadVC] Endpoint parse error: %@", parseErr);
            }
        }

        [self pl_finishWithURL:redirectURL];

    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Финал
// ─────────────────────────────────────────────────────────────────────────────

/// `url == nil`  → запускаем Unity (onComplete) — уведомления НЕ запрашиваем
/// `url != nil`  → показываем WebView (onOpenURL) — сначала запрашиваем уведомления (если не спрашивали в эту сессию)
- (void)pl_finishWithURL:(nullable NSURL *)url
{    

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // ── Push-приоритет: проверяем на главном потоке после небольшой задержки. ──
        // pl_finishWithURL: вызывается из фонового потока (URLSession completion), поэтому
        // проверять pendingPushURL там небезопасно — didReceiveNotificationResponse: устанавливает
        // его через dispatch_async(main_queue) и этот блок может ещё не выполниться.
        // Проверка здесь, на main queue через 0.3с, гарантирует что пуш уже обработан.
        if (self.pendingPushURL) {
            NSURL *pushURL = self.pendingPushURL;
            self.pendingPushURL = nil;
            NSLog(@"[PreloadVC] Push URL received during chain — overriding server URL with: %@", pushURL);
            // Сохраняем режим запуска
            if (![[NSUserDefaults standardUserDefaults] stringForKey:@"PLLaunchMode"]) {
                [[NSUserDefaults standardUserDefaults] setObject:@"webview" forKey:@"PLLaunchMode"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
            [self->_spinner stopAnimating];
            [self pl_checkAndAskNotificationsIfNeededWithCompletion:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.onOpenURL) self.onOpenURL(pushURL);
                });
            }];
            return;
        }

        [self->_spinner stopAnimating];

        // Для WebView-пути: если config.php не вернул URL — используем последний сохранённый
        NSURL *useURL = url;
        if (!useURL) {
            NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:@"PLLastEndpointURLString"];
            if (stored.length) {
                useURL = [NSURL URLWithString:stored];
            }
        }

        // ── Сохраняем режим запуска при первом определении ──
        NSString *savedMode = [[NSUserDefaults standardUserDefaults] stringForKey:@"PLLaunchMode"];
        if (!savedMode) {
            NSString *mode = useURL ? @"webview" : @"unity";
            [[NSUserDefaults standardUserDefaults] setObject:mode forKey:@"PLLaunchMode"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            NSLog(@"[PreloadVC] Launch mode saved: %@", mode);
        }

        if (useURL) {
            // ── WebView path: сначала спрашиваем разрешение на уведомления, затем открываем ──
            NSLog(@"[PreloadVC] WebView path — checking notification permission before opening URL");
            [self pl_checkAndAskNotificationsIfNeededWithCompletion:^{
                NSLog(@"[PreloadVC] → opening URL: %@", useURL);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.onOpenURL) {
                        self.onOpenURL(useURL);
                    } else {
                        [[UIApplication sharedApplication] openURL:useURL
                                                           options:@{}
                                                 completionHandler:nil];
                    }
                });
            }];
        } else {
            // ── Unity path: уведомления не запрашиваем ──
            NSLog(@"[PreloadVC] → proceeding to Unity (no notification prompt)");
            if (self.onComplete) self.onComplete();
        }
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers
// ─────────────────────────────────────────────────────────────────────────────

- (void)pl_showNoInternetRetry
{
    NSLog(@"[PreloadVC] No internet — showing no connection UI");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_spinner stopAnimating];
        self.noInternetOverlay.hidden = NO;
        self.noInternetView.hidden = NO;
    });
}

/// Возвращает IDFA если доступен, иначе пустую строку.
/// Для iOS 14+ требует ATTrackingManager (раскомментируйте import).
- (NSString *)pl_idfaString
{
    // Раскомментируйте если подключён ATTrackingManager:
    //
    // #import <AppTrackingTransparency/AppTrackingTransparency.h>
    // #import <AdSupport/AdSupport.h>
    // if (@available(iOS 14, *)) {
    //     if ([ATTrackingManager trackingAuthorizationStatus]
    //             == ATTrackingManagerAuthorizationStatusAuthorized) {
    //         return [[[ASIdentifierManager sharedManager] advertisingIdentifier]
    //                 UUIDString];
    //     }
    // }
    return @"";
}

// ── Status bar ────────────────────────────────────────────────────────────────
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

@end
