#import "CustomAppController.h"
#import "PreloadViewController.h"
#import "WebViewController.h"
#import "WebViewConfig.h"
#import "EasyLaunchConfig.h"
#import "ScreenCaptureBlocker.h"
#import "PLServicesWrapper.h"
#import <UserNotifications/UserNotifications.h>

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Private interface
// ─────────────────────────────────────────────────────────────────────────────

@interface CustomAppController () <UNUserNotificationCenterDelegate>

/// Временное окно с экраном загрузки
@property (nonatomic, strong, nullable) UIWindow *preloadWindow;

/// Сцена, полученная при первом вызове initUnityWithScene: — сохраняем для
/// передачи в super после завершения проверок
@property (nonatomic, weak, nullable) UIWindowScene *pendingScene;

/// Флаг: preload уже запущен и ждём завершения проверок
@property (nonatomic, assign) BOOL preloadInProgress;

/// После завершения EasyLaunch ограничивает ориентацию только для Unity-игры.
@property (nonatomic, assign) BOOL unityMode;

/// URL из push-уведомления, по которому открылось приложение
@property (nonatomic, strong, nullable) NSURL *pendingPushURL;

/// Monotonically increasing id of the last notification tap. It prevents an
/// older deferred UI transition from opening after a newer notification tap.
@property (nonatomic, assign) NSUInteger pushTapGeneration;
@property (nonatomic, strong, nullable) NSURL *coldStartPushURL;
@property (nonatomic, copy, nullable) NSString *coldStartMessageID;
@property (nonatomic, strong, nullable) NSURL *deferredOpenURL;
@property (nonatomic, assign) BOOL startingUnity;

- (void)pl_openURL:(NSURL *)url
        generation:(NSUInteger)generation
        retryCount:(NSUInteger)retryCount;

@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation CustomAppController

- (UIInterfaceOrientationMask)application:(UIApplication *)application
        supportedInterfaceOrientationsForWindow:(UIWindow *)window
{
    if (!self.unityMode)
        return UIInterfaceOrientationMaskAll;

    if ([EL_UNITY_ORIENTATION.lowercaseString isEqualToString:@"portrait"])
        return UIInterfaceOrientationMaskPortrait;

    return UIInterfaceOrientationMaskLandscape;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Push URL helper
// ─────────────────────────────────────────────────────────────────────────────

/// Извлекает URL из payload push-уведомления.
/// Ищет поле "url" в: корне payload → data словаре → aps словаре.
+ (nullable NSURL *)pl_pushURLFromUserInfo:(NSDictionary *)userInfo
{
    if (![userInfo isKindOfClass:NSDictionary.class]) return nil;

    // 1. Корень payload: userInfo["url"]
    NSString *urlStr = userInfo[@"url"];
    if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) {
        urlStr = userInfo[@"click_url"];
    }

    // 2. FCM data payload: userInfo["data"]["url"]
    if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) {
        NSDictionary *data = userInfo[@"data"];
        if ([data isKindOfClass:[NSDictionary class]]) {
            urlStr = data[@"url"];
            if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) {
                urlStr = data[@"click_url"];
            }
        }
    }

    // 3. APS словарь (нестандартное размещение): userInfo["aps"]["url"]
    if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) {
        NSDictionary *aps = userInfo[@"aps"];
        if ([aps isKindOfClass:[NSDictionary class]]) {
            urlStr = aps[@"url"];
            if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) {
                urlStr = aps[@"click_url"];
            }
        }
    }

    if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) return nil;

    NSURL *url = [NSURL URLWithString:urlStr];
    NSString *scheme = url.scheme.lowercaseString;
    if (!url.host.length || (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])) {
        NSLog(@"[CustomAppController] Ignoring invalid push URL: %@", urlStr);
        return nil;
    }
    return url;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - App lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // Извлекаем URL из cold-start push
    NSDictionary *remoteNotif = launchOptions[UIApplicationLaunchOptionsRemoteNotificationKey];
    if (remoteNotif) {
        self.pendingPushURL = [CustomAppController pl_pushURLFromUserInfo:remoteNotif];
        self.coldStartPushURL = self.pendingPushURL;
        id messageID = remoteNotif[@"gcm.message_id"] ?: remoteNotif[@"google.message_id"];
        self.coldStartMessageID = [messageID isKindOfClass:NSString.class] ? messageID : nil;
        NSURL *capturedColdURL = self.coldStartPushURL;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if ([self.coldStartPushURL.absoluteString isEqualToString:capturedColdURL.absoluteString]) {
                self.coldStartPushURL = nil;
                self.coldStartMessageID = nil;
            }
        });
        if (self.pendingPushURL) {
            NSLog(@"[CustomAppController] Cold-start push URL: %@", self.pendingPushURL);
            // Пуш открыл приложение — preload сам обработает pendingPushURL через showPreloadScreenForScene
        }
    }

    BOOL result = [super application:application didFinishLaunchingWithOptions:launchOptions];

    // Устанавливаем делегат ПОСЛЕ super — иначе Unity перезапишет его в своём
    // didFinishLaunchingWithOptions.
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;

    // The push fast path skips preload's SDK chain, but APNs callbacks still arrive.
    [PLServicesWrapper configureFirebase:nil];
    NSLog(@"[EasyLaunch] routing revision 2026-09-14-r1; build %@",
          [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]);
    NSLog(@"[EasyLaunch] source commit=%@ patch_sha256=%@",
          [NSBundle.mainBundle objectForInfoDictionaryKey:@"EasyLaunchSourceCommit"] ?: @"unknown",
          [NSBundle.mainBundle objectForInfoDictionaryKey:@"EasyLaunchPatchSHA256"] ?: @"unknown");

    // Защита от захвата экрана
    //[[ScreenCaptureBlocker sharedBlocker] startProtecting];

    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UNUserNotificationCenterDelegate
