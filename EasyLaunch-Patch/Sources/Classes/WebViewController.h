#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Полноэкранный WKWebView контроллер без возможности dismissal.
/// Поддерживает: редиректы, back-gesture (edge pan), video autoplay,
/// ограниченное продолжение длинных HTTP-цепочек внутри WKWebView.
@interface WebViewController : UIViewController

- (instancetype)initWithURL:(NSURL *)url NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibName bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Вызывается при закрытии контроллера (напр., чтобы продолжить запуск Unity)
@property (nonatomic, copy, nullable) void (^onClose)(void);
/// App-owned, non-sensitive routing flags for the on-screen diagnostic report.
@property (nonatomic, copy, nullable) NSString *diagnosticContext;

/// Opens a new URL in the existing web view. Safe to call before viewDidLoad.
- (void)navigateToURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
