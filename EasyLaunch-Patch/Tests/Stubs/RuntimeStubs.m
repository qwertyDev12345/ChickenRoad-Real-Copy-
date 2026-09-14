#import "UnityAppController.h"
#import "PLServicesWrapper.h"

@implementation UnityAppController
- (void)initUnityWithScene:(UIWindowScene *)scene { self.engineLoadState = kUnityEngineLoadStateAppReady; }
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
- (void)applicationDidBecomeActive:(UIApplication *)app {}
- (void)applicationDidEnterBackground:(UIApplication *)app {
    NSAssert(self.engineLoadState >= kUnityEngineLoadStateAppReady, @"UnityCancelTouches before startup");
}
- (void)applicationDidReceiveMemoryWarning:(UIApplication *)app {
    NSAssert(self.engineLoadState >= kUnityEngineLoadStateAppReady, @"UnityLowMemory before startup");
}
@end

NSData *PLTestAPNsToken;
NSNotificationName const PLFCMTokenDidUpdateNotification = @"PLFCMTokenDidUpdateNotification";
@implementation PLServicesWrapper
+ (void)configureFirebase:(void (^)(NSError *))completion { if (completion) completion(nil); }
+ (void)setAPNsDeviceToken:(NSData *)token { PLTestAPNsToken = token; }
+ (BOOL)isFirebaseConfigured { return YES; }
+ (NSString *)firebasePushToken { return nil; }
+ (NSString *)firebaseProjectId { return nil; }
+ (NSString *)appsFlyerDeviceId { return nil; }
+ (NSDictionary *)storedAppsFlyerConversionData { return nil; }
+ (void)clearStoredAppsFlyerConversionData {}
+ (void)startAppsFlyerWithDevKey:(NSString *)key appleAppId:(NSString *)appId gcdWaitTimeout:(NSTimeInterval)timeout completion:(PLAttributionBlock)completion { completion(nil, nil); }
+ (void)handleOpenURL:(NSURL *)url options:(NSDictionary *)options {}
+ (void)continueUserActivity:(NSUserActivity *)activity restorationHandler:(void (^)(NSArray *))handler {}
@end
