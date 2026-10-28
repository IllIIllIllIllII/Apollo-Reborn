# Native post preview footer evidence

Static investigation, 2026-10-28. Target: Apollo 1.15.11 (285), arm64,
the locally patched simulator shell at `.sim/Payload/Apollo.app/Apollo`.
SHA-256: `5fbb818da40f4cc97ae968d768ccb4b79dbc569ff2eb2b316e6d259067789769`.
This hash identifies that local shell, not an unmodified distribution IPA.

Evidence is the cached `.sim/apollo-disassembly.txt`, the shipped class
metadata (`xcrun otool -ov`, cached as `.sim/apollo-objc-metadata.txt`), and
the corresponding `Headers/{ObjC,Swift}` class dumps. Addresses below are
unslid virtual addresses; subtract `0x100000000` for image-relative offsets.
No app relaunch or runtime constructor execution was performed for this audit.

## Constructors and guards

Both classes' Objective-C `init` and `initWithViewControllerBlock:didLoadBlock:`
implementations are fatal Swift initialization stubs. Do not call `new` or
either initializer. Allocate with `alloc`, then use the native Swift
initializing entry point with `swiftcall` and the allocated object in the
`swift_context` parameter (arm64 `x20`). Return ownership is consumed as an
initialized object, as in the native post preview constructor bridge.

| Class | Initializing entry | Arguments before context | ObjC `init` guard |
|---|---|---|---|
| `Apollo.PageDividerCellNode` | `0x100417edc` | `NSInteger pageNumber` (`x0`), `BOOL compact` (`x1`) | `0x1004184a0` |
| `Apollo.ThinSeparatorCellNode` | `0x1003aca34` | `CGFloat leftInset` (`d0`), `CGFloat rightInset` (`d1`) | `0x1003ad118` |

Suggested function pointer signatures:

```objc
typedef void * __attribute__((swiftcall)) (*PageDividerInit)(
    NSInteger pageNumber, BOOL compact,
    void * __attribute__((swift_context)) allocatedSelf);
typedef void * __attribute__((swiftcall)) (*ThinSeparatorInit)(
    CGFloat leftInset, CGFloat rightInset,
    void * __attribute__((swift_context)) allocatedSelf);
```

Guard the class's `init` IMP against the expected image-relative offset and
check the constructor bytes before using these version-specific addresses.
The first 16 bytes are:

| Entry | Bytes |
|---|---|
| Page divider `+0x417edc` | `ff 83 02 d1 fc 6f 04 a9 fa 67 05 a9 f8 5f 06 a9` |
| Thin separator `+0x3aca34` | `ff c3 02 d1 e9 23 04 6d fc 6f 05 a9 fa 67 06 a9` |

Page initialization stores `pageNumber` and `compact` at
`0x100417efc–0x100417f10`, creates `pageNumberTextNode`, then calls the
superclass initializer. Its real section-controller caller at
`0x10072b244–0x10072b288` allocates the class and supplies those exact
arguments. Thin initialization saves `d0`/`d1`, stores `leftInset` and
`rightInset` at `0x1003acab8–0x1003acacc`, and creates its child nodes.
The section-controller caller at `0x100178854–0x1001788c0` corroborates
argument order. Any ivar access must use runtime ivar offsets: the static
class dump's small offsets precede superclass layout relocation.

## Page ending preference and sample number

The exact preference is:

```objc
[[NSUserDefaults standardUserDefaults] boolForKey:@"ShowPageEndings"]
```

The Appearance row initializer at `0x1001f10c4` assigns the title
`Show Page Endings` (cstring `0x100a46b90`). Instructions
`0x1001f1138–0x1001f1154` construct the inline Swift string
`ShowPageEndings`, then call `standardUserDefaults` and `boolForKey:`.
Their selector references are `0x100c772f0` and `0x100c70e30`.
The setter at `0x1001f11a8` constructs the same key and jumps to
`0x1001f49f0`, which invokes `setBool:forKey:`.

Use **page number 2** for the first sample boundary. The feed loop at
`0x10059c228` appends a page-divider token after every 25th post when
the preference is enabled; `0x10059c454–0x10059c494` computes
`Int(zeroBasedPostIndex / 25) + 2`. The parser at
`0x1005bcb74–0x1005bcca0` transfers the token's number unchanged to
the section controller. The cell formats **`PAGE 2`**, not “End of Page 1”:
`0x100418184–0x1004181b0` appends the number to `PAGE `.

The native layout at `0x100418388` specifies height 28 for compact and
56 for large (`0x100418414–0x100418428`). Its theme method selects
12-point compact or 14-point large text at `0x100418164–0x100418174`.
These are evidence of native behavior, not values to duplicate in UIKit;
let the native node measure and render itself.

## Feed separators

The ordinary `thin-separator-token` (`0x100a4c3b0`) is mapped to
`ThinSeparatorSectionController(leftInset: 16, rightInset: 0)` at
`0x1005bc808–0x1005bc870`. The
`thin-separator-full-width-token` (`0x100a46fb0`) uses 0 and 0 at
`0x1005bc874–0x1005bc8f4`.

The main feed's builder selects the ordinary thin token for its compact
branch (`0x10059c4e0–0x10059c534`). Its large branch uses
`thick-separator-token` (`0x100a4c390`, constructed at
`0x10059c53c–0x10059c598`). Therefore a thin separator with invented
thickness is not an accurate substitute for a large post gap.

Remaining runtime checks: execute each guarded constructor with ARC ownership
bridging; measure/render both page modes and the compact separator in the
preview; verify theme changes and the live Show Page Endings switch. The
large-post thick-separator constructor was outside this focused audit.

Parent integration validation subsequently executed both guarded constructors:
large PAGE 2 measured 56 points, compact PAGE 2 measured 28 points, and the
compact separator measured one display pixel (1/3 point on the test device).
Show Page Endings inserted/removed the native divider live in both previews.
