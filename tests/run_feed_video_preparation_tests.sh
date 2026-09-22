#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
qa=$(mktemp -d /tmp/apollo-video-preparation.XXXXXX)
trap 'rm -rf "$qa"' EXIT
# Exercise the production preparation helper on the host with AVFoundation.
# The UI hooks are validated in Apollo; no duplicate scheduler implementation.
python3 - "$repo" "$qa" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1], 'src/ApolloFeedVideoScrolling.xm').read_text()
src=src[:src.index('// MARK: - Video cells draw asynchronously')]
src=src.replace('#import <UIKit/UIKit.h>', '')
src=src.replace('#import "ApolloCommon.h"', '#define ApolloLog(...) do {} while (0)\n#define ApolloLogDebug(...) do {} while (0)')
src=src.replace('#import "ApolloState.h"', '')
Path(sys.argv[2], 'Preparation.inc').write_text(src)
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wno-deprecated-declarations \
    -framework Foundation -framework AVFoundation -framework QuartzCore -framework CoreVideo -framework CoreMedia \
    -I "$qa" "$repo/tests/feed_video_preparation_tests.m" -o "$qa/test"
"$qa/test"