// ─────────────────────────────────────────────────────────────────────────────

/// Тап по уведомлению когда приложение в фоне или foreground.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler
{
    NSDictionary *userInfo = response.notification.request.content.userInfo;
    NSURL *pushURL = [CustomAppController pl_pushURLFromUserInfo:userInfo];

    if (pushURL && ![response.actionIdentifier isEqualToString:UNNotificationDismissActionIdentifier]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Deduplicate the same message, never two messages sharing a URL.
            id messageID = userInfo[@"gcm.message_id"] ?: userInfo[@"google.message_id"];
            if (self.coldStartMessageID && [messageID isKindOfClass:NSString.class] &&
                [self.coldStartMessageID isEqualToString:messageID]) {
                NSLog(@"[CustomAppController] Ignoring duplicate cold-start push response");
                self.coldStartPushURL = nil;
                self.coldStartMessageID = nil;
                return;
            }
            NSLog(@"[CustomAppController] Push tap URL: %@", pushURL);
            NSUInteger generation = ++self.pushTapGeneration;
            PreloadViewController *preloadVC =
                (PreloadViewController *)self.preloadWindow.rootViewController;

            if ([preloadVC isKindOfClass:[PreloadViewController class]]
                && !preloadVC.hasFinished) {
                // Preload-экран активен и ещё не открыл WebView:
                // передаём URL — startChecks или pl_finishWithURL его подхватят.
                // Покрывает cold start + случай когда launchOptions не содержал URL.
                preloadVC.pendingPushURL = pushURL;

            } else if (self.preloadInProgress && self.preloadWindow == nil) {
                // Preload запускается, но окно ещё не создано (очень ранний cold start):
                // сохраняем — showPreloadScreenForScene передаст в VC.
                self.pendingPushURL = pushURL;

            } else {
                // Приложение уже работает (Unity/WebView открыт) — открываем/заменяем сразу.
                [self pl_openURL:pushURL generation:generation retryCount:0];
            }
        });
    }

    completionHandler();
}

/// Показывает уведомление даже когда приложение на переднем плане
/// (пользователь видит баннер — решает тапать или нет).
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler
{
    if (@available(iOS 14.0, *)) {
        completionHandler(UNNotificationPresentationOptionBanner |
                          UNNotificationPresentationOptionSound);
    } else {
        completionHandler(UNNotificationPresentationOptionAlert |
                          UNNotificationPresentationOptionSound);
    }
}

/// Фоновое/foreground получение remote notification (data messages и notification messages).
/// Вызывается когда приложение запущено в фоне и получает push, а также при тапе
/// если приложение было в foreground.
- (void)application:(UIApplication *)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo
    fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
    NSLog(@"[CustomAppController] didReceiveRemoteNotification: %@", userInfo);
    // Тап по уведомлению обрабатывается через userNotificationCenter:didReceiveNotificationResponse:
    // Здесь обрабатываем только фоновые data-пуши (content-available)
#if UNITY_USES_REMOTE_NOTIFICATIONS
    [super application:application
        didReceiveRemoteNotification:userInfo
        fetchCompletionHandler:completionHandler];
