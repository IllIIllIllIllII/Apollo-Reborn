# Duo Posts divider

On the flat inner display in landscape, a hairline in the theme's separator
color runs the full height between the feed and the thread. Hold anywhere along
it for 0.25 seconds, then drag horizontally. The feed and thread keep their
existing controllers and resize through UISplitViewController. Other tabs and
collapsed layouts keep their existing behavior. The feature is available
whenever both Posts panes are visible.

- The handle is a line the size of iOS's own multitasking grabber on the Duo
  (10 x 140 px at 3x). Until the divider has been resized once (a saved
  `DuoDividerFeedShare`), it shows at rest, dimmed, in the middle of the
  separator. After that nothing marks it at rest.
- Holding raises a Liquid Glass pill (6 points of glass around the line) at the
  finger's height. It follows the finger, stays two seconds after the columns
  settle, then fades. While it shows, a plain drag on it moves the divider
  without the hold. Tapping the separator raises it the same way.
- A hold counts within 12 points of the separator at any height, or on the
  handle's own 44 x 68 point target; a tap counts within the 12 points. There
  they win over the content's own taps and long presses; scrolls still scroll,
  and touches further away reach the content. The recognizers sit on the host
  view so they work while the handle is hidden.
- A visible handle keeps its taps, so tapping it never opens what's beneath.
  Double-tap the visible handle to restore 50/50. VoiceOver activation
  deliberately does not, so a double-tap can't discard the saved width; use
  Equal Widths instead.
- Grab, reaching either width limit, and release each give one light impact.
  Moving gives none. Moving at least 6 points back into the range rearms an
  edge; starting at an edge doesn't repeat it.
- A release within 6 points of a legal 1/3, 40%, 50%, or 60% position snaps
  there. Other releases retain their exact position. Both columns retain at
  least 320 points of usable width, including the thread's trailing rail
  reservation.
- Only successful releases persist `DuoDividerFeedShare`. The active fold takes
  precedence; returning flat restores the saved ratio. Interruption cancels and
  restores the saved geometry without a release haptic.
- VoiceOver exposes adjustable width and an Equal Widths action.

`ApolloDuoSplitDivider` owns its recognizers, separator and temporary views. It
does not inspect or disable UIKit's private resize/context-menu recognizers. A
display link coalesces touch samples and checks whether a fold, navigation,
presentation, or geometry change has invalidated the drag. Each column reflow
holds the main thread, so the handle glides on the render server between touch
bursts. Host layout positions the handle and separator; column-width writes
happen from the gesture/display-link path.

Validation:

- `tests/run_duo_divider_geometry_tests.sh`: bounds, arbitrary widths, valid snap
  targets and width-limit latching, with ASan/UBSan.
- Simulator and iOS 26 SDK device package builds.
- Apollo-Sim-Duo: hold and tap along the separator, plain drag on the raised
  pill, taps away from the separator reaching the content, scrolls starting on
  it, the first-run handle hiding after the first resize, and cancellation
  while folding.
- Physical iPhone Duo: haptics, hold and tap feel, and continuous-drag
  performance.
