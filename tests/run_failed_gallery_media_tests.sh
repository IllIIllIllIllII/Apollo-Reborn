#!/bin/sh

set -eu

# Builds the real failed-gallery repair as a macOS executable with a fake resolver.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-failed-gallery-tests.XXXXXX")
test_binary="$test_build_dir/failed_gallery_media_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -framework ImageIO -DAPOLLO_FAILED_GALLERY_TESTING \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloFailedGalleryMedia.m" \
    "$test_repo_root/tests/failed_gallery_media_tests.m" \
    -o "$test_binary"

"$test_binary"
