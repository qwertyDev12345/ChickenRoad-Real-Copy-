#import "CustomAppController.h"
#import "PreloadViewController.h"
#import "NotificationPromptViewController.h"
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
@property (nonatomic, strong, nullable) NSURL *diagnosticLastPushURL;
@property (nonatomic, copy) NSString *deferredDiagnosticContext;
@property (nonatomic, copy) NSString *diagnosticPushEntry;
@property (nonatomic, copy) NSString *diagnosticPushField;
@property (nonatomic, assign) BOOL startingUnity;
@property (nonatomic, assign) NSUInteger openRequestGeneration;
@property (nonatomic, assign) NSUInteger openRetryCount;
@property (nonatomic, assign) BOOL openAttemptScheduled;
@property (nonatomic, assign) BOOL observingPresentationReadiness;
@property (nonatomic, weak) WebViewController *openingWebView;
@property (nonatomic, assign) NSUInteger openingWebViewRequest;

- (void)pl_openURL:(NSURL *)url
        generation:(NSUInteger)generation;
- (void)pl_scheduleOpenAttemptAfter:(NSTimeInterval)delay;
- (void)pl_drainPendingOpen;
- (void)pl_presentationMayBeReady:(nullable NSNotification *)notification;
+ (nullable NSURL *)pl_pushURLFromUserInfo:(NSDictionary *)userInfo selectedField:(NSString * _Nullable * _Nullable)selectedField;

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

/// Match the tested Flutter payload contract: url is the destination.
/// Keep click_url only as a fallback for older senders with no valid url.
+ (nullable NSURL *)pl_pushURLFromUserInfo:(NSDictionary *)userInfo
{
    return [self pl_pushURLFromUserInfo:userInfo selectedField:NULL];
}

+ (nullable NSURL *)pl_pushURLFromUserInfo:(NSDictionary *)userInfo selectedField:(NSString * _Nullable * _Nullable)selectedField
{
    if (selectedField) *selectedField = nil;
    if (![userInfo isKindOfClass:NSDictionary.class]) return nil;
    NSArray *containers = @[userInfo, userInfo[@"data"] ?: NSNull.null,
                            userInfo[@"aps"] ?: NSNull.null];
    NSArray *names = @[@"root", @"data", @"aps"];
    for (NSString *key in @[@"url", @"click_url"]) {
        for (NSUInteger index = 0; index < containers.count; index++) {
            id container = containers[index];
            if (![container isKindOfClass:NSDictionary.class]) continue;
            id value = [(NSDictionary *)container objectForKey:key];
            if (![value isKindOfClass:NSString.class]) continue;
            NSString *text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!text.length) continue;
            NSURL *url = [NSURL URLWithString:text];
            NSString *scheme = url.scheme.lowercaseString;
            if (url.host.length && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
                if (selectedField) *selectedField = [NSString stringWithFormat:@"%@.%@", names[index], key];
                return url;
            }
            // A malformed candidate must not hide another valid field.
        }
    }
    return nil;
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
        NSString *field = nil;
        self.pendingPushURL = [CustomAppController pl_pushURLFromUserInfo:remoteNotif selectedField:&field];
        self.diagnosticPushField = field;
        self.coldStartPushURL = self.pendingPushURL;
        self.diagnosticLastPushURL = self.pendingPushURL;
        self.diagnosticPushEntry = @"launchOptions";
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
    NSLog(@"[EasyLaunch] routing revision 2026-09-18-r7-flutter-navigation-ui; build %@",
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
    NSString *field = nil;
    NSURL *pushURL = [CustomAppController pl_pushURLFromUserInfo:userInfo selectedField:&field];

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
            self.diagnosticLastPushURL = pushURL;
            self.diagnosticPushField = field;
            self.diagnosticPushEntry = self.preloadWindow == nil && self.engineLoadState < kUnityEngineLoadStateCoreInitialized ?
                @"response before preload window" : @"notification response with existing window/engine";
            PreloadViewController *preloadVC =
                (PreloadViewController *)self.preloadWindow.rootViewController;

            if ([preloadVC isKindOfClass:[PreloadViewController class]]
                && !preloadVC.hasFinished) {
                preloadVC.routingGeneration = generation;
                [preloadVC acceptPushURL:pushURL];

            } else if (!self.unityMode && !self.startingUnity && self.preloadWindow == nil &&
                       self.engineLoadState < kUnityEngineLoadStateCoreInitialized) {
                // Includes the response BEFORE initUnityWithScene sets preloadInProgress.
                // Never queue an independent runtime open alongside a future config run.
                self.pendingPushURL = pushURL;

            } else {
                // Приложение уже работает (Unity/WebView открыт) — открываем/заменяем сразу.
                [self pl_openURL:pushURL generation:generation];
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
{
    if (!url) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pl_openURL:url generation:generation];
        });
        return;
    }

    // Only the most recently tapped notification is allowed to navigate.
    if (generation != self.pushTapGeneration) return;
    self.deferredOpenURL = url;
    self.deferredDiagnosticContext = [NSString stringWithFormat:@"tap=%lu; equals last push=%@; field=%@; entry=%@; engine=%ld; preload=%@; Unity starting=%@",
        (unsigned long)generation, [url isEqual:self.diagnosticLastPushURL] ? @"yes" : @"no/unknown",
        self.diagnosticPushField ?: @"none",
        self.diagnosticPushEntry ?: @"no push observed", (long)self.engineLoadState,
        self.preloadInProgress ? @"yes" : @"no", self.startingUnity ? @"yes" : @"no"];
    self.openRequestGeneration++;
    self.openRetryCount = 0;
    if (!self.observingPresentationReadiness) {
        self.observingPresentationReadiness = YES;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(pl_presentationMayBeReady:)
                       name:UIApplicationDidBecomeActiveNotification object:nil];
        [center addObserver:self selector:@selector(pl_presentationMayBeReady:)
                       name:UIWindowDidBecomeVisibleNotification object:nil];
        if (@available(iOS 13.0, *)) {
            [center addObserver:self selector:@selector(pl_presentationMayBeReady:)
                           name:UISceneDidActivateNotification object:nil];
        }
    }
    // Permission completion and scene callbacks can precede UIKit readiness.
    // All retries drain the CURRENT queue; none capture an obsolete push URL.
    [self pl_scheduleOpenAttemptAfter:0];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)pl_isApplicationActive
{
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

- (UIWindow *)pl_presentationWindow
{
    // Our higher-level preload window owns the web flow even if a system/Unity
    // window temporarily becomes key during permission dismissal.
    return self.preloadWindow ?: self.window;
}

- (void)pl_presentationMayBeReady:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([notification.name isEqualToString:UIWindowDidBecomeVisibleNotification] &&
            notification.object != [self pl_presentationWindow]) return;
        if (!self.deferredOpenURL) return;
        self.openRetryCount = 0;
        [self pl_scheduleOpenAttemptAfter:0];
    });
}

