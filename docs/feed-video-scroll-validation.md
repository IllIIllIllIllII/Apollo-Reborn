# Feed video scrolling follow-up (#1168)

## Cause and change

The original background pre-warm still called `ASVideoNode.constructPlayerItem`.
In Apollo's bundled AsyncDisplayKit (function offset `0xc2988`), that method
holds the node lock across AVPlayerItem initialization. Its URL branch creates
a new asset and writes it into `_asset`. Main-thread node getters can therefore
wait for the background construction, and URL-backed items lose the metadata
loaded on the original asset. A cancelled worker can also mutate a reused node.

Preparation now snapshots the composition/audio mix on main, asynchronously
loads playable/tracks/duration, and constructs the item and player from the
same asset without accessing the node on the worker. A distinct request token
is cancelled at preload exit, including same-asset reentry. Main-thread identity
checks precede attachment through Texture's existing setters/delegate.

A September 22 simulator sample also traces first playback from
`ASTableView.scrollViewDidScroll:` through LargePostCellNode's visibility callback
to `ASVideoNode.play`, `ASDisplayNode.addSubnode:`, and AVPlayerLayer creation.
RichMediaNode preload separately creates AVURLAsset and its resource loader on
main. Moving only AVPlayer construction does not remove those paths.

While Smoother Video Scrolling is on, new feed setup and playback requests
leave the scroll callback and wait for a short 120 ms dwell in their required
range. They can then start **while tracking, dragging or decelerating**. A shared
admission interval spaces setup/play operations by at least 100 ms during motion
and 16 ms at rest. Stopping removes the dwell requirement. Request identity
survives the callback reentry so motion does not defer the admitted work again.

Native pause/exit cancels pending playback; state checks reject late work after
the node leaves its range. Existing playback continues. The owning feed cell is
found through supernodes (including crossposts), and its `scrollView` weak getter
is used without loading cell views. Comments/fullscreen nodes are outside this
feed gate. No single-player policy, bitrate cap, or autoplay preference change
is introduced.

This replaces the previous wait-until-settled policy, which the user confirmed
removed stuttering but delayed new playback. Pacing limits bursts; it does not
make native AVURLAsset/resource-loader or AVPlayerLayer setup asynchronous, or
bound the duration of an individual setup. Equal physical-device smoothness is
not established by the host harness or a successful build.

## Validation

- Paced-start revision: host harness, simulator build and device dylib build
  pass; simulator launch passes.
  Hook installation and background preparation confirmed in the new process;
  r/mariokartworld feed playback reports approximately 30 observer ticks/s.
  Simulator paging does not establish continuous finger-drag performance.

- `tests/run_feed_video_preparation_tests.sh`: exercises the production helpers
  with deterministic metadata completions, mock scroll state and a generated
  local video. Covers duplicate coalescing, cancellation, same-asset reentry,
  stale completion, node lifetime, native failure guards, real AVPlayer creation,
  prepared-asset identity, starts during continuous dragging/deceleration,
  inter-start spacing, callback reentry, preload admission and exit, short
  dwell removal at rest, pause/exit cancellation,
  toggle-off, crosspost ancestry and comments scope.
- Previous wait-until-settled revision: simulator build and launch on iOS 27.0. Module installation confirmed in
  `apollofix` logs. On r/mariokartworld, multiple feed videos play at approximately
  30 observer ticks/s, a playing feed video opens fullscreen, and playback returns
  to the feed. A comments-header video also plays.
- Device Hub accessibility paging was usable; direct automated drags sometimes
  behaved as taps or long presses. This run therefore does **not** establish an
  A/B dropped-frame improvement or fully validate physical drag/deceleration
  behavior inside Apollo. The scheduler's tracking/deceleration cases are covered
  by the host harness; physical-device acceptance remains necessary.

## Device acceptance

Use the test-branch IPA on a video-heavy feed with smoothing on, then off. Test
continuous finger dragging, repeated fast flicks and their deceleration tails,
reverse direction before stopping, and leave for comments/fullscreen while a
video is waiting. New videos should start during continuous dragging and deceleration after
a brief dwell; a video passed during the fling must not start later offscreen. Also check crossposts, GIFs, tap-to-play,
feed audio, fullscreen return and a long session. Compare Animation Hitches
traces on the same device/content; simulator wall-clock timings collected while
compilers or other workloads run are not a frame-rate benchmark.
