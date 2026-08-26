#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^NotificationPromptHandler)(void);

/// Полноэкранный кастомный экран запроса разрешения на уведомления.
/// Показывается перед системным диалогом UNUserNotificationCenter.
@interface NotificationPromptViewController : UIViewController

- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
              backgroundImage:(nullable UIImage *)image
                 allowHandler:(NotificationPromptHandler)allowHandler
                cancelHandler:(NotificationPromptHandler)cancelHandler NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithNibName:(NSString *)nibName bundle:(NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
