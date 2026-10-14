#!/bin/bash
set -euo pipefail

icon_test_root=$(cd "$(dirname "$0")/.." && pwd)
icon_test_logos=${LOGOS:-${THEOS:-$HOME/theos}/bin/logos.pl}
if [[ ! -f "$icon_test_logos" ]]; then
    printf 'Logos not found at %s; set THEOS or LOGOS.\n' "$icon_test_logos" >&2
    exit 1
fi

# This is a standalone UIKit executable, not the Apollo app. It uses synthetic
# images and volatile defaults, so running it never accesses account data.
# Select an already booted device; do not launch either simulator GUI here.
icon_test_device=${SIM_DEVICE:-}
if [[ -z "$icon_test_device" ]]; then
    icon_test_device=$(xcrun simctl list devices booted -j | python3 -c '
import json, sys
devices = [d["udid"] for group in json.load(sys.stdin)["devices"].values()
           for d in group if d["state"] == "Booted"]
if len(devices) != 1:
    sys.exit("Set SIM_DEVICE to an already booted simulator UUID (expected exactly one booted device).")
print(devices[0])')
fi
icon_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-subreddit-list-icons.XXXXXX")
trap 'rm -rf -- "$icon_test_dir"' EXIT HUP INT TERM
icon_test_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)

perl "$icon_test_logos" -c generator=internal \
    "$icon_test_root/src/ApolloSubredditListIcons.xm" > "$icon_test_dir/ApolloSubredditListIcons.mm"
xcrun --sdk iphonesimulator clang++ -fobjc-arc -fblocks -std=c++17 \
    -target arm64-apple-ios15.0-simulator -isysroot "$icon_test_sdk" \
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function \
    -I "$icon_test_root/src" -framework Foundation -framework UIKit -framework CoreGraphics \
    "$icon_test_root/tests/subreddit_list_icon_tests.mm" \
    "$icon_test_dir/ApolloSubredditListIcons.mm" \
    -x objective-c++ "$icon_test_root/src/ApolloNativeSubredditIcons.m" \
    -o "$icon_test_dir/subreddit_list_icon_tests"
codesign --force --sign - "$icon_test_dir/subreddit_list_icon_tests" >/dev/null
xcrun simctl spawn "$icon_test_device" "$icon_test_dir/subreddit_list_icon_tests"
