#import "WebViewController.h"
#import "WebViewConfig.h"
#import "ScreenCaptureBlocker.h"
#import <WebKit/WebKit.h>

@interface WebViewController () <WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate, UIScrollViewDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) NSURL *url;

// Track navigation requests (redirect chain)
@property (nonatomic, strong) NSMutableArray<NSURLRequest *> *redirectRequests;
@property (nonatomic, assign) NSInteger provisionalRetryCount;
@property (nonatomic, assign) NSInteger maxProvisionalRetries;
// Retry counter for didFailNavigation (non-TooManyRedirects) to prevent infinite loops
@property (nonatomic, assign) NSInteger failRetryCount;
@property (nonatomic, assign) NSUInteger navigationGeneration;
@property (nonatomic, strong) WKNavigation *activeNavigation;

@end

@implementation WebViewController

- (instancetype)initWithURL:(NSURL *)url
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _url = url;
        _navigationGeneration = 1;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)navigateToURL:(NSURL *)url
{
    if (!url) return;

    void (^navigate)(void) = ^{
        self.navigationGeneration++;
        self.url = url;
        if (!self.isViewLoaded || !self.webView) return;

        [self.webView stopLoading];
        self.provisionalRetryCount = 0;
        self.failRetryCount = 0;
        [self.redirectRequests removeAllObjects];

        NSURLRequest *request = [NSURLRequest requestWithURL:url
                                                cachePolicy:NSURLRequestReloadIgnoringCacheData
                                            timeoutInterval:WebViewConfigNavigationTimeout];
        self.activeNavigation = [self.webView loadRequest:request];
    };

    if ([NSThread isMainThread]) navigate();
    else dispatch_async(dispatch_get_main_queue(), navigate);
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    // Keep UI outside the web content black
    self.view.backgroundColor = [UIColor blackColor];

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    // Allow inline media playback and enable autoplay where possible
    cfg.allowsInlineMediaPlayback = YES;
    if (@available(iOS 10.0, *)) {
        cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    } else {
        cfg.requiresUserActionForMediaPlayback = NO;
    }

    // Inject a viewport meta override to disable user scaling (pinch/zoom)
    WKUserContentController *ucc = [WKUserContentController new];
    // Lock viewport, block gesture/multi-touch events and keep viewport locked via interval
    NSString *noZoomJS = @"(function(){"
        "function lockViewport(){"
            "var meta=document.querySelector('meta[name=viewport]');"
            "if(!meta){meta=document.createElement('meta');meta.name='viewport';document.head.appendChild(meta);}"
            "meta.content='width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no';"
        "}"
        "lockViewport();"
        "setInterval(lockViewport,500);"
        "document.addEventListener('gesturestart',function(e){e.preventDefault();},{passive:false});"
        "document.addEventListener('gesturechange',function(e){e.preventDefault();},{passive:false});"
        "document.addEventListener('gestureend',function(e){e.preventDefault();},{passive:false});"
        "document.addEventListener('touchmove',function(e){if(e.touches.length>1){e.preventDefault();}},{passive:false});"
    "})();";
    WKUserScript *script = [[WKUserScript alloc] initWithSource:noZoomJS injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
    [ucc addUserScript:script];
    // Also apply after document loads in case the page overrides viewport
    WKUserScript *scriptEnd = [[WKUserScript alloc] initWithSource:noZoomJS injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
    [ucc addUserScript:scriptEnd];

    // Inject JS to enable inline autoplay for <video> elements: add playsinline, webkit-playsinline, muted and autoplay attributes
    NSString *videoAutoJS = @"(function(){function enableVideos(){try{var vids=document.querySelectorAll('video');for(var i=0;i<vids.length;i++){var v=vids[i];v.setAttribute('playsinline','');v.setAttribute('webkit-playsinline','');v.muted=true;v.setAttribute('muted','');v.setAttribute('autoplay','');v.setAttribute('preload','auto');var p=v.play(); if(p && typeof p.then==='function'){p.catch(function(){/*ignore*/});}}}catch(e){} } if (document.readyState==='complete' || document.readyState==='interactive'){enableVideos();} else {document.addEventListener('DOMContentLoaded', enableVideos);} var obs=new MutationObserver(enableVideos); try{obs.observe(document.documentElement||document.body,{childList:true,subtree:true});}catch(e){} })();";
    WKUserScript *script2 = [[WKUserScript alloc] initWithSource:videoAutoJS injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
    [ucc addUserScript:script2];

    cfg.userContentController = ucc;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    // Ensure any transparent parts show black background
    self.webView.backgroundColor = [UIColor clearColor];
    self.webView.opaque = NO;
    self.webView.scrollView.backgroundColor = [UIColor blackColor];
    self.webView.navigationDelegate = self;
    // Handle JS-initiated new windows (window.open / target="_blank")
    self.webView.UIDelegate = self;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];

    // Constrain webView to the view's safe area so content doesn't go under notch/status bar
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor]
    ]];

    // Hard-lock scroll view zoom scale so pinch-to-zoom is impossible
    self.webView.scrollView.delegate = self;
    self.webView.scrollView.minimumZoomScale = 1.0;
    self.webView.scrollView.maximumZoomScale = 1.0;
    // Disable pinch/rotate/double-tap zoom gestures but keep scrolling
    // Disable pinch on scrollView directly
    if (self.webView.scrollView.pinchGestureRecognizer) {
        self.webView.scrollView.pinchGestureRecognizer.enabled = NO;
    }
    // Disable other gesture recognizers that enable scaling/rotation/double-tap
    for (UIGestureRecognizer *g in self.webView.gestureRecognizers) {
        if ([g isKindOfClass:[UIPinchGestureRecognizer class]] || [g isKindOfClass:[UIRotationGestureRecognizer class]]) {
            g.enabled = NO;
        }
        if ([g isKindOfClass:[UITapGestureRecognizer class]]) {
            UITapGestureRecognizer *t = (UITapGestureRecognizer *)g;
            if (t.numberOfTapsRequired >= 2) t.enabled = NO;
        }
    }
    for (UIGestureRecognizer *g in self.webView.scrollView.gestureRecognizers) {
        if ([g isKindOfClass:[UIPinchGestureRecognizer class]] || [g isKindOfClass:[UIRotationGestureRecognizer class]]) {
            g.enabled = NO;
        }
        if ([g isKindOfClass:[UITapGestureRecognizer class]]) {
            UITapGestureRecognizer *t = (UITapGestureRecognizer *)g;
            if (t.numberOfTapsRequired >= 2) t.enabled = NO;
        }
    }

    // Add left-edge pan gesture to navigate back in web view history
    UIScreenEdgePanGestureRecognizer *edgePan = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(handleEdgePan:)];
    edgePan.edges = UIRectEdgeLeft;
    edgePan.delegate = self;
    [self.view addGestureRecognizer:edgePan];

    // Force fullscreen modal presentation and prevent user dismissal (swipe down)
    if (@available(iOS 13.0, *)) {
        self.modalInPresentation = YES;
        if (self.navigationController) {
            self.navigationController.modalInPresentation = YES;
        }
    }

    // Prepare redirect tracking and retry policy
    self.redirectRequests = [NSMutableArray new];
    self.provisionalRetryCount = 0;
    self.maxProvisionalRetries = 3; // safe default

    if (self.url) {
        NSURLRequest *req = [NSURLRequest requestWithURL:self.url cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:WebViewConfigNavigationTimeout];
        self.activeNavigation = [self.webView loadRequest:req];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    // Применяем защиту от захвата экрана после того, как view добавлена в окно.
    // Метод CALayer-swap требует, чтобы view уже была в иерархии.
    // [ScreenCaptureBlocker applyProtectionToLayer:self.webView.layer];
}

