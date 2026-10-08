#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-awards-store-tests.XXXXXX")
test_binary="$test_build_dir/awards_store_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -framework CoreFoundation -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloAwardsStore.m" \
    "$test_repo_root/tests/awards_store_tests.m" -o "$test_binary"

"$test_binary"
