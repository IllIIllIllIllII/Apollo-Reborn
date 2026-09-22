# iPhone Duo implementation and validation

This branch adapts Apollo to the Duo simulator's cover, open portrait, and
landscape displays. UIKit owns the tab rail and split-column frames. The tweak
keeps Apollo's existing navigation controllers as routing entry points.

## Behavior and scope

| Change | Scope | Implementation |
| --- | --- | --- |
| Sidebar/detail navigation | Duo, unfolded landscape | `ApolloDuoSplitView` places a native `UISplitViewController` inside a plain containment host in the original tab navigation stack. Posts, Inbox, Account, Search, and Settings use separate primary/detail stacks. |
| Fold and portrait transitions | Duo | Restore the original Apollo navigation stack when the split closes. Open portrait stays one column with UIKit's bottom tab bar. The cover and landscape use UIKit's native trailing rail. |
| Sidebar width | Duo landscape | A partial fold uses half the display; fully open uses a narrower sidebar. The hinge interaction and scene geometry drive updates. |
| Feed widths, index placement, action pills, and empty states | Duo | Measure the visible content column and native rail. Do not apply another manual column frame or duplicate the rail's safe-area inset. |
| Search below titles and comment-count title | Duo unfolded | Keep native search in the stacked placement while preserving the title. |
| App Icon pack columns | Duo | Four columns in the wide landscape content area; two columns in portrait and when the sidebar narrows the content. Persistent section cells animate their geometry without a snapshot crossfade. |
| Account tab hold | Liquid Glass, all phones | A hold opens Accounts without selecting Account; a tap still selects the tab. Native button recognizers handle horizontal tabs; a bounded touch observer handles the Duo rail. |
| Subreddit title and switcher | Apollo-wide | Remove the title chevron. Tapping opens a centered native sheet with search focused and a height based on its content. Selection goes through Apollo's native search data source. |
| Subreddit headers/highlights | Apollo-wide | Discard the previous community's header and highlights when the feed changes. |
| Daily Spotlight | Apollo-wide | Six icons. Resize the edge fade with its scroll view. |
| Profile statistic widths | Duo only | Align with the shortcut rows; preserve the original capped layout elsewhere. |
| Device identity and island geometry | Newer iPhones | Map unknown phone identifiers to Apollo's recognized device models. Measure any island against the window's own screen. Pixel Pals stay disabled on Duo. |
| Floating tabs and media chrome | Scene-aware on all devices | Bind overlays to the app's scene and use safe areas plus extra layout margins. |

`ApolloDuoRailCore.m` contains native-rail measurements and content helpers.
It does not create a second tab rail. The retired frame-pinning split and
six-button custom rail are intentionally absent.

## Layout rules

- Size the app window to its assigned scene, including a multitasking scene.
  Never move it to another display merely because that display is larger.
- Coalesce scene/visibility callbacks and perform canvas correction outside
  `layoutSubviews`.
- Use weak references for links back from child controllers to split state.
- Refresh Texture measurements when the visible content width changes; UIKit
  may keep the backing table full-width beneath the primary column.
- Keep per-table work scoped to the relevant visible table. Layout callbacks
  from unrelated settings, sheets, and feeds must not trigger index repair.
- Do not call UIKit `reservedRegions` or `reservedRegionsForKind:options:`.
  These crashed during the Duo simulator's first layout commit. Media uses
  safe areas and layout margins; there is no active arbitrary-rectangle
  hinge-avoidance implementation.

## Build configuration

`patch.sh --liquid-glass` sets the guest Apollo binary's linked SDK to 27.1
(minimum OS remains 15.0). In the tested Duo runtime, older linked SDKs receive
a letterboxed phone canvas. This patch also affects Liquid Glass builds on
other devices, so it is part of the compatibility surface for release review.
Classic and icons-only binaries are unchanged.

Device tweak builds prefer a real `iPhoneOS27.1.sdk` in Theos or the selected
Xcode, and fall back to 26.0. `DEVELOPER_DIR` is respected. The device deployment
floor remains iOS 14. CI explicitly selects Xcode 26.0.1 and therefore uses the
26.0 fallback. An installed simulator runtime is not a device SDK.

Simulator builds use `TARGET=simulator:clang:latest:15.0`. Do not combine an old
simulator SDK with the current compiler. The simulator helper regenerates its
glass base if its SDK stamp predates 27.1 and strips embedded device-only tweak
libraries before inserting the simulator build.

## Validation

Use Device Hub for the GUI. Do not open Simulator.app for normal testing.
Use `xcrun simctl` for install, launch, logs, and screenshots. Dual-display
screenshots require selecting the correct display.

Host checks for the live geometry and classification helpers:

```sh
tests/run_device_identity_tests.sh
tests/run_device_display_tests.sh
tests/run_duo_compatibility_tests.sh
tests/run_duo_rail_layout_tests.sh
```

Run the simulator with the existing device/settings:

```sh
scripts/run-in-sim.sh --glass
```

Verify `apollofix` load messages before testing. Exercise:

- Cover, open portrait, full landscape, and partial-fold landscape transitions.
- Each tab's current detail through fold/unfold, including a scrolled Inbox.
- Account hold from another tab, dismissal without tab selection, and ordinary
  tap afterward. Hold elsewhere in content to check native context menus.
- Sidebar show/hide on App Icon; all four cards in both pack sections remain
  visible or reachable, and card taps open the matching pack.
- Subreddit switcher keyboard, filtering, selection, dismissal, and normal
  title brightness afterward.
- Theme changes and account changes with split navigation active.

## Known limitation

The native app-icon confirmation alert's dimming layer can remain portrait-width
on the unfolded simulator. That alert is presented by the system outside
Apollo's view hierarchy. This branch does not add a second app-side dimmer.
