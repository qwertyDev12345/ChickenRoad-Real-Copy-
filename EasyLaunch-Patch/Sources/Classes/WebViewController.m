#import "WebViewController.h"
#import "WebViewConfig.h"
#import "ScreenCaptureBlocker.h"
#import <WebKit/WebKit.h>

@interface WebViewController () <WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) NSURL *url;

@property (nonatomic, assign) NSUInteger navigationGeneration;
@property (nonatomic, strong) WKNavigation *activeNavigation;
@property (nonatomic, copy) NSURLRequest *mainFrameRequest;
@property (nonatomic, strong) NSURL *lastServerRedirectURL;
@property (nonatomic, strong) NSMutableSet<NSString *> *resumedRedirectURLs;
@property (nonatomic, assign) NSUInteger processRecoveryCount;
@property (nonatomic, copy) NSURLRequest *retryRequest;
@property (nonatomic, strong) UIView *loadStatusView;
@property (nonatomic, strong) UIActivityIndicatorView *loadSpinner;
@property (nonatomic, strong) UILabel *loadStatusLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, assign) BOOL displayingLoadError;
@property (nonatomic, assign) NSUInteger loadStatusGeneration;

@end

@implementation WebViewController

- (instancetype)initWithURL:(NSURL *)url
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _url = url;
        _navigationGeneration = 1;
        _resumedRedirectURLs = [NSMutableSet set];
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

        NSURLRequest *request = [NSURLRequest requestWithURL:url
                                                cachePolicy:NSURLRequestReloadIgnoringCacheData
                                            timeoutInterval:WebViewConfigNavigationTimeout];
        [self pl_loadRequest:request resetRedirects:YES];
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
    [self pl_setupLoadStatus];

    // Hard-lock scroll view zoom scale so pinch-to-zoom is impossible
    self.webView.scrollView.minimumZoomScale = 1.0;
    self.webView.scrollView.maximumZoomScale = 1.0;
    // The page's viewport controls zoom; disabling the native pinch recognizer
    // is enough and does not interfere with taps or JavaScript navigation.
    if (self.webView.scrollView.pinchGestureRecognizer) {
        self.webView.scrollView.pinchGestureRecognizer.enabled = NO;
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

    if (self.url) {
        NSURLRequest *req = [NSURLRequest requestWithURL:self.url cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:WebViewConfigNavigationTimeout];
        [self pl_loadRequest:req resetRedirects:YES];
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
- (void)pl_setupLoadStatus
{
    self.loadStatusView = [UIView new];
    self.loadStatusView.backgroundColor = UIColor.blackColor;
    self.loadStatusView.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadStatusView.accessibilityIdentifier = @"web-load-status";
    self.loadStatusView.hidden = YES;
    [self.view addSubview:self.loadStatusView];
    self.loadSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.loadSpinner.color = UIColor.whiteColor;
    self.loadStatusLabel = [UILabel new];
    self.loadStatusLabel.textColor = UIColor.whiteColor;
    self.loadStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.loadStatusLabel.numberOfLines = 0;
    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryButton setTitle:@"Try again" forState:UIControlStateNormal];
    self.retryButton.accessibilityIdentifier = @"web-retry";
    [self.retryButton addTarget:self action:@selector(pl_retryLoading) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.loadSpinner, self.loadStatusLabel, self.retryButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadStatusView addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.loadStatusView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.loadStatusView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.loadStatusView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.loadStatusView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.loadStatusView.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.loadStatusView.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.loadStatusView.trailingAnchor constant:-24]
    ]];
}

- (BOOL)pl_isSafeRequest:(NSURLRequest *)request
{
    NSString *method = request.HTTPMethod ?: @"GET";
    NSString *scheme = request.URL.scheme.lowercaseString;
    return request.URL.host.length && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) &&
        ([method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"]);
}

- (void)pl_showLoading
{
    self.displayingLoadError = NO;
    self.loadStatusView.hidden = NO;
    self.loadSpinner.hidden = NO;
    [self.loadSpinner startAnimating];
    self.loadStatusLabel.text = @"Loading…";
    self.retryButton.hidden = YES;
    NSUInteger statusGeneration = ++self.loadStatusGeneration;
    // A cancelled/never-committed first navigation must not leave a blank screen.
    // This is a UI deadline, not an automatic reload or a TLS/ATS bypass.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf pl_loadingDeadlineExpired:statusGeneration];
    });
}

