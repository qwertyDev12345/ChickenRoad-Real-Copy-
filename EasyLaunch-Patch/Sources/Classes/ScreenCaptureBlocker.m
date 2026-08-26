// ScreenCaptureBlocker.m
// ─────────────────────────────────────────────────────────────────────────────

#import "ScreenCaptureBlocker.h"
#import <objc/runtime.h>

// Длительность авто-закрытия оверлея после скриншота (секунды)
static const NSTimeInterval kSCB_ScreenshotOverlayDuration = 3.0;

// Длительность анимации появления / исчезновения оверлея
static const NSTimeInterval kSCB_AnimationDuration = 0.25;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - BlockerViewController (private)
// ─────────────────────────────────────────────────────────────────────────────

/// Простой контроллер внутри блокирующего UIWindow.
/// Скрывает строку состояния и поддерживает все ориентации хост-приложения.
@interface _SCBBlockerViewController : UIViewController
@end

@implementation _SCBBlockerViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
}

- (BOOL)prefersStatusBarHidden { return YES; }

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskAll;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ScreenCaptureBlocker
// ─────────────────────────────────────────────────────────────────────────────

@interface ScreenCaptureBlocker ()

/// Блокирующее окно поверх всего приложения.
@property (nonatomic, strong, nullable) UIWindow *blockerWindow;

/// Таймер авто-скрытия после скриншота.
@property (nonatomic, strong, nullable) NSTimer  *dismissTimer;

/// Флаг: защита активна.
@property (nonatomic, assign) BOOL isProtecting;

/// Флаг: оверлей виден прямо сейчас.
@property (nonatomic, assign) BOOL overlayVisible;

/// Флаг: оверлей показан из-за активной записи экрана.
@property (nonatomic, assign) BOOL shownForRecording;

@end

@implementation ScreenCaptureBlocker

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CALayer protection (статический метод, можно вызывать без синглтона)
// ─────────────────────────────────────────────────────────────────────────────

+ (BOOL)applyProtectionToLayer:(CALayer *)layer
{
    if (!layer) return NO;

    // ── 1. Ищем видимое окно для временного размещения UITextField ───────────
    UIWindow *hostWindow = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (![ws isKindOfClass:[UIWindowScene class]]) continue;
            if (ws.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ws.windows) {
                if (!w.isHidden) { hostWindow = w; break; }
            }
            if (hostWindow) break;
        }
    }

    if (!hostWindow) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (!w.isHidden) { hostWindow = w; break; }
        }
