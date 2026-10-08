#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-awards-parsing-tests.XXXXXX")
test_binary="$test_build_dir/awards_parsing_tests"
test_sdk=$(xcrun --sdk macosx --show-sdk-path)
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -lxml2 -I "$test_sdk/usr/include/libxml2" \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloAwardsParsing.m" \
    "$test_repo_root/tests/awards_parsing_tests.m" -o "$test_binary"

"$test_binary" "$test_repo_root/tests/fixtures/awards"