- (void)onCloseTapped
{
    // Close action intentionally left empty — controller is non-dismissible.
}

#pragma mark - WKNavigationDelegate
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    if (navigation && self.activeNavigation && navigation != self.activeNavigation) return;
    // Ignore cancellations (e.g. triggered by our own decidePolicyForNavigationAction)
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
        return;
    }

    NSLog(@"[WebViewController] navigation error (domain=%@ code=%ld): %@",
          error.domain, (long)error.code, error.localizedDescription);

    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorHTTPTooManyRedirects) {
        // A real redirect loop must stop. Replaying it through NSURLSession and
        // injecting partial HTML causes another loop and can terminate WebKit.
        NSLog(@"[WebViewController] redirect limit reached; navigation stopped");
    } else {
        // For other transient network errors, retry with a cap to avoid infinite loops.
        // This covers cases where a 301/302 redirect destination is temporarily unreachable.
        const NSInteger kMaxFailRetries = 3;
        if (self.failRetryCount >= kMaxFailRetries) {
            NSLog(@"[WebViewController] navigation error: retry cap reached");
            return;
        }
        self.failRetryCount++;
        NSUInteger generation = self.navigationGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != self.navigationGeneration) return;
            NSURL *target = webView.URL ?: self.url;
            if (target) {
                NSURLRequest *req = [NSURLRequest requestWithURL:target
                                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                timeoutInterval:WebViewConfigNavigationTimeout];
                self.activeNavigation = [webView loadRequest:req];
            }
        });
    }
}

// Track navigation actions (this provides the redirect chain)
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURL *requestURL = navigationAction.request.URL;

    // Sub-frame navigations (iframes etc.) — allow them through without interference.
    // Must be checked first so that blob:/about:/data: URLs used by game launchers inside
    // iframes are never intercepted or sent to UIApplication.
    // Target-blank / new-window requests are handled by createWebViewWithConfiguration:.
    if (navigationAction.targetFrame && !navigationAction.targetFrame.isMainFrame) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    // Open non-http(s) URLs (deeplinks, tel:, mailto:, custom schemes, etc.) via the system.
    // Exclude blob:, about:, data: — WebKit must handle these natively; UIApplication cannot.
    if (requestURL) {
        NSString *scheme = requestURL.scheme.lowercaseString;
        BOOL isWebKitInternal = [scheme isEqualToString:@"blob"] ||
                                [scheme isEqualToString:@"about"] ||
                                [scheme isEqualToString:@"data"];
        if (scheme && ![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"] && !isWebKitInternal) {
            if (@available(iOS 10.0, *)) {
                [[UIApplication sharedApplication] openURL:requestURL options:@{} completionHandler:nil];
            } else {
                [[UIApplication sharedApplication] openURL:requestURL];
            }
            decisionHandler(WKNavigationActionPolicyCancel);
            return;
        }
    }

    if (navigationAction.request) {
        // Append the request to the chain (keep a reasonable cap)
        const NSUInteger kMaxChain = 128;
        if (self.redirectRequests.count >= kMaxChain) {
            [self.redirectRequests removeObjectAtIndex:0];
        }
        [self.redirectRequests addObject:navigationAction.request];
        if (!navigationAction.targetFrame || navigationAction.targetFrame.isMainFrame) {
            self.url = requestURL;
        }
    }

    decisionHandler(WKNavigationActionPolicyAllow);
}


