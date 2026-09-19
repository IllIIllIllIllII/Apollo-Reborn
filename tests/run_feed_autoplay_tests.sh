#!/bin/bash
set -euo pipefail
: "${SIM_UDID:?Set SIM_UDID to a booted iOS simulator}"
feed_repo=$(cd "$(dirname "$0")/.." && pwd)
feed_test_dir=$(mktemp -d /tmp/apollo-feed-tests.XXXXXX)
trap 'rm -rf "$feed_test_dir"' EXIT
mkdir -p "$feed_test_dir/FeedAutoplayTests.app"
perl "${THEOS:-$HOME/theos}/bin/logos.pl" -c generator=internal "$feed_repo/src/ApolloFeedAutoplay.xm" > "$feed_test_dir/FeedAutoplayCore.inc"
python3 - "$feed_test_dir" <<'PY'
from pathlib import Path
import plistlib, sys
Path(sys.argv[1], 'FeedAutoplayTests.app/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'app.apolloreborn.feed-autoplay-tests',
    'CFBundleExecutable': 'FeedAutoplayTests', 'CFBundleName': 'Feed Autoplay Tests',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
    'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '15.0',
    'LSRequiresIPhoneOS': True, 'UILaunchScreen': {},
}))
PY
xcrun --sdk iphonesimulator clang++ -fobjc-arc -fblocks -target arm64-apple-ios15.0-simulator \
    -framework UIKit -framework Foundation -framework AVFoundation -framework QuartzCore -framework CoreGraphics \
    -I "$feed_repo/src" -I "$feed_test_dir" "$feed_repo/tests/feed_autoplay_tests.mm" \
    -o "$feed_test_dir/FeedAutoplayTests.app/FeedAutoplayTests"
codesign -s - -f "$feed_test_dir/FeedAutoplayTests.app" >/dev/null
xcrun simctl terminate "$SIM_UDID" app.apolloreborn.feed-autoplay-tests >/dev/null 2>&1 || true
xcrun simctl install "$SIM_UDID" "$feed_test_dir/FeedAutoplayTests.app"
feed_container=$(xcrun simctl get_app_container "$SIM_UDID" app.apolloreborn.feed-autoplay-tests data)
rm -f "$feed_container/Documents/result.txt"
xcrun simctl launch "$SIM_UDID" app.apolloreborn.feed-autoplay-tests
for ((i=0; i<30; i++)); do
    if [[ -f "$feed_container/Documents/result.txt" ]]; then
        cat "$feed_container/Documents/result.txt"
        grep -q '^PASS:' "$feed_container/Documents/result.txt"
        exit $?
    fi
    sleep 1
done
echo 'Timed out waiting for feed autoplay tests' >&2
exit 1
