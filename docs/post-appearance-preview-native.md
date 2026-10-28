# Native post appearance previews

The previews host Apollo 1.15.11's actual `LargePostCellNode` and
`CompactPostCellNode`. The tweak supplies an `RDKLink` fixture and local images;
Apollo owns all post typography, assets, colors, insets, positions and sizing.
There is no hand-drawn post fallback.

## Native constructor evidence

REA/Ghidra analyzed the locally patched arm64 simulator executable (SHA-256
`fceee3fcf23f2474e4ba6b43bf92652b31ad3aee1b5d40064d45b30d1cf22eeb`).
This identifies that analysis input, not a distribution IPA; simulator packaging
and dylib load-command edits can change its hash without changing these entries.

The native PostSectionController factory at `0x10056248c` calls:

| Cell | Swift designated initializer | ObjC `init` anchor |
|---|---|---|
| LargePostCellNode | `0x100302488` | `0x100308558` |
| CompactPostCellNode | `0x1007dd384` | `0x1007e2cac` |

REA function dossier evidence:
`ev_0751de57559b06ded67a11367a1d8b8faa38cacf14238bfac4012384762ed7f2`.
The Ghidra pseudocode's inferred generic types are not a Swift ABI declaration;
register assignments were cross-checked against the arm64 call-site assembly.

The initializing ABI is `swiftcall(link, isOnProfile, inSpecificSubreddit,
isRead, isInModQueue, swift_context allocatedSelf)`: link in x0, flags in
x1–x4, self in x20. Native callers retain the link before passing it; the
initializers consume link/self and return the owned initialized object. The
preview uses ARC retained bridges and `CFBridgingRelease` accordingly. All
four flags are false, representing an unread mixed-feed post. In particular,
this preserves the native Always Show Usernames / Show Subreddit at Top rules.

The Objective-C `init` and `initWithViewControllerBlock:didLoadBlock:` methods
are Swift fatal-init stubs. They must never be called. Before invoking a private
Swift initializer, the implementation verifies the image-relative ObjC anchor
and the designated initializer's arm64 instruction prologue. Unsupported binary
layouts show an unavailable message while leaving appearance controls usable.

## Fixtures and layout

`RDKObjectBuilder.objectFromJSON:` builds normal image/text post models for
r/ApolloReborn and u/TheBean31415. The user-supplied photo is loaded from
`PostAppearancePreview.jpg`. A fictional community award uses the bundled
Apollo Reborn illustration and Apollo's real AwardsNode. Network image URLs
are cleared and local images supplied before nodes enter a view hierarchy;
post interactions are disabled. No live account or Reddit fetch is needed.

Texture's native `layoutThatFits:` receives the exact available preview width.
Its returned height sizes the container. Native child frames are never moved,
scaled or reconstructed. The compact text example exercises the self-post
thumbnail setting. The native compact separator and optional native page
ending are documented in `post-appearance-preview-footer-native.md`.

The existing native Appearance form owns every switch, slider and picker.
The single Appearance integration filters two destination screens without
renumbering Eureka's native sections. Refresh runs after native persistence and
notifications (including `com.christianselig.AppFontChanged`); width changes
remeasure existing nodes. The pin is outside the post's content.

## Validation

An isolated simulator bundle executes the guarded initializers, native form
controls and Texture measurement/rendering. Captures verify the rocket image,
large/compact nodes, subreddit and author positions, icon visibility, native
votes, title/flair changes, native award layout and PAGE 2. The test uses no
account backup. Native slider track callbacks and picker choices require their
actual native interaction paths; merely sending UISlider valueChanged does not
exercise ApolloDiscreteSlider's Swift callbacks.

The simulator build and device package both pass. The device build uses Xcode
26.0.1's genuine iOS 26.0 SDK with the iOS 14 deployment floor. The local copied
Theos SDK has incomplete FoundationModels/Translation Swift symbol stubs, so
validation explicitly overrides SYSROOT to Xcode's iPhoneOS26.0.sdk without
changing the repository's SDK pin or replacing the user's SDK installation.
On-device rendering remains a manual verification step; binary signature guards
protect against using the constructors in a different Apollo build.

Live checks also exercised all compact thumbnail-size choices (hidden, small,
medium, large), both thumbnail positions, both voting-button positions, and
native font-slider minimum/maximum callbacks. These use native action handlers;
the ignored simulator harness does not ship with the tweak.