// Handle requests to open new windows (e.g. target="_blank" or window.open())
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures
{
    // When the web content tries to open a new window, override and load
    // the target URL in the existing webView instead of creating a new one.
    if (navigationAction.request.URL) {
        self.url = navigationAction.request.URL;
        [self.redirectRequests removeAllObjects];
        self.activeNavigation = [webView loadRequest:navigationAction.request];
    }
    return nil;
}

// Handle provisional failures (e.g., too many redirects, network interruptions)
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    if (navigation && self.activeNavigation && navigation != self.activeNavigation) return;
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    NSLog(@"[WebViewController] provisional navigation failed: %@", error);

    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorHTTPTooManyRedirects) {
        // Retry the last main-frame request at most a few times. WKWebView itself
        // follows valid 3xx redirects; this branch is only for a genuine loop.
        NSURLRequest *lastReq = [self.redirectRequests lastObject];
        if (lastReq && self.provisionalRetryCount < self.maxProvisionalRetries) {
            self.provisionalRetryCount++;
            NSLog(@"[WebViewController] retrying from last redirect request (attempt %ld)", (long)self.provisionalRetryCount);

            // Clear recorded chain and start new chain from lastReq preserving its method/headers/body
            [self.redirectRequests removeAllObjects];

            // Recreate mutable request to ensure bodies/headers preserved for POST etc.
            NSMutableURLRequest *r = [lastReq mutableCopy];
            r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
            NSUInteger generation = self.navigationGeneration;

            // Small delay to avoid tight retry loop
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (generation != self.navigationGeneration) return;
                self.activeNavigation = [self.webView loadRequest:r];
            });
            return;
        }

        NSLog(@"[WebViewController] redirect retry cap reached");
    } else {
        // Do not replace a failed WebKit navigation with downloaded HTML: that
        // loses cookies, POST bodies, JS context and redirect semantics.
        NSLog(@"[WebViewController] provisional navigation stopped without fallback");
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    if (navigation && self.activeNavigation && navigation != self.activeNavigation) return;
    NSLog(@"[WebViewController] finished loading: %@", webView.URL);
    // Reset retry counters after a successful load
    self.provisionalRetryCount = 0;
    self.failRetryCount = 0;
    // WKWebView resets scrollView delegate and zoom limits after each load — restore them
    webView.scrollView.delegate = self;
    webView.scrollView.minimumZoomScale = 1.0;
    webView.scrollView.maximumZoomScale = 1.0;
    webView.scrollView.zoomScale = 1.0;
}

// Called when the WKWebView web-content process crashes or is killed by the OS
// (e.g. memory pressure). Without this the WebView stays blank forever.
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    NSLog(@"[WebViewController] WKWebView content process terminated — reloading");
    self.provisionalRetryCount = 0;
    [self.redirectRequests removeAllObjects];
    NSUInteger generation = self.navigationGeneration;
    // Brief delay to let the process fully clean up before reloading
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.navigationGeneration) return;
        if (webView.URL) {
            NSURLRequest *req = [NSURLRequest requestWithURL:webView.URL
                                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                            timeoutInterval:WebViewConfigNavigationTimeout];
            self.activeNavigation = [webView loadRequest:req];
        } else if (self.url) {
            NSURLRequest *req = [NSURLRequest requestWithURL:self.url
                                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                            timeoutInterval:WebViewConfigNavigationTimeout];
            self.activeNavigation = [webView loadRequest:req];
        }
    });
}

#pragma mark - Back gesture

- (void)handleEdgePan:(UIScreenEdgePanGestureRecognizer *)gesture
{
    if (gesture.state == UIGestureRecognizerStateEnded) {
        if (self.webView.canGoBack) {
            [self.webView goBack];
        }
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    // Allow the web view's own gestures (scrolling) to work alongside the edge pan
    return YES;
}

#pragma mark - UIScrollViewDelegate

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return nil;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Add observer for keyboard notifications
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    // Remove observer for keyboard notifications
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    // Reset zoom scale when keyboard is shown
    self.webView.scrollView.zoomScale = 1.0;
}

- (void)keyboardWillHide:(NSNotification *)notification {
    // Reset zoom scale when keyboard is hidden
    self.webView.scrollView.zoomScale = 1.0;
}
@end