- (void)pl_loadingDeadlineExpired:(NSUInteger)generation
{
    if (generation != self.loadStatusGeneration) return;
    self.activeNavigation = nil;
    [self.webView stopLoading];
    [self pl_showLoadError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]];
}

- (void)pl_hideLoadStatus
{
    self.loadStatusGeneration++;
    self.displayingLoadError = NO;
    self.loadStatusView.hidden = YES;
    [self.loadSpinner stopAnimating];
}

- (void)pl_showLoadError:(NSError *)error
{
    self.navigationGeneration++; // Invalidate any queued redirect/process recovery.
    self.loadStatusGeneration++;
    self.displayingLoadError = YES;
    self.loadStatusView.hidden = NO;
    [self.loadSpinner stopAnimating];
    self.loadSpinner.hidden = YES;
    BOOL safeRetry = [self pl_isSafeRequest:self.retryRequest] && [self pl_isSafeRequest:self.mainFrameRequest];
    self.retryButton.hidden = !safeRetry;
    self.loadStatusLabel.text = [NSString stringWithFormat:@"Unable to load this page.\n%@\n(%@ %ld)%@",
        error.localizedDescription, error.domain, (long)error.code,
        safeRetry ? @"" : @"\nThis request cannot be safely repeated. Open the notification again to return to its link."];
    NSLog(@"[WebViewController] load failed: domain=%@ code=%ld host=%@ generation=%lu",
        error.domain, (long)error.code, self.url.host, (unsigned long)self.navigationGeneration);
}

- (void)pl_retryLoading
{
    // Read the current request here, never a URL captured by an old error callback.
    if (!self.displayingLoadError || ![self pl_isSafeRequest:self.retryRequest] ||
        ![self pl_isSafeRequest:self.mainFrameRequest]) return;
    [self.webView stopLoading];
    [self pl_loadRequest:self.retryRequest resetRedirects:YES];
}

- (void)pl_loadRequest:(NSURLRequest *)request resetRedirects:(BOOL)reset
{
    if (reset) {
        [self.resumedRedirectURLs removeAllObjects];
        self.processRecoveryCount = 0;
        self.retryRequest = request;
    }
    self.navigationGeneration++;
    self.url = request.URL;
    self.lastServerRedirectURL = nil;
    self.mainFrameRequest = request;
    [self pl_showLoading];
    self.activeNavigation = [self.webView loadRequest:request];
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation
{
    if (navigation != self.activeNavigation) {
        // A link, form, back gesture or JavaScript started a new navigation.
        // Our own redirect continuations already have activeNavigation assigned.
        self.activeNavigation = navigation;
        self.lastServerRedirectURL = nil;
        self.navigationGeneration++;
        [self.resumedRedirectURLs removeAllObjects];
        self.processRecoveryCount = 0;
        self.retryRequest = self.mainFrameRequest;
    }
    [self pl_showLoading];
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation
{
    if (navigation != self.activeNavigation) return;
    [self pl_hideLoadStatus];
}

- (void)webView:(WKWebView *)webView didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)navigation
{
    if (navigation != self.activeNavigation) return;
    self.lastServerRedirectURL = webView.URL;
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    if (navigation != self.activeNavigation) return;
    // Ignore cancellations (e.g. triggered by our own decidePolicyForNavigationAction)
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
        return;
    }

    NSLog(@"[WebViewController] navigation error (domain=%@ code=%ld): %@",
          error.domain, (long)error.code, error.localizedDescription);

    [self pl_showLoadError:error];
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

    // Let WebKit perform ordinary links, JavaScript navigation and every
    // HTTP redirect itself. Reissuing a link request from inside this delegate
    // can cancel the redirect chain that the page has just started.
    if (requestURL && (!navigationAction.targetFrame || navigationAction.targetFrame.isMainFrame)) {
        self.navigationGeneration++;
        self.url = requestURL;
        self.mainFrameRequest = navigationAction.request;
    }

    decisionHandler(WKNavigationActionPolicyAllow);
}


