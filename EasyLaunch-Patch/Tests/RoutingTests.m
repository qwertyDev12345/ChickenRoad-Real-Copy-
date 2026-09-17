#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import <UserNotifications/UserNotifications.h>
#import "CustomAppController.h"
#import "PreloadViewController.h"
#import "NotificationPromptViewController.h"
#import "WebViewController.h"

extern NSData *PLTestAPNsToken;
@interface CustomAppController (TestAccess)
+ (NSURL *)pl_pushURLFromUserInfo:(NSDictionary *)info;
- (void)application:(UIApplication *)app didReceiveRemoteNotification:(NSDictionary *)info fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completion;
- (void)application:(UIApplication *)app didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)token;
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)(void))completion;
- (void)pl_openURL:(NSURL *)url generation:(NSUInteger)generation;
- (BOOL)pl_isApplicationActive;
- (UIWindow *)pl_presentationWindow;
- (void)pl_drainPendingOpen;
- (void)dismissPreloadAndStartUnity;
@end
@interface NotificationPromptViewController (TestAccess)
- (void)onAllow:(id)sender;
@end
@interface PreloadViewController (TestAccess)
- (void)pl_finishWithURL:(NSURL *)url;
- (void)pl_checkAndAskNotificationsIfNeededWithCompletion:(void (^)(void))completion;
- (void)pl_step1_checkNetwork;
@end
@interface WebViewController (TestAccess)
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error;
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView;
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error;
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation;
- (void)pl_retryLoading;
- (void)pl_loadingDeadlineExpired:(NSUInteger)generation;
- (NSString *)pl_diagnosticReportForError:(NSError *)error source:(NSString *)source;
- (void)pl_recordDiagnostic:(NSString *)event URL:(NSURL *)url;
- (void)pl_copyDiagnostics;
- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response decisionHandler:(void (^)(WKNavigationResponsePolicy))handler;
@end

@interface TestNavigationResponse : NSObject
@property (nonatomic, strong) NSURLResponse *response;
@property (nonatomic, getter=isForMainFrame) BOOL forMainFrame;
@property (nonatomic) BOOL canShowMIMEType;
@end
@implementation TestNavigationResponse
@end

// Intercepts only the OS permission dialog/network entry; the production
// preload state machine, callbacks and viewDidAppear still run unchanged.
@interface PermissionPreload : PreloadViewController
@property (nonatomic, copy) void (^permissionCompletion)(void);
@property (nonatomic, copy) void (^networkStarted)(void);
@property (nonatomic) NSUInteger permissionCount;
@end
@implementation PermissionPreload
- (void)pl_checkAndAskNotificationsIfNeededWithCompletion:(void (^)(void))completion {
    self.permissionCount++;
    self.permissionCompletion = completion;
}
- (void)pl_step1_checkNetwork { if (self.networkStarted) self.networkStarted(); }
@end

// Only substitute the OS activation state; presentation/retries use production
// code and real UIKit windows, controllers and animations.
@interface RoutingApp : CustomAppController
@property (nonatomic) BOOL simulatedActive;
@end
@implementation RoutingApp
- (BOOL)pl_isApplicationActive { return self.simulatedActive; }
@end

@interface RejectOncePresenter : UIViewController
@property (nonatomic) NSUInteger presentationAttempts;
@end
@implementation RejectOncePresenter
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    self.presentationAttempts++;
    if (self.presentationAttempts == 1) return; // UIKit rejection: no completion.
    [super presentViewController:vc animated:animated completion:completion];
}
@end

// Notification responses cannot be publicly constructed. This object supplies
// their documented read-only properties to the production delegate method.
@interface TestResponse : NSObject
@property (nonatomic, copy) NSString *actionIdentifier;
@property (nonatomic, strong) id notification;
@end
@implementation TestResponse
@end
@interface TestNotification : NSObject
@property (nonatomic, strong) UNNotificationRequest *request;
@end
@implementation TestNotification
@end

