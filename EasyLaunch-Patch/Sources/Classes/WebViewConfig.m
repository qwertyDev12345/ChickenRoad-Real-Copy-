#import "WebViewConfig.h"

BOOL const WebViewConfigShowCloseButton = YES;
// Foundation's standard URLRequest timeout, matching the browser request defaults.
NSTimeInterval const WebViewConfigNavigationTimeout = 60.0;

UIColor *WebViewConfigTintColor(void)
{
    return [UIColor colorWithRed:0.12 green:0.48 blue:0.96 alpha:1.0];
}
