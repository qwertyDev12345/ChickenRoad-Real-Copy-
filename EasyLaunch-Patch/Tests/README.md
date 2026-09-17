# Push and redirect regression checks

Run on a Mac with Xcode, an installed iOS Simulator, Python 3 and the `xcodeproj` Ruby gem:

```sh
gem install xcodeproj --no-document
IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 16' bash EasyLaunch-Patch/Tests/run_ios_tests.sh
```

The script creates a separate test project under `build/routing-tests`; it does not modify the Unity export or use production Firebase credentials. The local HTTP fixture uses port 18765. An available iPhone simulator is selected automatically; optionally override it with `IOS_TEST_DESTINATION`. XCTest results are retained as `.xcresult`. The patched GitHub Actions build now runs this suite before TestFlight upload and saves `easylaunch-routing-tests`; test failures block upload.

The suite compiles the actual CustomAppController, PreloadViewController, NotificationPromptViewController and WebViewController. Unity and the service wrapper are stubbed: it tests the UIKit/WebKit routing but cannot validate Firebase swizzling or real APNs delivery.

Coverage: a JavaScript button leading through 50 real HTTP 302s, query/cookie preservation, stale redirect and process recovery after a new push, no POST replay, repeated preload appearance, push replacement during permission completion, completion once only, APNs bytes forwarding, background/memory callbacks before Unity startup, and the missing Unity remote-notification superclass method.

Presentation regressions additionally exercise real UIKit modal dismissal with an inactive permission completion, readiness without a second delegate callback, Settings-return activation after the retry budget, a rejected presentation with no completion, ownership when another window is key, and replacement of a pending push without stale replay. OS activation and the permission response are simulated; these tests do not grant actual system permission.

The r3 regressions check explicit `click_url` precedence (root, then data, then aps), fallback to a valid `url` (same container order), whitespace, invalid values and image-only payloads. They also cover a push arriving during a full-screen native modal, selection exceeding the usual retry budget, latest-push replacement, and no document reload on return without a push. The modal is a UIKit stand-in, NOT an actual camera: successful image delivery to an HTML file input still requires an iPhone check. The actual 777 payload has not been supplied, so the parser change is not proof of the cause in the recording.

Device acceptance is still required on the newly built app:

1. Click the redirect button and reach `/final`; verify the skip button and Back.
2. Tap pushes A then B, in both orders and during loading. Check each clicked payload's URL, also when both pushes share the same URL.
3. Repeat from foreground, background and a terminated process.
4. Skip permission, expire the three-day cooldown, allow, then repeat the push checks.
   Also test a fresh install: Allow and Deny must both continue to WebView. With system permission previously denied, enable it in Settings, return to the app, and verify WebView opens. Capture the interval from the permission response to the visible page.
5. Switch to Unity mode and repeat background/foreground and push navigation.
6. On the file test, choose a camera image on the first attempt, cancel and retry, and choose an ordinary file. Repeat with a push received/tapped while a native picker is open. Verify no second WebView covers the picker; after it closes the latest requested destination should open in the original WebView.
7. Cold-start via 777, including offline and a connection dropped before any content appears. Loading must be visible; failure must show an error and safe manual retry. Retry must retain that push's URL, not the previous page/config URL. Then tap a newer push while an error/recovery is pending. Repeat on the actual production redirect URL: the local fixture cannot validate its server or JavaScript.

The r4 regressions cover notification responses before Unity/preload entry, latest early push transfer, interruption of config checks, stale startup callbacks, a push during the Unity fade, a real dropped first-load connection, same-target retry, stale failure/finish events, loading deadline ownership and POST/process-recovery safety. Permission completion ordering and the older redirect/modal regressions remain in the suite. The 45-second no-commit UI deadline is tested by invoking its production handler, not by waiting 45 seconds. This is not evidence that a valid page's own JavaScript cannot render black after content commits.

Identify the installed source by the launch log `routing revision 2026-09-17-r5-diag` and the build number. Presentation logs distinguish `WebView opening deferred`, `WebView still waiting` (URL retained), and `WebView destination delivered in owner window`. If the process still terminates, export the matching `.ips` (including Exception Type and Last Exception Backtrace/Triggered by Thread). A screen recording confirms the symptom but not the native exception or offending thread.

## On-screen diagnostic capture (r5)