#pragma clang diagnostic pop
    }

    if (!hostWindow) {
        NSLog(@"[ScreenCaptureBlocker] applyProtection: no visible window found.");
        return NO;
    }

    // ── 2. Создаём UITextField за пределами экрана ────────────────────────────
    // Размещаем вне видимой области, чтобы не мелькал на экране.
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(-100, -100, 1, 1)];
    textField.secureTextEntry = NO; // сначала выключено — LayoutCanvasView ещё нет
    [hostWindow addSubview:textField];

    // ── 3. Включаем secureTextEntry — UIKit создаёт внутренний LayoutCanvasView ─
    textField.secureTextEntry = YES;

    // ── 4. Ищем LayoutCanvasView среди subviews текстового поля ──────────────
    UIView *canvasView = nil;
    for (UIView *sub in textField.subviews) {
        if ([NSStringFromClass([sub class]) containsString:@"LayoutCanvasView"]) {
            canvasView = sub;
            break;
        }
    }

    if (!canvasView) {
        [textField removeFromSuperview];
        NSLog(@"[ScreenCaptureBlocker] applyProtection: LayoutCanvasView not found "
              "(iOS version may not support this technique).");
        return NO;
    }

    // ── 5. Подменяем layer LayoutCanvasView на защищаемый layer ──────────────
    // iOS помечает layer атрибутом disableUpdateMask при переключении
    // secureTextEntry — именно это исключает содержимое из системного захвата.
    //
    // Проверяем KVC-совместимость через ivar / accessor. UIView объявляет
    // 'layer' как readonly-свойство, но в приватных подклассах он часто доступен
    // на запись через KVC. Используем Ivar-поиск как безопасную fallback-проверку.
    BOOL layerIsWritable = NO;
    {
        // Ищем ivar с именем "_layer" или "layer" вверх по иерархии классов
        Class cls = [canvasView class];
        while (cls && cls != [NSObject class]) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            for (unsigned int i = 0; i < count; i++) {
                const char *ivarName = ivar_getName(ivars[i]);
                if (ivarName && (strcmp(ivarName, "_layer") == 0 ||
                                 strcmp(ivarName, "layer") == 0)) {
                    layerIsWritable = YES;
                }
            }
            if (ivars) free(ivars);
            if (layerIsWritable) break;
            cls = [cls superclass];
        }

        // UIView хранит layer через CALayer *_layer ivar; если нашли — доступен
        // через KVC без исключения NSUndefinedKeyException.
        // Дополнительная проверка: UIView всегда KVC-compliant для ключа "layer"
        if (!layerIsWritable) {
            layerIsWritable = [canvasView respondsToSelector:@selector(layer)];
        }
    }

    if (!layerIsWritable) {
        [textField removeFromSuperview];
        NSLog(@"[ScreenCaptureBlocker] applyProtection: layer ivar not found — skipping.");
        return NO;
    }

    // KVC-запись безопасна: 'layer' — объявленное свойство UIView / CALayer-хост.
    CALayer *originalLayer = [canvasView valueForKey:@"layer"];

    // Подставляем защищаемый layer
    [canvasView setValue:layer forKey:@"layer"];

    // ── 6. Переключаем secureTextEntry — UIKit применяет disableUpdateMask ───
    textField.secureTextEntry = NO;
    textField.secureTextEntry = YES;

    // ── 7. Возвращаем оригинальный layer ─────────────────────────────────────
    [canvasView setValue:originalLayer forKey:@"layer"];

    BOOL success = YES;
    NSLog(@"[ScreenCaptureBlocker] applyProtection: protection applied to %@", layer);

    // ── 8. Убираем временный TextField ───────────────────────────────────────
    [textField removeFromSuperview];
    return success;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Singleton
// ─────────────────────────────────────────────────────────────────────────────

+ (instancetype)sharedBlocker
{
    static ScreenCaptureBlocker *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    return self;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Public API
// ─────────────────────────────────────────────────────────────────────────────

- (void)startProtecting
{
    if (self.isProtecting) return;
    self.isProtecting = YES;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    // Скриншот (iOS 7+)
    [nc addObserver:self
           selector:@selector(pl_screenshotTaken)
               name:UIApplicationUserDidTakeScreenshotNotification
             object:nil];

    // Запись экрана / AirPlay Mirror / QuickTime (iOS 11+)
    if (@available(iOS 11.0, *)) {
        [nc addObserver:self
               selector:@selector(pl_capturedStateDidChange)
                   name:UIScreenCapturedDidChangeNotification
                 object:nil];

        // Проверяем текущее состояние немедленно — вдруг уже идёт запись
        if (UIScreen.mainScreen.isCaptured) {
            [self pl_showOverlayForRecording];
        }
    }

    NSLog(@"[ScreenCaptureBlocker] Protection started.");
}

- (void)stopProtecting
{
    if (!self.isProtecting) return;
    self.isProtecting = NO;

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self pl_dismissOverlayAnimated:NO];

    NSLog(@"[ScreenCaptureBlocker] Protection stopped.");
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Notification handlers
// ─────────────────────────────────────────────────────────────────────────────

- (void)pl_screenshotTaken
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[ScreenCaptureBlocker] Screenshot detected.");
        [self pl_showOverlayForScreenshot];
    });
}