- (void)pl_scheduleOpenAttemptAfter:(NSTimeInterval)delay
{
    if (!self.deferredOpenURL || self.openAttemptScheduled) return;
    self.openAttemptScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.openAttemptScheduled = NO;
        [strongSelf pl_drainPendingOpen];
    });
}

- (void)pl_waitForPresentation:(NSString *)reason
{
    if (self.openRetryCount == 0)
        NSLog(@"[EasyLaunch] WebView opening deferred: %@", reason);
    if (self.openRetryCount++ < 100) {
        [self pl_scheduleOpenAttemptAfter:0.1];
    } else if (self.openRetryCount == 101) {
        // Keep the URL for a later activation/window event (e.g. Settings).
        NSLog(@"[EasyLaunch] WebView still waiting: %@; destination retained", reason);
    }
}

- (void)pl_drainPendingOpen
{
    NSURL *url = self.deferredOpenURL;
    if (!url) return;
    if (![self pl_isApplicationActive] || self.startingUnity) {
        [self pl_waitForPresentation:@"application inactive or Unity starting"];
        return;
    }
    UIWindow *keyWin = [self pl_presentationWindow];
    if (!keyWin || keyWin.hidden || keyWin.alpha <= 0) {
        [self pl_waitForPresentation:@"owner window not visible"];
        return;
    }
    if (@available(iOS 13.0, *)) {
        if (keyWin.windowScene &&
            keyWin.windowScene.activationState != UISceneActivationStateForegroundActive) {
            [self pl_waitForPresentation:@"owner scene inactive"];
            return;
        }
    }

    UIViewController *top = keyWin.rootViewController;
    WebViewController *existingWebView = nil;
    if ([top isKindOfClass:WebViewController.class]) existingWebView = (WebViewController *)top;
    while (top.presentedViewController) {
        top = top.presentedViewController;
        if ([top isKindOfClass:WebViewController.class]) existingWebView = (WebViewController *)top;
    }
    if (existingWebView && top != existingWebView) {
        // A camera/file picker or another native modal belongs to the current
        // document. Never cover it with a second WebView or replace its page
        // before its completion has returned the selected file. Picking can
        // take longer than the normal transition retry budget; wait at a low
        // rate while foregrounded. Background retries remain bounded above.
        if (self.openRetryCount == 0)
            NSLog(@"[EasyLaunch] Push navigation waiting for WebView modal to close");
        self.openRetryCount++;
        [self pl_scheduleOpenAttemptAfter:0.5];
        return;
    }
    if (!top || top.viewIfLoaded.window != keyWin) {
        [self pl_waitForPresentation:@"presenter not attached to owner window"];
        return;
    }

    if (top.isBeingPresented || top.isBeingDismissed || top.transitionCoordinator ||
        [top isKindOfClass:NotificationPromptViewController.class]) {
        // Do not rely solely on a transition completion: UIKit can decline
        // registration, leaving a one-shot preload completion stranded.
        [self pl_waitForPresentation:@"permission UI or controller transition"];
        return;
    }

    // Если WebViewController уже открыт — загружаем URL именно текущего tap.
    if ([top isKindOfClass:[WebViewController class]]) {
        ((WebViewController *)top).diagnosticContext = self.deferredDiagnosticContext;
        // Reuse the existing controller for the URL from this response.
        NSLog(@"[CustomAppController] pl_openURL: navigating existing WebViewController");
        if (top != self.openingWebView || self.openingWebViewRequest != self.openRequestGeneration)
            [(WebViewController *)top navigateToURL:url];
        self.deferredOpenURL = nil;
        self.openingWebView = nil;
        self.openRetryCount = 0;
        NSLog(@"[EasyLaunch] WebView destination delivered in owner window");
        return;
    }

    WebViewController *wvc = [[WebViewController alloc] initWithURL:url];
    wvc.diagnosticContext = self.deferredDiagnosticContext;
    wvc.modalPresentationStyle = UIModalPresentationFullScreen;
    if (@available(iOS 13.0, *)) {
        wvc.modalInPresentation = YES;
    }
    __weak typeof(self) weakSelf = self;
    wvc.onClose = ^{
        [weakSelf dismissPreloadAndStartUnity];
    };
    self.openingWebView = wvc;
    self.openingWebViewRequest = self.openRequestGeneration;
    [top presentViewController:wvc animated:YES completion:^{
        [weakSelf pl_scheduleOpenAttemptAfter:0];
    }];
    // UIKit can reject presentation without invoking completion. Retain the
    // destination until a visible WebView confirms it; retry independently.
    [self pl_waitForPresentation:@"waiting for visible WebView"];
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
        vc.routingGeneration = self.pushTapGeneration;

        // Если приложение открыто через push с URL — передаём его напрямую
        if (self.pendingPushURL) {
            vc.pendingPushURL = self.pendingPushURL;
            self.pendingPushURL = nil;
        }

        // По завершении всех проверок — скрываем preload и запускаем Unity
        __weak typeof(self) weakSelf = self;
        __weak PreloadViewController *weakPreload = vc;
        vc.onComplete = ^{
            __strong typeof(weakSelf) app = weakSelf;
            PreloadViewController *preload = weakPreload;
            if (!app || !preload || app.preloadWindow.rootViewController != preload ||
                preload.routingGeneration != app.pushTapGeneration) return;
            [app dismissPreloadAndStartUnity];
        };

        // Если сервер вернул URL — открыть во встроенном WebView
        vc.onOpenURL = ^(NSURL *url) {
            __strong typeof(weakSelf) app = weakSelf;
            PreloadViewController *preload = weakPreload;
            if (!app || !preload || app.preloadWindow.rootViewController != preload) return;
            // Never relabel an old startup callback with the CURRENT push token.
            [app pl_openURL:url generation:preload.routingGeneration];
        };

        preloadWindow.rootViewController = vc;
        self.preloadWindow = preloadWindow;
        [preloadWindow makeKeyAndVisible];
    });
}

- (void)dismissPreloadAndStartUnity
{
    NSUInteger generation = self.pushTapGeneration;
    // Гарантируем выполнение на главном потоке
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self.pushTapGeneration || self.startingUnity || self.unityMode) return;
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
            if (generation != self.pushTapGeneration) {
                // A push arrived during the fade. Keep the web-owning window alive.
                preloadWindow.alpha = 1.0;
                self.startingUnity = NO;
                [self pl_presentationMayBeReady:nil];
                return;
            }
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
            [self pl_presentationMayBeReady:nil];
        }];
    });
}

/// Переустанавливаем себя как делегат нотификаций после каждого выхода на передний план —
/// Firebase и Unity могут перезаписывать delegate во время работы приложения.
- (void)applicationDidBecomeActive:(UIApplication *)application
{
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    [super applicationDidBecomeActive:application];
    [self pl_presentationMayBeReady:nil];
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
