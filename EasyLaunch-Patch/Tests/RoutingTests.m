#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import <UserNotifications/UserNotifications.h>
#import "CustomAppController.h"
#import "PreloadViewController.h"
#import "WebViewController.h"

extern NSData *PLTestAPNsToken;
@interface CustomAppController (TestAccess)
+ (NSURL *)pl_pushURLFromUserInfo:(NSDictionary *)info;
- (void)application:(UIApplication *)app didReceiveRemoteNotification:(NSDictionary *)info fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completion;
- (void)application:(UIApplication *)app didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)token;
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)(void))completion;
@end
@interface PreloadViewController (TestAccess)
- (void)pl_finishWithURL:(NSURL *)url;
- (void)pl_checkAndAskNotificationsIfNeededWithCompletion:(void (^)(void))completion;
- (void)pl_step1_checkNetwork;
@end
@interface WebViewController (TestAccess)
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error;
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView;
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
@end
@implementation RoutingTests
- (void)setUp {
    [super setUp];
    for (NSString *key in @[@"PLLaunchMode", @"PLLastEndpointURLString", @"PLLastNotificationDeniedAt"])
        [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
}
- (void)tearDown {
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
    vc.pendingPushURL = [self URL:@"/push-a"];
    vc.pendingPushURL = [self URL:@"/push-b"];
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
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.userInfo = @{@"gcm.message_id": @"second-id", @"click_url": [self URL:@"/push-b"].absoluteString};
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"second-id" content:content trigger:nil];
    NSObject *response = [self responseForRequest:request];
    [app userNotificationCenter:nil didReceiveNotificationResponse:(id)response withCompletionHandler:^{}];
    [self drainMainQueue];
    XCTAssertEqualObjects(vc.pendingPushURL.path, @"/push-b");
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
@end
