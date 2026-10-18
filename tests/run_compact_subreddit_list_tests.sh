#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_logos=${LOGOS:-${THEOS:-$HOME/theos}/bin/logos.pl}
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-compact-list.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

# Exercise the shipping header wrappers around the shipping Following remapper.
# UIKit/model acquisition are doubled; section translation and donor-header
# behavior are extracted, so hook ordering is part of the regression test.
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import re
import sys

root, output = map(Path, sys.argv[1:])
index = (root / 'src/ApolloSubredditIndexPolish.xm').read_text()
following = (root / 'src/ApolloFollowingSection.xm').read_text()
common = (root / 'src/ApolloCommon.h').read_text()
panel = (root / 'src/ApolloCompactSubredditPanel.xm').read_text()
autohide = (root / 'src/ApolloAutoHideTabBar.xm').read_text()
topbar = (root / 'src/ApolloTopBarScrollPresentation.m').read_text()

def function(source, name):
    match = re.search(r'^.*\b' + re.escape(name) + r'\([^;\n]*\) \{', source, re.M)
    if not match:
        raise SystemExit(f'Missing production function: {name}')
    return source[match.start():source.index('\n}', match.end()) + 2]

map_start = following.index('@interface ApolloFollowingEntry')
map_end = following.index('@end', following.index('@implementation ApolloFollowingMap')) + len('@end')
model = following[map_start:map_end]
constants = following[following.index('static const NSInteger kApolloNativeSectionFavorites'):following.index('// Section order tokens')]
helpers = '\n\n'.join(function(following, name) for name in (
    'ApolloFollowingNativeSectionForVisible', 'ApolloFollowingHiddenRowsForNative',
    'ApolloFollowingCollationSectionCollapsed', 'ApolloFollowingCanonicalTitle',
    'ApolloFollowingCanonicalTitleForVisibleSection'))

group = following.split('%hook RedditListViewController', 1)[1].split('%end', 1)[0]
methods = []
for signature in ('numberOfSectionsInTableView:', 'tableView:(UITableView *)tableView heightForHeaderInSection:',
                  'tableView:(UITableView *)tableView viewForHeaderInSection:', 'sectionIndexTitlesForTableView:',
                  'tableView:(UITableView *)tableView sectionForSectionIndexTitle:'):
    match = re.search(r'^- \([^\n]+\)' + re.escape(signature), group, re.M)
    if not match:
        raise SystemExit(f'Missing production Following method: {signature}')
    methods.append(group[match.start():group.index('\n}', match.end()) + 2])
hooks = '%group CompactListFollowingTests\n%hook RedditListViewController\n'
hooks += '\n\n'.join(methods) + '\n%end\n%end\n'
hooks += 'static void InstallFollowingHooks(void) { %init(CompactListFollowingTests); }\n'

compact = '\n'.join(re.findall(r'^static const CGFloat ApolloCompactList(?:RowMinimumHeight|VerticalPadding) = .*?;', index, re.M)) + '\n\n'
compact += function(common, 'ApolloSetMethodImplementation') + '\n\n'
compact += '\n\n'.join(function(index, name) for name in (
    'ApolloCompactListEnabledForDevice', 'ApolloSubredditIndexTrackHeader', 'ApolloSubredditIndexUsesCompactRows',
    'ApolloSubredditIndexFirstCompactCollationSection', 'ApolloSubredditIndexCompactSubredditsHeaderSection',
    'ApolloSubredditIndexHidesCompactHeader', 'ApolloSubredditIndexApplyCompactHeaderTitle',
    'ApolloSubredditIndexApplyCompactHeaderVisibility', 'ApolloSubredditIndexHeightForHeaderHook',
    'ApolloSubredditIndexViewForHeaderHook', 'ApolloSubredditIndexIndexTitlesHook',
    'ApolloSubredditIndexSectionForIndexTitleHook', 'ApolloSubredditIndexInstallCompactHeaderHooks',
    'ApolloSubredditIndexCellIsInFavoritesSection',
    'ApolloSubredditIndexControlHasFavoriteAction', 'ApolloSubredditIndexRestoreCompactStar',
    'ApolloSubredditIndexApplyCompactStar', 'ApolloMetaFeedWrappedRanges',
    'ApolloCompactListHeightForContent', 'ApolloMetaFeedRestoreCompactIcon', 'ApolloMetaFeedApplyCompactIcon',
    'ApolloSubredditIndexApplyDescriptionPreference'))

editing = '\n\n'.join((function(panel, 'CompactPanelForObject'),
                         function(panel, 'ApolloCompactSubredditPanelOwnsNavigation'),
                         function(topbar, 'ApolloSubredditListIsEditing')))
editing += '\n%group CompactListEditingTests\n'
for target, replacement in (('_TtC6Apollo24RedditListViewController', 'RedditListViewController'),
                            ('UINavigationController', 'UINavigationController')):
    # These groups contain precisely the three edit/reveal entry points. Run
    # their shipped bodies unchanged so precedence, %orig arguments and native
    # editing state are tested together rather than mirrored in test helpers.
    body = autohide.split('%hook ' + target + '\n', 1)[1].split('%end', 1)[0]
    editing += '%hook ' + replacement + '\n' + body + '\n%end\n'
editing += '%end\nstatic void InstallEditingHooks(void) { %init(CompactListEditingTests); }\n'

test = (root / 'tests/compact_subreddit_list_tests.m').read_text()
for token, replacement in (
    ('// INCLUDE_PRODUCTION_MODEL', constants + '\n' + model),
    ('// INCLUDE_PRODUCTION_FOLLOWING_HELPERS', helpers),
    ('// INCLUDE_PRODUCTION_FOLLOWING_HOOKS', hooks),
    ('// INCLUDE_PRODUCTION_COMPACT_HELPERS', compact),
    ('// INCLUDE_PRODUCTION_EDITING_HOOKS', editing)):
    test = test.replace(token, replacement)
(output / 'CompactSubredditList.xm').write_text(test)
PY

perl "$test_logos" -c generator=internal "$test_build_dir/CompactSubredditList.xm" > "$test_build_dir/CompactSubredditList.mm"
xcrun --sdk macosx clang++ -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    "$test_build_dir/CompactSubredditList.mm" -o "$test_build_dir/compact_subreddit_list_tests"
"$test_build_dir/compact_subreddit_list_tests"
# Negative control: prove the same production hooks detect the original
# inner-hook composition bug instead of accepting either installation order.
"$test_build_dir/compact_subreddit_list_tests" --inner-hook-control
