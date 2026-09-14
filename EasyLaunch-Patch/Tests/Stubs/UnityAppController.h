#import <UIKit/UIKit.h>

// Deliberately has NO remote-notification methods: Unity compiles them out
// when UNITY_USES_REMOTE_NOTIFICATIONS=0. A super call must fail this test.
typedef NS_ENUM(NSInteger, UnityEngineLoadState) {
    kUnityEngineLoadStateMinimal = 0,
    kUnityEngineLoadStateCoreInitialized = 1,
    kUnityEngineLoadStateAppReady = 2
};
@interface UnityAppController : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic) UnityEngineLoadState engineLoadState;
- (void)initUnityWithScene:(UIWindowScene *)scene;
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options;
- (void)applicationDidBecomeActive:(UIApplication *)application;
- (void)applicationDidEnterBackground:(UIApplication *)application;
- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application;
@end
