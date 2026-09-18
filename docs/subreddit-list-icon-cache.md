# Subreddit list ready-image cache

`ApolloSubredditListIconCache.xm` keeps the final native 28-point icon bitmaps in
a process-wide `NSCache` (1,500 entries / 16 MB). Returning to the list or
rebuilding rows applies a warm bitmap before `cellForRowAtIndexPath:` returns.
Keys include the row title, source URL, appearance, and display scale, but not
the account or index path. A changed URL is a cache miss.

Apollo already persists image downloads through PINRemoteImage. This cache adds
no requests or disk files. Cold loads, the native HEAD size check, and normal
PIN cache refreshes still run. A first visit, process restart, explicit clear,
or memory eviction can therefore still require an asynchronous icon load.

## Native path and interception

Verified against the supplied Apollo 1.15.11 binary:

- `sub_1006402dc` sets a placeholder before asking the image cache for an icon.
- `sub_10064093c` asks `cacheKeyForURL:processorKey:` and checks the PIN cache,
  performing a HEAD request on a miss.
- `sub_1006415b0` calls `downloadImageWithURL:completion:`. Its completion
  dispatches to the main queue even on cache hits.
- `sub_100641ad8` reads the result image, finds the cell by its captured index
  path, and renders a circular avatar with the native subreddit background.
- `sub_1007ad000` renders that avatar with a 28 × 28 `UIGraphicsImageRenderer`
  and `UIImage.drawInRect:`.

The implementation uses Objective-C method hooks, not these addresses. A row
configuration scope observes the requested URL. A successful PIN result tags
its source image; a narrowly scoped renderer observation carries that identity
to the resulting bitmap. The image-view assignment caches only a bitmap whose
URL matches the current row binding. This preserves the native crop, color,
and pixels without copying its Swift rendering implementation.

Late tagged images for a different URL are rejected. Placeholders never enter
the cache or replace a ready image. `prepareForReuse` clears the binding, and
configuration scopes prevent the previous row's binding affecting a new row.
Custom multireddit icons retain precedence regardless of hook order. Memory
warnings and **Clear Tweak Caches** clear the ready-image cache.

## Manual regression checks

Use `scripts/run-in-sim.sh` and Device Hub. Verify the `ListIconCache` hook-install
message in `apollofix` logs before testing. Simulator builds expose read-only
`ApolloSubredditListIconCacheDiagnostics()` counters for an injected QA probe.

1. Open Subreddits and let native icons load. Scroll to the bottom and back;
   cached icons should already be present when rows are configured.
2. Open All Posts and return; reload the list. Warm icons should not flash to
   placeholders. Include Favorites, Following, and reordered sections.
3. Switch between accounts with overlapping subscriptions. Shared rows should
   reuse their rendered icons. First-time communities can still load normally.
4. Hide and show subreddit icons through settings. The hidden state should
   remain hidden; reopening the list should reuse warm icons when enabled.
5. Verify custom multireddit art and expanded child rows separately.
6. Clear tweak caches, then reload. Cold rows should become warm again.
7. In a simulator probe, configure warm rows synchronously and compare PNG
   bytes with their settled images. Assign one row's tagged bitmap to another:
   the second row must keep its own image. Assign nil: keep the ready icon.
   Call `prepareForReuse`: the old binding must no longer enforce its image.

Local iOS 26.5 testing verified byte-identical warm images, top/bottom scrolling,
list reloads, hidden icons, explicit clearing/re-warming, nil-image retention,
and rejection of mismatched callbacks followed by successful cell reuse.
The test account has only one signed-in account, so a live two-account switch
remains a device/manual check.
