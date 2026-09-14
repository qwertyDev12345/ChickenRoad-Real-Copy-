# Push and redirect regression checks

Run on a Mac with Xcode, an installed iOS Simulator, Python 3 and the `xcodeproj` Ruby gem:

```sh
gem install xcodeproj --no-document
IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 16' bash EasyLaunch-Patch/Tests/run_ios_tests.sh
```

The script creates a separate test project under `build/routing-tests`; it does not modify the Unity export or use production Firebase credentials. The local HTTP fixture uses port 18765. Choose an available simulator in `IOS_TEST_DESTINATION`. XCTest results are retained as `.xcresult`.

The suite compiles the actual CustomAppController, PreloadViewController, NotificationPromptViewController and WebViewController. Unity and the service wrapper are stubbed: it tests the UIKit/WebKit routing but cannot validate Firebase swizzling or real APNs delivery.

Coverage: a JavaScript button leading through 50 real HTTP 302s, query/cookie preservation, stale redirect and process recovery after a new push, no POST replay, repeated preload appearance, push replacement during permission completion, completion once only, APNs bytes forwarding, background/memory callbacks before Unity startup, and the missing Unity remote-notification superclass method.

Device acceptance is still required on the newly built app:

1. Click the redirect button and reach `/final`; verify the skip button and Back.
2. Tap pushes A then B, in both orders and during loading. Check each clicked payload's URL, also when both pushes share the same URL.
3. Repeat from foreground, background and a terminated process.
4. Skip permission, expire the three-day cooldown, allow, then repeat the push checks.
5. Switch to Unity mode and repeat background/foreground and push navigation.

Identify the installed source by the launch log `routing revision 2026-09-14-r1` and the build number. If the process still terminates, export the matching `.ips` (including Exception Type and Last Exception Backtrace/Triggered by Thread). A screen recording confirms the symptom but not the native exception or offending thread.

These iOS tests have not been executed in the Windows workspace. Local checks must not be reported as a successful device run.

## Export identity checks

`patch.sh` verifies that every native source/header (except the generated credentials config) matches the export before reporting success. It writes `EasyLaunchSourceCommit` and `EasyLaunchPatchSHA256` into the app's Info.plist. Actions also saves `easylaunch-build.json` as the `easylaunch-build-identity` artifact. The launch log prints both values. An old branch without these changes cannot provide this evidence.

Run portable tests with:

```sh
python3 -B -m unittest discover -s EasyLaunch-Patch/Tests -p test_verify_patch.py -v
```

## Evidence from the September 14 device log (reported build 1 (8))

- At log times 12:50:13, 12:50:18 and 12:50:35, Cluckstep PID 1100 reports main-frame navigation error `-1007` (log lines 8454, 8469, 8499).
- At 12:50:06, UIKit rejects presentation of WebViewController on a PreloadViewController whose view is not in the window hierarchy (line 8371).
- At 12:55:43 Cluckstep has PID 1125. At 12:55:45 the scene is invalidated and the process no longer exists (lines 24529, 24573). The recording shows the system crash dialog.
- The supplied log contains Error/Fault messages, not a symbolicated crash stack or the informational EasyLaunch version marker. It does not establish which exception terminated the application.
- A fresh `git ls-remote` check found GitHub main at `352ffeeb18c527884cffa45a4507e3fdbf21cda5` (August 31). The September 14 fixes remain uncommitted locally. A workflow run from that remote main cannot include them. The exact Actions run/commit behind build 1 (8) has not been retrieved.

Before retesting, publish the prepared changes to the intended build branch, run Actions with `apply_patch=true`, and retain the build identity artifact. Real APNs and the three-day permission flow still require a device acceptance run; use the matching `.ips` if the new binary terminates.
