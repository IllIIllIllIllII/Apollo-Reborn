#!/bin/sh
set -eu
navigation_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
navigation_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-subreddit.XXXXXX")
trap 'rm -rf -- "$navigation_build"' EXIT HUP INT TERM

# Execute the production routing helper and settings callback. The fixture
# doubles containment and preference storage, preserving object identities.
python3 - "$navigation_root" "$navigation_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
def extract(path, declaration):
    source = path.read_text()
    start = source.index(declaration)
    return source[start:source.index('\n}', start) + 2]
fixture = (root / 'tests/duo_subreddit_navigation_tests.m').read_text()
fixture = fixture.replace('// INCLUDE_PRODUCTION_ROUTING', '\n'.join(extract(
    root / 'src/ApolloDuoSplitView.xm', declaration) for declaration in [
        'static NSUInteger ApolloDuoPostsFeedPageCount(',
        'static UIViewController *ApolloDuoPostsCurrentFeed(',
        'UINavigationController *ApolloDuoSplitDetailNavigation(',
        'static BOOL ApolloDuoPostsCanRouteSubredditLink(',
        'static void ApolloDuoPostsOpenSubreddit(',
        'static BOOL ApolloDuoPostsRouteSubredditLink(']))
fixture = fixture.replace('// INCLUDE_PRODUCTION_SETTING', extract(
    root / 'src/settings/CustomAPIViewController.m', '- (ApolloSettingsSection *)buildSubredditsDuoNavigationSection'))
split = (root / 'src/ApolloDuoSplitView.xm').read_text()
a = split.index('    BOOL separateComments =')
b = split.index('    [state.host.viewIfLoaded setNeedsLayout];', a)
fixture = fixture.replace('// INCLUDE_PRODUCTION_STACK_MIGRATION', split[a:b])
startup = (root / 'src/Tweak.xm').read_text()
start = startup.index('    sDuoSubredditLinksInFeed = [standardDefaults')
end = startup.index('    // Value 1 belonged', start)
fixture = fixture.replace('// INCLUDE_PRODUCTION_PREFERENCE_LOAD', startup[start:end])
(build / 'duo_subreddit_navigation_tests.m').write_text(fixture)
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    "$navigation_build/duo_subreddit_navigation_tests.m" -o "$navigation_build/duo_subreddit_navigation_tests"
"$navigation_build/duo_subreddit_navigation_tests"