This revision adds observation, NOT a confirmed fix for the production 777 timeout. It does not increase timeouts, clear cookies/storage, bypass TLS, request notification permission, or send diagnostic probes. The navigation-response observer preserves WebKit's default allow-if-displayable MIME policy.

1. Update to a build containing r5 with `apply_patch=true`; do not reinstall/clear app data just to gather evidence.
2. Close the app and tap 777. On failure, the report must start with `EASYLAUNCH DIAG r5`.
3. Tap **Copy diagnostics** and send the entire text. Alternatively scroll the diagnostic panel and capture all parts. Copy BEFORE pressing Try again; then optionally send the retry's report too.
4. Label whether permission was allowed immediately or after Skip + the three-day cooldown, and whether this was a cold launch. Capture each failing scenario separately.

The report includes the native-vs-UI error source, nested error domain/codes, last stage, elapsed time, observed load/redirect counts, original route URL, current request, last redirect, WebView URL and error URL; app/scene visibility, HTTP response/MIME when observed, permission status, saved skip age (if still stored), build/commit/fingerprint and the last 40 callback events. `not observed` is not proof that the server received no request. The timeline is bounded and is not a packet trace; TLS/DNS timings and HTTP redirect response codes are not available here. URLs/identities can confirm replacement by another address, but do not expose hidden query values for replay.

Privacy: only allowlisted diagnostic fields are collected locally in memory. No automatic upload. Copy writes the report only after an explicit tap. URL credentials, ALL query values, fragments, non-HTTP URL contents and selected sensitive/long path segments are hidden; a short SHA-256 URL identity allows comparison even when query values differ. Hostnames and ordinary path segments remain visible and must be reviewed before sharing. NSError descriptions/userInfo dumps, cookies, headers, bodies, tokens and notification payloads are not included. The frozen report is replaced on the next error, and a new route clears the previous timeline/report.

The added native tests cover URL/description redaction, identity comparison, bounded/reset timelines, UI-vs-WebKit timeout distinction, report copying and response-policy preservation. These are still unexecuted in this Windows workspace; the Mac Actions gate must compile/run them. Check the scroll/copy UI on a small iPhone in portrait and landscape during device acceptance.

These iOS tests have not been executed in the Windows workspace. Local checks must not be reported as a successful device run.

## Export identity checks

`patch.sh` verifies that every native source/header (except the generated credentials config) matches the export before reporting success. It writes `EasyLaunchSourceCommit` and `EasyLaunchPatchSHA256` into the app's Info.plist. Actions also saves `easylaunch-build.json` as the `easylaunch-build-identity` artifact. The launch log prints both values. An old branch without these changes cannot provide this evidence.

Run portable tests with:

```sh
python3 -B -m unittest discover -s EasyLaunch-Patch/Tests -p 'test_*.py' -v
```

## Evidence from the September 14 device log (reported build 1 (8))

- At log times 12:50:13, 12:50:18 and 12:50:35, Cluckstep PID 1100 reports main-frame navigation error `-1007` (log lines 8454, 8469, 8499).
- At 12:50:06, UIKit rejects presentation of WebViewController on a PreloadViewController whose view is not in the window hierarchy (line 8371).
- At 12:55:43 Cluckstep has PID 1125. At 12:55:45 the scene is invalidated and the process no longer exists (lines 24529, 24573). The recording shows the system crash dialog.
- The supplied log contains Error/Fault messages, not a symbolicated crash stack or the informational EasyLaunch version marker. It does not establish which exception terminated the application.
- At the initial investigation, `git ls-remote` found GitHub main at `352ffeeb18c527884cffa45a4507e3fdbf21cda5` (August 31), before the September 14 fixes were committed. The exact Actions run/commit behind build 1 (8) was not retrieved.
- Subsequently, the supplied `easylaunch-build.json` identified commit `b52c75d4f0e73a775dcbed25a586242b1df5cc4c` and native fingerprint `3f4ea68a1ed54a903dbffa8b2d13f1fbc527568a9601d54dfb1ce2798c8706d3`. All 14 listed native files matched the local r1 sources. This confirms export identity, not an on-device pass. The r2 presentation changes require a new export and fingerprint.

Before retesting, publish the prepared changes to the intended build branch, run Actions with `apply_patch=true`, and retain the build identity artifact. Real APNs and the three-day permission flow still require a device acceptance run; use the matching `.ips` if the new binary terminates.
