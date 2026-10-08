#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-awards-transport.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
source = (root / 'src/ApolloAwardsData.m').read_text()
web = (root / 'src/ApolloWebJSON.m').read_text()
marker = web[web.index('NSString *ApolloWebJSONAccountFromURL('):web.index('\nNSURL *ApolloWebJSONProbeURL(')]
interface = source[source.index('@interface ApolloAwardsRequest'):source.index('// Scheduling is main-thread-only')]
load = source[source.index('- (void)loadURL:'):source.index('- (void)complete:')]
scheduler = source[source.index('// Scheduling is main-thread-only'):source.index('@implementation ApolloAwardsRequest')]
scheduler += source[source.index('static void ApolloAwardsDrain(void) {'):source.index('__attribute__((constructor))')]
template = (root / 'tests/awards_transport_tests.m').read_text()
template = template.replace('// PRODUCTION_INTERFACE', interface).replace('// PRODUCTION_MARKER', marker).replace('// PRODUCTION_SCHEDULER', scheduler).replace('// PRODUCTION_LOAD', load)
(output / 'test.m').write_text(template)
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter -fsanitize=address,undefined \
    -framework Foundation -I"$test_repo_root/src" "$test_repo_root/src/ApolloAwardsStore.m" \
    "$test_repo_root/src/ApolloAwardsListing.m" "$test_build_dir/test.m" -o "$test_build_dir/test"
"$test_build_dir/test"
