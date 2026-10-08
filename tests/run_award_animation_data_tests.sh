#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-award-animation-tests.XXXXXX")
test_binary="$test_build_dir/award_animation_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx swiftc -parse-as-library -warnings-as-errors \
    "$test_repo_root/src/ApolloAwardAnimationData.swift" \
    "$test_repo_root/tests/award_animation_data_tests.swift" -o "$test_binary"
"$test_binary" "$@"