#else
    // Unity omits this optional method entirely when its C# notification API
    // is unused. An unconditional super call then raises unrecognized selector.
    if (completionHandler) completionHandler(UIBackgroundFetchResultNoData);
#endif
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
    [PLServicesWrapper setAPNsDeviceToken:deviceToken];
#if UNITY_USES_REMOTE_NOTIFICATIONS
    [super application:application didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];
#endif
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{
    NSLog(@"[CustomAppController] APNs registration failed: %@", error);
#if UNITY_USES_REMOTE_NOTIFICATIONS
    [super application:application didFailToRegisterForRemoteNotificationsWithError:error];
#endif
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Open URL helper (app already running)
// ─────────────────────────────────────────────────────────────────────────────

- (void)pl_openURL:(NSURL *)url
        generation:(NSUInteger)generation
        retryCount:(NSUInteger)retryCount
{
    if (!url) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pl_openURL:url generation:generation retryCount:retryCount];
        });
        return;
    }

    // Only the most recently tapped notification is allowed to navigate.
    if (generation != self.pushTapGeneration) return;
    self.deferredOpenURL = url;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive || self.startingUnity) return;

    // Ищем topmost presented view controller и показываем WebView поверх.
    // Перебираем все windows чтобы найти активный ключевой — используем keyWindow.
    UIWindow *keyWin = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow) { keyWin = w; break; }
                }
                if (keyWin) break;
            }
        }
    }
    if (!keyWin) {
        keyWin = self.preloadWindow ?: self.window;
    }

    UIViewController *top = keyWin.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    if (!top || !top.view.window) {
        // Runtime notification responses can arrive while the scene is being
        // attached. Retry this exact response; never put it into the cold-start
        // pending slot, where it could be consumed by a later notification.
        if (retryCount < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self pl_openURL:url generation:generation retryCount:retryCount + 1];
            });
        } else {
            NSLog(@"[CustomAppController] Push UI did not become ready; URL not opened: %@", url);
        }
        return;
    }

    if (top.isBeingPresented || top.isBeingDismissed || top.transitionCoordinator) {
        id<UIViewControllerTransitionCoordinator> coordinator = top.transitionCoordinator;
        if (coordinator) {
            [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self pl_openURL:url generation:generation retryCount:retryCount + 1];
                });
            }];
        } else if (retryCount < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self pl_openURL:url generation:generation retryCount:retryCount + 1];
            });
        }
        return;
    }

    // Если WebViewController уже открыт — загружаем URL именно текущего tap.
    if ([top isKindOfClass:[WebViewController class]]) {
        // Reuse the existing controller for the URL from this response.
        NSLog(@"[CustomAppController] pl_openURL: navigating existing WebViewController");
        [(WebViewController *)top navigateToURL:url];
        self.deferredOpenURL = nil;
        return;
    }

    WebViewController *wvc = [[WebViewController alloc] initWithURL:url];
    wvc.modalPresentationStyle = UIModalPresentationFullScreen;
    if (@available(iOS 13.0, *)) {
        wvc.modalInPresentation = YES;
    }
    __weak typeof(self) weakSelf = self;
    wvc.onClose = ^{
        [weakSelf dismissPreloadAndStartUnity];
    };
    [top presentViewController:wvc animated:YES completion:nil];
    self.deferredOpenURL = nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Unity entry point
// ─────────────────────────────────────────────────────────────────────────────