@interface RoutingTests : XCTestCase
@property (nonatomic, strong) UIWindow *testWindow;
@property (nonatomic, strong) UIWindow *otherWindow;
@end
@implementation RoutingTests
- (void)setUp {
    [super setUp];
    for (NSString *key in @[@"PLLaunchMode", @"PLLastEndpointURLString", @"PLLastNotificationDeniedAt"])
        [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
}
- (void)tearDown {
    self.otherWindow.hidden = YES;
    self.otherWindow.rootViewController = nil;
    self.otherWindow = nil;
    self.testWindow.hidden = YES;
    self.testWindow.rootViewController = nil;
    self.testWindow = nil;
    [super tearDown];
}
- (void)drainMainQueue {
    XCTestExpectation *done = [self expectationWithDescription:@"main queue drained"];
    dispatch_async(dispatch_get_main_queue(), ^{ [done fulfill]; });
    [self waitForExpectations:@[done] timeout:2];
}
- (NSURL *)URL:(NSString *)path {
    return [NSURL URLWithString:[@"http://127.0.0.1:18765" stringByAppendingString:path]];
}
- (void)tapPush:(NSString *)path app:(CustomAppController *)app {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.userInfo = @{@"click_url": [self URL:path].absoluteString};
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:path content:content trigger:nil];
    [app userNotificationCenter:nil didReceiveNotificationResponse:[self responseForRequest:request] withCompletionHandler:^{}];
    [self drainMainQueue];
}
- (void)testPushBeforeUnityEntryIsTransferredToStartupNotRuntimeQueue {
    RoutingApp *app = [RoutingApp new];
    app.simulatedActive = YES;
    XCTAssertFalse([[app valueForKey:@"preloadInProgress"] boolValue]);
    [self tapPush:@"/push-a" app:app];
    [self tapPush:@"/777" app:app];
    XCTAssertEqualObjects([[app valueForKey:@"pendingPushURL"] path], @"/777");
    XCTAssertNil([app valueForKey:@"deferredOpenURL"]);
    [app initUnityWithScene:nil];
    [self drainMainQueue];
    self.testWindow = [app valueForKey:@"preloadWindow"];
    XCTAssertNotNil(self.testWindow);
    WebViewController *web = [self waitForRoutedWebView:app];
    [self waitForWebView:web path:@"/777"];
    XCTAssertTrue([(PreloadViewController *)self.testWindow.rootViewController hasFinished]);
    XCTAssertNil([app valueForKey:@"pendingPushURL"]);
}
- (void)testLateStartupCallbackCannotReplaceSecondRuntimePush {
    RoutingApp *app = [RoutingApp new];
    app.simulatedActive = YES;
    [self tapPush:@"/push-a" app:app];
    [app initUnityWithScene:nil];
    [self drainMainQueue];
    self.testWindow = [app valueForKey:@"preloadWindow"];
    WebViewController *web = [self waitForRoutedWebView:app];
    [self waitForWebView:web path:@"/push-a"];
    PreloadViewController *preload = (id)self.testWindow.rootViewController;
    [self tapPush:@"/777" app:app];
    // Exercise the app's callback guard independently of preload's one-shot guard.
    preload.onOpenURL([self URL:@"/stale-config"]);
    preload.onComplete();
    [self waitForRoutedWebView:app];
    [self waitForWebView:web path:@"/777"];
    XCTAssertFalse([[app valueForKey:@"unityMode"] boolValue]);
    XCTAssertEqual(self.testWindow.rootViewController.presentedViewController, web);
}
- (void)testPushInterruptsConfigAndIgnoresItsLateCompletion {
    PermissionPreload *preload = [PermissionPreload new];
    __block NSUInteger opens = 0;
    __block NSURL *opened;
    __block NSUInteger unityStarts = 0;
    preload.onOpenURL = ^(NSURL *url) { opens++; opened = url; };
    preload.onComplete = ^{ unityStarts++; };
    [preload startChecks]; // stub leaves config chain pending
    [preload acceptPushURL:[self URL:@"/777"]];
    [preload pl_finishWithURL:[self URL:@"/late-config"]];
    [preload pl_finishWithURL:nil];
    [self drainMainQueue];
    XCTAssertEqual(opens, 1u);
    XCTAssertEqualObjects(opened.path, @"/777");
    XCTAssertEqual(unityStarts, 0u);
    XCTAssertEqual(preload.permissionCount, 0u);
}
- (void)testPushDuringUnityFadePreservesWebOwningWindow {
    RoutingApp *app = [RoutingApp new];
    app.simulatedActive = YES;
    PermissionPreload *root = [PermissionPreload new];
    [self showRoutingRoot:root app:app];
    [root setValue:@YES forKey:@"hasFinished"];
    [app setValue:@YES forKey:@"preloadInProgress"];
    [app dismissPreloadAndStartUnity];
    [self drainMainQueue];
    XCTAssertTrue([[app valueForKey:@"startingUnity"] boolValue]);
    [self tapPush:@"/777" app:app];
    WebViewController *web = [self waitForRoutedWebView:app];
    [self waitForWebView:web path:@"/777"];
    XCTAssertFalse([[app valueForKey:@"unityMode"] boolValue]);
    XCTAssertEqual([app valueForKey:@"preloadWindow"], self.testWindow);
    XCTAssertEqual(self.testWindow.alpha, 1.0);
    XCTAssertFalse(self.testWindow.hidden);
}
- (void)testExplicitClickURLWinsOverGenericURL {
    NSDictionary *payload = @{@"url": [self URL:@"/generic"].absoluteString,
        @"click_url": [self URL:@"/clicked"].absoluteString};
    XCTAssertEqualObjects([CustomAppController pl_pushURLFromUserInfo:payload].path, @"/clicked");
    NSDictionary *nested = @{@"url": [self URL:@"/generic"].absoluteString,
        @"data": @{@"click_url": [self URL:@"/nested-click"].absoluteString}};
    XCTAssertEqualObjects([CustomAppController pl_pushURLFromUserInfo:nested].path, @"/nested-click");
}
- (void)testInvalidCandidateDoesNotHideValidPayloadURL {
    NSDictionary *payload = @{@"click_url": @"javascript:alert(1)", @"url": @"not a URL",
        @"data": @{@"url": [self URL:@"/valid-fallback"].absoluteString}};
    XCTAssertEqualObjects([CustomAppController pl_pushURLFromUserInfo:payload].path, @"/valid-fallback");
    NSDictionary *invalidGeneric = @{@"url": @"invalid", @"click_url": [self URL:@"/clicked"].absoluteString};
    XCTAssertEqualObjects([CustomAppController pl_pushURLFromUserInfo:invalidGeneric].path, @"/clicked");
}
- (void)testPushParserAcceptsLegacyURLAndTrimsWhitespace {
    XCTAssertEqualObjects([CustomAppController pl_pushURLFromUserInfo:
        @{@"aps": @{@"url": [self URL:@"/legacy"].absoluteString}}].path, @"/legacy");
    NSString *padded = [NSString stringWithFormat:@" \n%@\n ", [self URL:@"/trimmed"].absoluteString];
    XCTAssertEqualObjects([CustomAppController pl_pushURLFromUserInfo:@{@"click_url": padded}].path, @"/trimmed");
}
- (void)testPushParserNeverUsesImageOrPreviousResponse {
    XCTAssertNotNil([CustomAppController pl_pushURLFromUserInfo:@{@"url": [self URL:@"/first"].absoluteString}]);
    NSDictionary *imageOnly = @{@"image_url": [self URL:@"/image.jpg"].absoluteString,
        @"data": @42, @"aps": NSNull.null};
    NSDictionary *invalidValues = @{@"url": @42, @"click_url": @"file:///private/file",
        @"data": @{@"url": NSNull.null}};
    XCTAssertNil([CustomAppController pl_pushURLFromUserInfo:imageOnly]);
    XCTAssertNil([CustomAppController pl_pushURLFromUserInfo:invalidValues]);
    XCTAssertNil([CustomAppController pl_pushURLFromUserInfo:(id)@[]]);
}
- (void)waitUntil:(BOOL (^)(void))condition description:(NSString *)description {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return condition();
    }];
    XCTNSPredicateExpectation *done = [[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:nil];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[done] timeout:5], XCTWaiterResultCompleted, @"%@", description);
}
- (void)showRoutingRoot:(UIViewController *)root app:(RoutingApp *)app {
    self.testWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.testWindow.windowLevel = UIWindowLevelNormal + 10;
    self.testWindow.rootViewController = root;
    [app setValue:self.testWindow forKey:@"preloadWindow"];
    [self.testWindow makeKeyAndVisible];
    [self waitUntil:^BOOL { return root.viewIfLoaded.window != nil; } description:@"root visible"];
}
- (WebViewController *)waitForRoutedWebView:(RoutingApp *)app {
    [self waitUntil:^BOOL {
        UIViewController *vc = self.testWindow.rootViewController.presentedViewController;
        return [vc isKindOfClass:WebViewController.class] && vc.viewIfLoaded.window == self.testWindow &&
            [app valueForKey:@"deferredOpenURL"] == nil;
    } description:@"queued URL delivered to visible WebView"];
    return (WebViewController *)self.testWindow.rootViewController.presentedViewController;
}
- (void)testPermissionAllowWhileInactiveOpensWithoutAnotherDelegateCallback {
    RoutingApp *app = [RoutingApp new];
    PermissionPreload *root = [PermissionPreload new];
    [self showRoutingRoot:root app:app];
    __weak RoutingApp *weakApp = app;
    root.onOpenURL = ^(NSURL *url) { [weakApp pl_openURL:url generation:0]; };
    [root pl_finishWithURL:[self URL:@"/after-permission"]];
    [self drainMainQueue];
    XCTAssertNotNil(root.permissionCompletion);
    NotificationPromptViewController *prompt = [[NotificationPromptViewController alloc]
        initWithTitle:@"Allow" message:@"Test" backgroundImage:nil
        allowHandler:^{ root.permissionCompletion(); } cancelHandler:^{}];
    prompt.modalPresentationStyle = UIModalPresentationFullScreen;
    XCTestExpectation *shown = [self expectationWithDescription:@"permission prompt shown"];
    [root presentViewController:prompt animated:YES completion:^{ [shown fulfill]; }];
    [self waitForExpectations:@[shown] timeout:5];
    [prompt onAllow:nil];
    [self waitUntil:^BOOL { return root.hasFinished; } description:@"allow completed while inactive"];
    XCTAssertNil(root.presentedViewController);
    XCTAssertNotNil([app valueForKey:@"deferredOpenURL"]);
    // Simulate UIKit becoming ready after the earlier lifecycle callback.
    // Deliberately send no applicationDidBecomeActive: call or notification.
    app.simulatedActive = YES;
    WebViewController *web = [self waitForRoutedWebView:app];
    [self waitForWebView:web path:@"/after-permission"];
}
- (void)testSettingsReturnResumesRetainedDestinationAfterRetryBudget {
    RoutingApp *app = [RoutingApp new];
    [self showRoutingRoot:[UIViewController new] app:app];
    [app pl_openURL:[self URL:@"/after-settings"] generation:0];
    [self drainMainQueue];
    [app setValue:@100 forKey:@"openRetryCount"];
    [app pl_drainPendingOpen];
    [self waitUntil:^BOOL { return ![[app valueForKey:@"openAttemptScheduled"] boolValue]; }
        description:@"bounded retry ended"];
    XCTAssertNotNil([app valueForKey:@"deferredOpenURL"]);
    app.simulatedActive = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:UISceneDidActivateNotification object:nil];
    WebViewController *web = [self waitForRoutedWebView:app];
    [self waitForWebView:web path:@"/after-settings"];
}
- (void)testRejectedPresentationRetriesInOwnedWindowNotForeignKeyWindow {
    RoutingApp *app = [RoutingApp new];
    app.simulatedActive = YES;
    RejectOncePresenter *root = [RejectOncePresenter new];
    [self showRoutingRoot:root app:app];
    self.otherWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.otherWindow.rootViewController = [UIViewController new];
    [self.otherWindow makeKeyAndVisible];
    app.window = self.otherWindow;
    XCTAssertEqual([app pl_presentationWindow], self.testWindow);
    [app pl_openURL:[self URL:@"/retry-presentation"] generation:0];
    [self drainMainQueue];
    XCTAssertNotNil([app valueForKey:@"deferredOpenURL"]);
    WebViewController *web = [self waitForRoutedWebView:app];
    XCTAssertEqual(root.presentationAttempts, 2u);
    XCTAssertNil(self.otherWindow.rootViewController.presentedViewController);
    [self waitForWebView:web path:@"/retry-presentation"];
}
- (void)testQueuedPushReplacementDoesNotReplayOldURLOnActivation {
    RoutingApp *app = [RoutingApp new];
    [self showRoutingRoot:[UIViewController new] app:app];
    [app pl_openURL:[self URL:@"/push-a"] generation:0];
    [self drainMainQueue];
    [app setValue:@1 forKey:@"pushTapGeneration"];
    [app pl_openURL:[self URL:@"/push-b"] generation:1];
    [app pl_openURL:[self URL:@"/push-a"] generation:0]; // stale callback
    app.simulatedActive = YES;
    WebViewController *web = [self waitForRoutedWebView:app];
    [self waitForWebView:web path:@"/push-b"];
    WKNavigation *navigation = [web valueForKey:@"activeNavigation"];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    [self drainMainQueue];
    [self drainMainQueue];
    XCTAssertEqual(navigation, [web valueForKey:@"activeNavigation"]);
    XCTAssertNil([app valueForKey:@"deferredOpenURL"]);
}
- (void)testNewPushDuringPresentationReusesTheOpeningController {
    RoutingApp *app = [RoutingApp new];
    app.simulatedActive = YES;
    UIViewController *root = [UIViewController new];
    [self showRoutingRoot:root app:app];
    [app pl_openURL:[self URL:@"/push-a"] generation:0];
    [self drainMainQueue];
    UIViewController *opening = root.presentedViewController;
    XCTAssertTrue([opening isKindOfClass:WebViewController.class]);
    [app setValue:@1 forKey:@"pushTapGeneration"];
    [app pl_openURL:[self URL:@"/push-b"] generation:1];
    WebViewController *web = [self waitForRoutedWebView:app];
    XCTAssertEqual(web, opening);
    XCTAssertNil(web.presentedViewController);
    [self waitForWebView:web path:@"/push-b"];
}
- (void)testPushWaitsForFilePickerAndReusesOriginalWebViewAfterLongSelection {
    RoutingApp *app = [RoutingApp new];
    app.simulatedActive = YES;
    UIViewController *root = [UIViewController new];
    [self showRoutingRoot:root app:app];
    [app pl_openURL:[self URL:@"/form"] generation:0];
    WebViewController *web = [self waitForRoutedWebView:app];
    [self waitForWebView:web path:@"/form"];
    WKNavigation *originalNavigation = [web valueForKey:@"activeNavigation"];
    // Simulator-independent substitute for the native camera/file picker.
    // It uses real full-screen UIKit presentation but does not take a photo.
    UIViewController *picker = [UIViewController new];
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    XCTestExpectation *shown = [self expectationWithDescription:@"native picker presented"];
    [web presentViewController:picker animated:YES completion:^{ [shown fulfill]; }];
    [self waitForExpectations:@[shown] timeout:5];
    [app pl_openURL:[self URL:@"/push-a"] generation:0];
    [app setValue:@101 forKey:@"openRetryCount"]; // selection outlasted normal retry budget
    [self drainMainQueue];
    XCTAssertNil(picker.presentedViewController);
    XCTAssertEqual([web valueForKey:@"activeNavigation"], originalNavigation);
    XCTAssertTrue([[app valueForKey:@"openAttemptScheduled"] boolValue]);
    [app setValue:@1 forKey:@"pushTapGeneration"];
    [app pl_openURL:[self URL:@"/push-b"] generation:1];
    XCTestExpectation *closed = [self expectationWithDescription:@"picker returned"];
    [picker dismissViewControllerAnimated:YES completion:^{ [closed fulfill]; }];
    [self waitForExpectations:@[closed] timeout:5];
    XCTAssertEqual([self waitForRoutedWebView:app], web);
    XCTAssertNil(web.presentedViewController);
    [self waitForWebView:web path:@"/push-b"];
}
- (void)testReturningFromNativeModalWithoutPushDoesNotReloadDocument {
    RoutingApp *app = [RoutingApp new];
    app.simulatedActive = YES;
    [self showRoutingRoot:[UIViewController new] app:app];
    [app pl_openURL:[self URL:@"/form"] generation:0];
    WebViewController *web = [self waitForRoutedWebView:app];
    [self waitForWebView:web path:@"/form"];
    WKNavigation *originalNavigation = [web valueForKey:@"activeNavigation"];
    UIViewController *picker = [UIViewController new];
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    XCTestExpectation *shown = [self expectationWithDescription:@"picker shown without push"];
    [web presentViewController:picker animated:YES completion:^{ [shown fulfill]; }];
    [self waitForExpectations:@[shown] timeout:5];
    [app applicationDidBecomeActive:UIApplication.sharedApplication];
    XCTestExpectation *closed = [self expectationWithDescription:@"picker dismissed without push"];
    [picker dismissViewControllerAnimated:YES completion:^{ [closed fulfill]; }];
    [self waitForExpectations:@[closed] timeout:5];
    [self drainMainQueue];
    XCTAssertEqual([web valueForKey:@"activeNavigation"], originalNavigation);
    XCTAssertEqual(self.testWindow.rootViewController.presentedViewController, web);
    XCTAssertNil([app valueForKey:@"deferredOpenURL"]);
}
- (WebViewController *)showWebView:(NSString *)path {
    WebViewController *vc = [[WebViewController alloc] initWithURL:[self URL:path]];
    self.testWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.testWindow.rootViewController = vc;
    [self.testWindow makeKeyAndVisible];
    [vc loadViewIfNeeded];
    return vc;
}
- (void)waitForWebView:(WebViewController *)vc path:(NSString *)path {
    NSPredicate *loaded = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        WKWebView *web = [vc valueForKey:@"webView"];
        return !web.loading && [web.URL.path isEqualToString:path];
    }];
    XCTNSPredicateExpectation *done = [[XCTNSPredicateExpectation alloc] initWithPredicate:loaded object:vc];
    [self waitForExpectations:@[done] timeout:30];
}
- (void)testRemoteNotificationWithUnityHandlerCompiledOut {
    CustomAppController *app = [CustomAppController new];
    __block NSUInteger count = 0;
    XCTAssertNoThrow([app application:UIApplication.sharedApplication didReceiveRemoteNotification:@{}
        fetchCompletionHandler:^(UIBackgroundFetchResult result) {
            count++;
            XCTAssertEqual(result, UIBackgroundFetchResultNoData);
        }]);
    XCTAssertEqual(count, 1u);
}
- (void)testBackgroundAndMemoryBeforeEngineStartup {
    CustomAppController *app = [CustomAppController new];
    XCTAssertNoThrow([app applicationDidEnterBackground:UIApplication.sharedApplication]);
    XCTAssertNoThrow([app applicationDidReceiveMemoryWarning:UIApplication.sharedApplication]);
    app.engineLoadState = kUnityEngineLoadStateAppReady;
    XCTAssertNoThrow([app applicationDidEnterBackground:UIApplication.sharedApplication]);
}
- (void)testAPNsIsForwardedAsBytesWithoutDictionaryLookup {
    NSData *token = [@"apns-token-bytes" dataUsingEncoding:NSUTF8StringEncoding];
    CustomAppController *app = [CustomAppController new];
    XCTAssertNoThrow([app application:UIApplication.sharedApplication didRegisterForRemoteNotificationsWithDeviceToken:token]);
    XCTAssertEqualObjects(PLTestAPNsToken, token);
}
- (void)testPermissionDismissalDoesNotRestartPreload {
    PermissionPreload *vc = [PermissionPreload new];
    XCTestExpectation *network = [self expectationWithDescription:@"only one network chain"];
    network.assertForOverFulfill = YES;
    vc.networkStarted = ^{ [network fulfill]; };
    [vc viewDidAppear:NO];
    [vc viewDidAppear:NO];
    [vc startChecks];
    [self waitForExpectations:@[network] timeout:2];
}
- (void)testLatestPushWinsAfterPermissionAndCompletionIsOneShot {
    // Expired three-day cooldown; the OS permission UI is supplied by the stub.
    [NSUserDefaults.standardUserDefaults setObject:[NSDate dateWithTimeIntervalSinceNow:-4*24*3600]
        forKey:@"PLLastNotificationDeniedAt"];
    PermissionPreload *vc = [PermissionPreload new];
    __block NSUInteger opens = 0;
    __block NSURL *opened;
    vc.onOpenURL = ^(NSURL *url) { opens++; opened = url; };
    [vc pl_finishWithURL:[self URL:@"/server"]];
    [vc pl_finishWithURL:[self URL:@"/stale-server"]];
    [self drainMainQueue];
    XCTAssertEqual(vc.permissionCount, 1u);
    [vc acceptPushURL:[self URL:@"/push-a"]];
    [vc acceptPushURL:[self URL:@"/push-b"]];
    XCTAssertFalse(vc.hasFinished); // permission still owns the handoff
    vc.permissionCompletion();
    vc.permissionCompletion();
    [vc viewDidAppear:NO];
    XCTAssertEqual(opens, 1u);
    XCTAssertEqualObjects(opened.path, @"/push-b");
    XCTAssertTrue(vc.hasFinished);
}
- (void)testTwoResponsesWithSameURLAndDifferentIDsAreNotDeduplicated {
    CustomAppController *app = [CustomAppController new];
    PermissionPreload *vc = [PermissionPreload new];
    UIWindow *window = [UIWindow new];
    window.rootViewController = vc;
    [app setValue:window forKey:@"preloadWindow"];
    [app setValue:@"first-id" forKey:@"coldStartMessageID"];
    __block NSURL *opened;
    vc.onOpenURL = ^(NSURL *url) { opened = url; };
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.userInfo = @{@"gcm.message_id": @"second-id", @"click_url": [self URL:@"/push-b"].absoluteString};
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"second-id" content:content trigger:nil];
    NSObject *response = [self responseForRequest:request];
    [app userNotificationCenter:nil didReceiveNotificationResponse:(id)response withCompletionHandler:^{}];
    [self drainMainQueue];
    XCTAssertEqualObjects(opened.path, @"/push-b");
    XCTAssertEqual(vc.routingGeneration, 1u);
}
- (id)responseForRequest:(UNNotificationRequest *)request {
    TestNotification *notification = [TestNotification new];
    notification.request = request;
    TestResponse *response = [TestResponse new];
    response.actionIdentifier = UNNotificationDefaultActionIdentifier;
    response.notification = notification;
    return response;
}
- (void)testFiftyRedirectsPreserveQueryAndCookies {
    WebViewController *vc = [self showWebView:@"/?case=redirect50"];
    [self waitForWebView:vc path:@"/"];
    WKWebView *web = [vc valueForKey:@"webView"];
    [web evaluateJavaScript:@"document.getElementById('redirectBtn').click()" completionHandler:nil];
    [self waitForWebView:vc path:@"/final"];
    XCTAssertEqualObjects(web.URL.query, @"case=redirect50");
    XCTestExpectation *cookie = [self expectationWithDescription:@"redirect cookie survived"];
    [web evaluateJavaScript:@"document.body.textContent" completionHandler:^(id result, NSError *error) {
        XCTAssertNil(error);
        XCTAssertTrue([result containsString:@"chain=retained"]);
        [cookie fulfill];
    }];
    [self waitForExpectations:@[cookie] timeout:3];
}
- (void)testSkipRedirectButton {
    WebViewController *vc = [self showWebView:@"/?case=skip"];
    [self waitForWebView:vc path:@"/"];
    WKWebView *web = [vc valueForKey:@"webView"];
    [web evaluateJavaScript:@"document.getElementById('skipBtn').click()" completionHandler:nil];
    [self waitForWebView:vc path:@"/final"];
    XCTAssertEqualObjects(web.URL.query, @"case=skip");
}
- (void)testTooManyRedirectsDoesNotReplayPOST {
    WebViewController *vc = [self showWebView:@"/a"];
    [self waitForWebView:vc path:@"/a"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self URL:@"/payment"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [@"amount=1" dataUsingEncoding:NSUTF8StringEncoding];
    [vc setValue:request forKey:@"mainFrameRequest"];
    WKNavigation *navigation = [vc valueForKey:@"activeNavigation"];
    [vc webView:[vc valueForKey:@"webView"] didFailProvisionalNavigation:navigation
        withError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorHTTPTooManyRedirects
            userInfo:@{NSURLErrorFailingURLErrorKey: [self URL:@"/payment"]}]];
    [self drainMainQueue];
    XCTAssertEqual(navigation, [vc valueForKey:@"activeNavigation"]);
    XCTAssertEqual([[vc valueForKey:@"resumedRedirectURLs"] count], 0u);
}
- (void)testNewPushCancelsQueuedRedirectContinuation {
    WebViewController *vc = [self showWebView:@"/a"];
    [self waitForWebView:vc path:@"/a"];
    WKWebView *web = [vc valueForKey:@"webView"];
    WKNavigation *old = [vc valueForKey:@"activeNavigation"];
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorHTTPTooManyRedirects
        userInfo:@{NSURLErrorFailingURLErrorKey: [self URL:@"/redirect/21"]}];
    [vc webView:web didFailProvisionalNavigation:old withError:error];
    [vc navigateToURL:[self URL:@"/push-b"]];
    [self drainMainQueue];
    [self waitForWebView:vc path:@"/push-b"];
}
- (void)testRepeatedPushReusesWebViewAndRecoveryDoesNotRestoreOldURL {
    WebViewController *vc = [self showWebView:@"/a"];
    [self waitForWebView:vc path:@"/a"];
    WKWebView *web = [vc valueForKey:@"webView"];
    [vc webViewWebContentProcessDidTerminate:web];
    [vc navigateToURL:[self URL:@"/push-b"]];
    XCTestExpectation *delay = [self expectationWithDescription:@"recovery delay elapsed"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [delay fulfill]; });
    [self waitForExpectations:@[delay] timeout:3];
    [self waitForWebView:vc path:@"/push-b"];
    XCTAssertEqual(web, [vc valueForKey:@"webView"]);
}
- (void)testFirstLoadNetworkFailureShowsErrorInsteadOfBlackScreen {
    WebViewController *vc = [self showWebView:@"/disconnect"];
    NSPredicate *failed = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return [[vc valueForKey:@"displayingLoadError"] boolValue];
    }];
    XCTNSPredicateExpectation *shown = [[XCTNSPredicateExpectation alloc] initWithPredicate:failed object:nil];
    [self waitForExpectations:@[shown] timeout:30]; // allow a cold WebKit process on CI
    XCTAssertFalse([[vc valueForKey:@"loadStatusView"] isHidden]);
    XCTAssertFalse([[vc valueForKey:@"retryButton"] isHidden]);
    XCTAssertEqualObjects([[vc valueForKey:@"retryRequest"] URL].path, @"/disconnect");
}
- (void)testRetryKeepsClickedURLAndNewPushInvalidatesOldErrorActions {
    WebViewController *vc = [self showWebView:@"/a"];
    [self waitForWebView:vc path:@"/a"];
    WKWebView *web = [vc valueForKey:@"webView"];
    [vc navigateToURL:[self URL:@"/777"]];
    [web stopLoading];
    WKNavigation *failed = [vc valueForKey:@"activeNavigation"];
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil];
    [vc webView:web didFailProvisionalNavigation:failed withError:error];
    XCTAssertTrue([[vc valueForKey:@"displayingLoadError"] boolValue]);
    [vc pl_retryLoading];
    XCTAssertEqualObjects([[vc valueForKey:@"mainFrameRequest"] URL].path, @"/777");
    [self waitForWebView:vc path:@"/777"];
    XCTAssertTrue([[vc valueForKey:@"loadStatusView"] isHidden]);
    [vc navigateToURL:[self URL:@"/new-push"]];
    WKNavigation *latest = [vc valueForKey:@"activeNavigation"];
    [vc webView:web didFailNavigation:failed withError:error];
    [vc webView:web didFailProvisionalNavigation:failed withError:error];
    [vc webView:web didFinishNavigation:failed];
    [vc pl_retryLoading]; // stale UI action cannot replay 777
    XCTAssertEqual([vc valueForKey:@"activeNavigation"], latest);
    XCTAssertFalse([[vc valueForKey:@"displayingLoadError"] boolValue]);
    XCTAssertFalse([[vc valueForKey:@"loadStatusView"] isHidden]);
    [self waitForWebView:vc path:@"/new-push"];
}
- (void)testLoadingDeadlineCannotStopNewerPushOrCompletedPage {
    WebViewController *vc = [self showWebView:@"/a"];
    NSUInteger old = [[vc valueForKey:@"loadStatusGeneration"] unsignedIntegerValue];
    [vc navigateToURL:[self URL:@"/777"]];
    WKNavigation *current = [vc valueForKey:@"activeNavigation"];
    [vc pl_loadingDeadlineExpired:old];
    XCTAssertEqual([vc valueForKey:@"activeNavigation"], current);
    XCTAssertFalse([[vc valueForKey:@"displayingLoadError"] boolValue]);
    NSUInteger pending = [[vc valueForKey:@"loadStatusGeneration"] unsignedIntegerValue];
    [self waitForWebView:vc path:@"/777"];
    [vc pl_loadingDeadlineExpired:pending];
    XCTAssertTrue([[vc valueForKey:@"loadStatusView"] isHidden]);
}
- (void)testLoadingDeadlineShowsRetryForCurrentDestination {
    WebViewController *vc = [self showWebView:@"/777"];
    [vc pl_loadingDeadlineExpired:[[vc valueForKey:@"loadStatusGeneration"] unsignedIntegerValue]];
    XCTAssertTrue([[vc valueForKey:@"displayingLoadError"] boolValue]);
    XCTAssertNil([vc valueForKey:@"activeNavigation"]);
    XCTAssertFalse([[vc valueForKey:@"retryButton"] isHidden]);
    [vc pl_retryLoading];
    [self waitForWebView:vc path:@"/777"];
}
- (void)testPOSTFailureDisablesRetryAndAutomaticProcessRecovery {
    WebViewController *vc = [self showWebView:@"/a"];
    [self waitForWebView:vc path:@"/a"];
    NSMutableURLRequest *post = [NSMutableURLRequest requestWithURL:[self URL:@"/payment"]];
    post.HTTPMethod = @"POST";
    post.HTTPBody = [@"amount=1" dataUsingEncoding:NSUTF8StringEncoding];
    [vc setValue:post forKey:@"mainFrameRequest"];
    [vc setValue:post forKey:@"retryRequest"];
    WKNavigation *navigation = [vc valueForKey:@"activeNavigation"];
    [vc webViewWebContentProcessDidTerminate:[vc valueForKey:@"webView"]];
    [vc pl_retryLoading];
    [self drainMainQueue];
    XCTAssertTrue([[vc valueForKey:@"displayingLoadError"] boolValue]);
    XCTAssertTrue([[vc valueForKey:@"retryButton"] isHidden]);
    XCTAssertEqual(navigation, [vc valueForKey:@"activeNavigation"]);
    XCTAssertEqual([[vc valueForKey:@"processRecoveryCount"] unsignedIntegerValue], 0u);
}
- (void)testRepeatedProcessFailureCancelsAlreadyQueuedRecovery {
    WebViewController *vc = [self showWebView:@"/a"];
    [self waitForWebView:vc path:@"/a"];
    WKWebView *web = [vc valueForKey:@"webView"];
    WKNavigation *navigation = [vc valueForKey:@"activeNavigation"];
    [vc webViewWebContentProcessDidTerminate:web];
    [vc webViewWebContentProcessDidTerminate:web];
    XCTestExpectation *delay = [self expectationWithDescription:@"recovery delay elapsed"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [delay fulfill]; });
    [self waitForExpectations:@[delay] timeout:3];
    XCTAssertEqual(navigation, [vc valueForKey:@"activeNavigation"]);
    XCTAssertTrue([[vc valueForKey:@"displayingLoadError"] boolValue]);
}
- (void)testDiagnosticReportRedactsURLsAndErrorDescriptions {
    NSURL *secretURL = [NSURL URLWithString:@"https://private-user:private-password@example.com/push/token/path-secret?token=query-secret&next=https%3A%2F%2Fsecret.example#fragment-secret"];
    WebViewController *vc = [[WebViewController alloc] initWithURL:secretURL];
    NSError *underlying = [NSError errorWithDomain:@"kCFErrorDomainCFNetwork" code:-1001 userInfo:nil];
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:-1001 userInfo:@{
        NSURLErrorFailingURLErrorKey: secretURL, NSUnderlyingErrorKey: underlying,
        NSLocalizedDescriptionKey: @"private-description", @"private-payload": @"private-value"}];
    NSString *report = [vc pl_diagnosticReportForError:error source:@"test failure"];
    for (NSString *secret in @[@"private-user", @"private-password", @"path-secret", @"query-secret", @"secret.example", @"fragment-secret", @"private-description", @"private-value"])
        XCTAssertFalse([report containsString:secret], @"Leaked %@", secret);
    XCTAssertTrue([report containsString:@"https://example.com/push/token/<hidden>?token=<hidden>&next=<hidden>"]);
    XCTAssertTrue([report containsString:@"NSURLErrorDomain -1001 <- kCFErrorDomainCFNetwork -1001"]);
    XCTAssertTrue([report containsString:@"[id="]);
}
- (void)testDiagnosticIdentityDistinguishesHiddenQueryValues {
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:-1001 userInfo:nil];
    WebViewController *first = [[WebViewController alloc] initWithURL:[NSURL URLWithString:@"https://example.com/push?token=first-secret"]];
    NSString *a = [first pl_diagnosticReportForError:error source:@"test"];
    NSString *b = [first pl_diagnosticReportForError:error source:@"test"];
    WebViewController *second = [[WebViewController alloc] initWithURL:[NSURL URLWithString:@"https://example.com/push?token=second-secret"]];
    NSString *c = [second pl_diagnosticReportForError:error source:@"test"];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"id=([a-f0-9]{12})" options:0 error:nil];
    NSString *(^identity)(NSString *) = ^NSString *(NSString *text) {
        NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        return match ? [text substringWithRange:[match rangeAtIndex:1]] : nil;
    };
    XCTAssertNotNil(identity(a));
    XCTAssertEqualObjects(identity(a), identity(b));
    XCTAssertNotEqualObjects(identity(a), identity(c));
    XCTAssertFalse([a containsString:@"first-secret"]);
    XCTAssertFalse([c containsString:@"second-secret"]);
}
- (void)testDiagnosticTimelineIsBoundedAndNewRouteClearsOldData {
    WebViewController *vc = [[WebViewController alloc] initWithURL:[self URL:@"/old-push"]];
    for (NSUInteger i = 0; i < 75; i++) [vc pl_recordDiagnostic:[NSString stringWithFormat:@"event-%lu", (unsigned long)i] URL:nil];
    XCTAssertEqual([[vc valueForKey:@"diagnosticEvents"] count], 40u);
    [vc navigateToURL:[self URL:@"/777"]]; // does not load a view or send a request
    NSString *report = [vc pl_diagnosticReportForError:[NSError errorWithDomain:NSURLErrorDomain code:-1001 userInfo:nil] source:@"test"];
    XCTAssertFalse([report containsString:@"old-push"]);
    XCTAssertFalse([report containsString:@"event-74"]);
    XCTAssertTrue([report containsString:@"/777"]);
    XCTAssertFalse(vc.isViewLoaded);
}
- (void)testDiagnosticScreenDistinguishesUIAndWebKitTimeoutAndCopiesSnapshot {
    WebViewController *vc = [self showWebView:@"/777"];
    [vc pl_loadingDeadlineExpired:[[vc valueForKey:@"loadStatusGeneration"] unsignedIntegerValue]];
    NSString *uiReport = [vc valueForKey:@"diagnosticReport"];
    XCTAssertTrue([uiReport containsString:@"Source: app UI deadline"]);
    UITextView *text = [vc valueForKey:@"diagnosticTextView"];
    XCTAssertFalse(text.hidden);
    XCTAssertFalse(text.editable);
    XCTAssertTrue(text.selectable);
    XCTAssertEqualObjects(text.text, uiReport);
    [vc pl_copyDiagnostics];
    XCTAssertEqualObjects(UIPasteboard.generalPasteboard.string, uiReport);
    [vc navigateToURL:[self URL:@"/new-push"]];
    XCTAssertTrue(text.hidden);
    XCTAssertTrue([[vc valueForKey:@"copyDiagnosticButton"] isHidden]);
    XCTAssertNil([vc valueForKey:@"diagnosticReport"]);
    WKWebView *web = [vc valueForKey:@"webView"];
    [web stopLoading];
    [vc webView:web didFailProvisionalNavigation:[vc valueForKey:@"activeNavigation"]
        withError:[NSError errorWithDomain:NSURLErrorDomain code:-1001 userInfo:nil]];
    NSString *networkReport = [vc valueForKey:@"diagnosticReport"];
    XCTAssertTrue([networkReport containsString:@"Source: WebKit didFailProvisionalNavigation"]);
    // WebView.URL may legitimately still describe the previously displayed
    // page; retain that evidence, but never retain its route/timeline as current.
    XCTAssertEqualObjects([[vc valueForKey:@"diagnosticRouteURL"] path], @"/new-push");
    XCTAssertFalse([[[vc valueForKey:@"diagnosticEvents"] componentsJoinedByString:@"\n"] containsString:@"/777"]);
    XCTAssertTrue([networkReport containsString:@"/new-push"]);
    [vc pl_copyDiagnostics];
    XCTAssertEqualObjects(UIPasteboard.generalPasteboard.string, networkReport);
}
- (void)testDiagnosticResponseObservationPreservesDefaultMIMEPolicy {
    WebViewController *vc = [[WebViewController alloc] initWithURL:[self URL:@"/777"]];
    TestNavigationResponse *response = [TestNavigationResponse new];
    response.forMainFrame = YES;
    response.canShowMIMEType = YES;
    response.response = [[NSHTTPURLResponse alloc] initWithURL:[self URL:@"/final?token=hidden-response-token"] statusCode:503 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"text/html", @"Set-Cookie": @"private-cookie"}];
    __block NSUInteger decisions = 0;
    [vc webView:nil decidePolicyForNavigationResponse:(id)response decisionHandler:^(WKNavigationResponsePolicy policy) {
        decisions++; XCTAssertEqual(policy, WKNavigationResponsePolicyAllow);
    }];
    XCTAssertTrue([[vc valueForKey:@"diagnosticLastResponse"] containsString:@"HTTP 503"]);
    response.canShowMIMEType = NO;
    [vc webView:nil decidePolicyForNavigationResponse:(id)response decisionHandler:^(WKNavigationResponsePolicy policy) {
        decisions++; XCTAssertEqual(policy, WKNavigationResponsePolicyCancel);
    }];
    XCTAssertEqual(decisions, 2u);
    NSString *report = [vc pl_diagnosticReportForError:[NSError errorWithDomain:NSURLErrorDomain code:-1001 userInfo:nil] source:@"test"];
    XCTAssertFalse([report containsString:@"private-cookie"]);
    XCTAssertFalse([report containsString:@"hidden-response-token"]);
}
@end
