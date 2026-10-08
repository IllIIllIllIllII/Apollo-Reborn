#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-awards-giving-tests.XXXXXX")
test_sdk=$(xcrun --sdk macosx --show-sdk-path)
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
source = (root / 'src/ApolloAwardsGiving.m').read_text()
helper = source[source.index('static id ApolloAwardsGivingValue'):source.index('@interface ApolloAwardsGivingViewController')]
chooser = source[source.index('static NSString *ApolloAwardsGivingOpenChooserScript'):source.index('@implementation ApolloAwardsGivingViewController')]
test = (root / 'tests/awards_giving_target_tests.m').read_text()
(output / 'test.m').write_text(test.replace('// PRODUCTION_TARGET', helper).replace('// PRODUCTION_CHOOSER', chooser))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -fsanitize=address,undefined \
    -framework Foundation -framework JavaScriptCore -lxml2 -I "$test_sdk/usr/include/libxml2" -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloAwardsParsing.m" "$test_build_dir/test.m" -o "$test_build_dir/test"
"$test_build_dir/test" "$test_repo_root/tests/awards_giving_chooser_tests.js"