- (void)pl_capturedStateDidChange
{
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL capturing = NO;
        if (@available(iOS 11.0, *)) {
            capturing = UIScreen.mainScreen.isCaptured;
        }
        if (capturing) {
            NSLog(@"[ScreenCaptureBlocker] Screen recording started.");
            [self pl_showOverlayForRecording];
        } else {
            NSLog(@"[ScreenCaptureBlocker] Screen recording stopped.");
            // Убираем только если оверлей был показан именно из-за записи
            if (self.shownForRecording) {
                [self pl_dismissOverlayAnimated:YES];
            }
        }
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Overlay control
// ─────────────────────────────────────────────────────────────────────────────

/// Показывает оверлей из-за скриншота — исчезает автоматически через 3 секунды.
- (void)pl_showOverlayForScreenshot
{
    [self.dismissTimer invalidate];
    self.dismissTimer = nil;
    self.shownForRecording = NO;

    [self pl_presentOverlay];

    self.dismissTimer = [NSTimer scheduledTimerWithTimeInterval:kSCB_ScreenshotOverlayDuration
                                                         target:self
                                                       selector:@selector(pl_timerFired)
                                                       userInfo:nil
                                                        repeats:NO];
}

/// Показывает постоянный оверлей пока идёт запись экрана.
- (void)pl_showOverlayForRecording
{
    [self.dismissTimer invalidate];
    self.dismissTimer = nil;
    self.shownForRecording = YES;

    [self pl_presentOverlay];
}

- (void)pl_timerFired
{
    self.dismissTimer = nil;
    // Если к этому моменту запись уже идёт — не убираем оверлей
    BOOL capturedNow = NO;
    if (@available(iOS 11.0, *)) {
        capturedNow = UIScreen.mainScreen.isCaptured;
    }
    if (!capturedNow) {
        [self pl_dismissOverlayAnimated:YES];
    } else {
        // Переключаемся в режим «постоянного» оверлея для записи
        [self pl_showOverlayForRecording];
    }
}

- (void)pl_presentOverlay
{
    UIWindow *window = [self pl_blockerWindow];

    if (!self.overlayVisible) {
        // Начинаем с прозрачного для fade-in
        window.alpha  = 0.0;
        window.hidden = NO;
        [window makeKeyAndVisible];

        [UIView animateWithDuration:kSCB_AnimationDuration animations:^{
            window.alpha = 1.0;
        }];
        self.overlayVisible = YES;
    }
    // Если окно уже видно — просто обновляем текст/иконку (уже сделано выше)
}

- (void)pl_dismissOverlayAnimated:(BOOL)animated
{
    if (!self.overlayVisible) return;
    self.overlayVisible    = NO;
    self.shownForRecording = NO;

    [self.dismissTimer invalidate];
    self.dismissTimer = nil;

    UIWindow *window = self.blockerWindow;
    if (!window) return;

    if (animated) {
        [UIView animateWithDuration:kSCB_AnimationDuration
                         animations:^{ window.alpha = 0.0; }
                         completion:^(BOOL finished) {
            window.hidden = YES;
            window.alpha  = 1.0;
            // Вернуть фокус предыдущему ключевому окну
            [self pl_restoreKeyWindow];
        }];
    } else {
        window.hidden = YES;
        [self pl_restoreKeyWindow];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Window / ViewController helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Возвращает (при необходимости создаёт) блокирующее UIWindow.
- (UIWindow *)pl_blockerWindow
{
    if (self.blockerWindow) return self.blockerWindow;

    UIWindow *window = nil;

    if (@available(iOS 13.0, *)) {
        // Ищем активную foreground-сцену
        UIWindowScene *targetScene = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                targetScene = (UIWindowScene *)scene;
                break;
            }
        }
        if (targetScene) {
            window = [[UIWindow alloc] initWithWindowScene:targetScene];
        }
    }

    if (!window) {
        window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    }

    // Отображаем строго поверх системных алертов
    window.windowLevel           = UIWindowLevelAlert + 100.0;
    window.backgroundColor       = [UIColor blackColor];
    window.rootViewController    = [_SCBBlockerViewController new];

    self.blockerWindow = window;
    return window;
}

/// Удобный доступ к rootViewController блокирующего окна.
- (_SCBBlockerViewController *)pl_blockerViewController
{
    return (_SCBBlockerViewController *)[self pl_blockerWindow].rootViewController;
}

/// После скрытия блокирующего окна возвращает ключевое окно приложению.
- (void)pl_restoreKeyWindow
{
    if (@available(iOS 15.0, *)) {
        // Находим подходящее окно приложения и делаем его ключевым
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (![ws isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ws.windows) {
                if (!w.isHidden && w != self.blockerWindow) {
                    [w makeKeyWindow];
                    return;
                }
            }
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (!w.isHidden && w != self.blockerWindow) {
                [w makeKeyWindow];
                return;
            }
        }
#pragma clang diagnostic pop
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.dismissTimer invalidate];
}

@end
