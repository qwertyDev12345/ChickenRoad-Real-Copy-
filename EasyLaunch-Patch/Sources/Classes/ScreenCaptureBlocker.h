// ScreenCaptureBlocker.h
// ─────────────────────────────────────────────────────────────────────────────
// Независимый синглтон-защитник от захвата экрана.
//
// Возможности:
//  • Обнаружение скриншота (UIApplicationUserDidTakeScreenshotNotification)
//    → показывает полноэкранный блокирующий оверлей на 3 секунды.
//  • Обнаружение записи экрана / AirPlay / QuickTime Mirror
//    (UIScreenCapturedDidChangeNotification, iOS 11+)
//    → показывает постоянный оверлей пока захват активен.
//
// Использование:
//   [[ScreenCaptureBlocker sharedBlocker] startProtecting];
//   // …при необходимости:
//   [[ScreenCaptureBlocker sharedBlocker] stopProtecting];
// ─────────────────────────────────────────────────────────────────────────────

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScreenCaptureBlocker : NSObject

/// Единственный экземпляр.
+ (instancetype)sharedBlocker;

/// Начать наблюдение за захватом экрана. Безопасно вызывать повторно.
- (void)startProtecting;

/// Остановить наблюдение и убрать оверлей, если он был активен.
- (void)stopProtecting;

/// Защищает слой от попадания в скриншоты и записи экрана на уровне рендерера.
/// Реализует технику CALayer-swap через внутренний LayoutCanvasView UITextField:
/// iOS проставляет disableUpdateMask на layer, исключая его из системного захвата.
///
/// ВАЖНО: view должна быть в иерархии окна в момент вызова (viewDidAppear: и позже).
///
/// @param layer CALayer представления, которое нужно защитить.
/// @return YES если защита успешно применена, NO — если LayoutCanvasView не найден.
+ (BOOL)applyProtectionToLayer:(CALayer *)layer;

@end

NS_ASSUME_NONNULL_END