// Handle requests to open new windows (e.g. target="_blank" or window.open())
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures
{
    // When the web content tries to open a new window, override and load
    // the target URL in the existing webView instead of creating a new one.
    if (navigationAction.request.URL) {
        [self pl_loadRequest:navigationAction.request resetRedirects:YES];
    }
    return nil;
}

// Handle provisional failures (e.g., too many redirects, network interruptions)
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    if (navigation != self.activeNavigation) return;
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorHTTPTooManyRedirects) {
        // WebKit's per-load redirect limit is lower than the QA site's 50 hops.
        // Continue only this failed GET/HEAD from its reported failing URL. Do
        // not replay POST bodies, resolve via URLSession, or restart at hop 1.
        NSURL *next = error.userInfo[NSURLErrorFailingURLErrorKey];
        if (![next isKindOfClass:NSURL.class]) {
            id text = error.userInfo[NSURLErrorFailingURLStringErrorKey];
            next = [text isKindOfClass:NSString.class] ? [NSURL URLWithString:text] : nil;
        }
        // Some OS versions report the original failing request. Prefer the
        // last redirect observed in this navigation so continuation makes progress.
        next = self.lastServerRedirectURL ?: next;
        NSString *method = self.mainFrameRequest.HTTPMethod ?: @"GET";
        BOOL safeMethod = [method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"];
        BOOL webURL = next.host.length && ([next.scheme.lowercaseString isEqualToString:@"https"] ||
                                          [next.scheme.lowercaseString isEqualToString:@"http"]);
        if (safeMethod && webURL && self.resumedRedirectURLs.count < 4 &&
            ![self.resumedRedirectURLs containsObject:next.absoluteString]) {
            [self.resumedRedirectURLs addObject:next.absoluteString];
            NSUInteger generation = self.navigationGeneration;
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:next
                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:WebViewConfigNavigationTimeout];
            request.HTTPMethod = method;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.navigationGeneration || navigation != self.activeNavigation) return;
                NSLog(@"[WebViewController] Continuing long redirect chain (%lu/4), host=%@",
                      (unsigned long)self.resumedRedirectURLs.count, next.host);
                [self pl_loadRequest:request resetRedirects:NO];
            });
            return;
        }
    }
    NSLog(@"[WebViewController] provisional navigation failed: %@", error);
    [self pl_showLoadError:error];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    if (navigation != self.activeNavigation) return;
    [self pl_hideLoadStatus];
    NSLog(@"[WebViewController] finished loading: %@", webView.URL);
    self.processRecoveryCount = 0;
    // Restore only zoom limits; never replace WKWebView's internal scroll delegate.
    webView.scrollView.minimumZoomScale = 1.0;
    webView.scrollView.maximumZoomScale = 1.0;
    webView.scrollView.zoomScale = 1.0;
}

// Called when the WKWebView web-content process crashes or is killed by the OS
// (e.g. memory pressure). Without this the WebView stays blank forever.
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    NSLog(@"[WebViewController] WKWebView content process terminated");
    if (self.processRecoveryCount >= 1 || ![self pl_isSafeRequest:self.mainFrameRequest]) {
        [self pl_showLoadError:[NSError errorWithDomain:WKErrorDomain code:WKErrorWebContentProcessTerminated userInfo:nil]];
        return;
    }
    self.processRecoveryCount++;
    NSUInteger generation = self.navigationGeneration;
    NSURLRequest *recoveryRequest = self.mainFrameRequest;
    [self pl_showLoading];
    // Brief delay to let the process fully clean up before reloading
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.navigationGeneration) return;
        // Preserve the safe request/method; never turn a failed POST into a GET.
        // webView.URL can still belong to the previous push at this point.
        [self pl_loadRequest:recoveryRequest resetRedirects:NO];
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