/// Перехватываем точку входа Unity.
/// Если движок ещё не инициализировался — сначала показываем preload-экран,
/// а запуск Unity откладываем до завершения всех проверок.
/// Повторные вызовы (возврат из фона после инициализации) пробрасываем в super.
- (void)initUnityWithScene:(UIWindowScene *)scene
{
    // Если Unity уже инициализирован — обычное поведение (return внутри super)
    if (self.engineLoadState >= kUnityEngineLoadStateCoreInitialized)
    {
        [super initUnityWithScene:scene];
        return;
    }

    // Если preload уже запущен (повторный вызов пока идут проверки) — игнорируем
    if (self.preloadInProgress)
        return;

    self.preloadInProgress = YES;
    self.pendingScene = scene;

    [self showPreloadScreenForScene:scene];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preload window
// ─────────────────────────────────────────────────────────────────────────────

- (void)showPreloadScreenForScene:(UIWindowScene *)scene
{
    dispatch_async(dispatch_get_main_queue(), ^{
        // Создаём отдельное UIWindow поверх всего
        UIWindow *preloadWindow;
        if (scene != nil) {
            preloadWindow = [[UIWindow alloc] initWithWindowScene:scene];
        } else {
            preloadWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        }
        // Ensure UI outside presented controllers/webview is black
        preloadWindow.backgroundColor = [UIColor blackColor];
        // Уровень окна: выше стандартного, но ниже системных алертов
        preloadWindow.windowLevel = UIWindowLevelNormal + 10;

        PreloadViewController *vc = [[PreloadViewController alloc] init];

        PreloadConfig *cfg = [PreloadConfig configWithAppsDevKey:EL_APPSFLYER_DEV_KEY
                                                      appleAppId:EL_APPLE_APP_ID
                                                     endpointURL:EL_ENDPOINT_URL];
        vc.config = cfg;

        // Если приложение открыто через push с URL — передаём его напрямую
        if (self.pendingPushURL) {
            vc.pendingPushURL = self.pendingPushURL;
            self.pendingPushURL = nil;
        }

        // По завершении всех проверок — скрываем preload и запускаем Unity
        __weak typeof(self) weakSelf = self;
        vc.onComplete = ^{
            [weakSelf dismissPreloadAndStartUnity];
        };

        // Если сервер вернул URL — открыть во встроенном WebView
        vc.onOpenURL = ^(NSURL *url) {
            // Preload and runtime pushes share one serialized presentation path.
            [weakSelf pl_openURL:url generation:weakSelf.pushTapGeneration retryCount:0];
        };

        preloadWindow.rootViewController = vc;
        [preloadWindow makeKeyAndVisible];
        self.preloadWindow = preloadWindow;
    });
}

- (void)dismissPreloadAndStartUnity
{
    // Гарантируем выполнение на главном потоке
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.startingUnity || self.unityMode) return;
        self.startingUnity = YES;
        UIWindow *preloadWindow = self.preloadWindow;

        // Плавное исчезновение preload-экрана
        [UIView animateWithDuration:0.4
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            preloadWindow.alpha = 0.0;
        }
                         completion:^(BOOL finished) {
            preloadWindow.hidden = YES;
            self.preloadWindow = nil;
            self.preloadInProgress = NO;

            // EasyLaunch/WebView разрешают все ориентации. Ограничение включаем
            // непосредственно перед инициализацией Unity.
            self.unityMode = YES;

            UIInterfaceOrientationMask unityMask =
                [EL_UNITY_ORIENTATION.lowercaseString isEqualToString:@"portrait"]
                    ? UIInterfaceOrientationMaskPortrait
                    : UIInterfaceOrientationMaskLandscape;

            if (@available(iOS 16.0, *)) {
                UIWindowSceneGeometryPreferencesIOS *preferences =
                    [[UIWindowSceneGeometryPreferencesIOS alloc]
                        initWithInterfaceOrientations:unityMask];
                [self.pendingScene requestGeometryUpdateWithPreferences:preferences
                                                           errorHandler:^(NSError *error) {
                    NSLog(@"[CustomAppController] Unity orientation error: %@", error);
                }];
            } else {
                UIInterfaceOrientation orientation =
                    unityMask == UIInterfaceOrientationMaskPortrait
                        ? UIInterfaceOrientationPortrait
                        : UIInterfaceOrientationLandscapeRight;
                [[UIDevice currentDevice] setValue:@(orientation) forKey:@"orientation"];
                [UIViewController attemptRotationToDeviceOrientation];
            }

            // Теперь инициализируем Unity
            [super initUnityWithScene:self.pendingScene];
            self.startingUnity = NO;
            if (self.deferredOpenURL) {
                [self pl_openURL:self.deferredOpenURL generation:self.pushTapGeneration retryCount:0];
            }
        }];
    });
}

/// Переустанавливаем себя как делегат нотификаций после каждого выхода на передний план —
/// Firebase и Unity могут перезаписывать delegate во время работы приложения.
- (void)applicationDidBecomeActive:(UIApplication *)application
{
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    [super applicationDidBecomeActive:application];
    if (self.deferredOpenURL) {
        [self pl_openURL:self.deferredOpenURL generation:self.pushTapGeneration retryCount:0];
    }
}

// Unity's implementations call native runtime functions unconditionally.
// In the web-only path initUnityWithScene: intentionally has not run yet.
- (void)applicationDidEnterBackground:(UIApplication *)application
{
    if (self.engineLoadState >= kUnityEngineLoadStateAppReady)
        [super applicationDidEnterBackground:application];
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application
{
    if (self.engineLoadState >= kUnityEngineLoadStateAppReady)
        [super applicationDidReceiveMemoryWarning:application];
}

@end
