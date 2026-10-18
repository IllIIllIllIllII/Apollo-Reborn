#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-post-media-menu.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

# Compile the shipping selection, menu and commit behavior unchanged. UIKit
# storage/geometry and output effects are doubled by the host harness; original
# media URL classification and GIF metadata resolution use production code.
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'src/ApolloFeedAlbumMenus.xm').read_text()
def between(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin)]
context = between(source, '@interface ApolloFeedAlbumMenuContext', 'static char kApolloFeedAlbumMenuContext')
helpers = between(source, 'static UIView *ApolloFeedAlbumNodeView(', 'static void ApolloFeedAlbumResolve(')
menu = between(source, 'static UIAction *ApolloFeedAlbumAction(', '%hook _TtC6Apollo19PostCellActionTaker')
end = between(source, '- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willEndForConfiguration:',
              '- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willPerformPreviewAction')
end = end[end.index('    if (!context)'):].replace('%orig', 'QANativeEnd()')
commit = between(source, '- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willPerformPreviewAction', '\n%end')
commit = commit[commit.index('    if (!context)'):].replace('%orig', 'QANativeCommit()')
display = between(source, '- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willDisplayMenuForConfiguration:',
                  '- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willEndForConfiguration:')
display = display[display.index('    if (context'):].replace('%orig', 'QANativeDisplay()')
configure = between(source, '- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:',
                    '- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction previewForHighlightingMenuWithConfiguration:')
configure = configure[configure.index('    if (!context)'):configure.index('    UIContextMenuConfiguration *configuration = [UIContextMenuConfiguration')]
configure = configure.replace('%orig', 'nativeConfiguration()')
factory = between(source, '+ (instancetype)configurationWithIdentifier:', '\n%end')
factory = factory[factory.index('    ApolloFeedAlbumMenuContext *context'):]
factory = factory.replace('%orig(identifier, previewProvider, mediaActions)', 'QAOriginalConfiguration(identifier, previewProvider, mediaActions)')
factory = factory.replace('%orig', 'QAOriginalConfiguration(identifier, previewProvider, actionProvider)')
highlight = between(source, '- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction previewForHighlightingMenuWithConfiguration:', '// Apollo has no dismissal-preview callback.')
highlight = highlight[highlight.index('    if (!context)'):].replace('%orig', 'nil')
dismiss = between(source, '- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction previewForDismissingMenuWithConfiguration:', '- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willDisplayMenuForConfiguration:')
dismiss = dismiss[dismiss.index('    if (!context'):]
out.joinpath('PostMediaSelection.inc').write_text(context + helpers)
out.joinpath('PostMediaActions.inc').write_text(menu + '\nstatic void QAEndMenu(ApolloFeedAlbumMenuContext *context, id<UIContextMenuInteractionAnimating> animator) {\n' + end +
    '\nstatic void QACommit(ApolloFeedAlbumMenuContext *context, id<UIContextMenuInteractionAnimating> animator) {\n' + commit +
    '\nstatic void QADisplay(ApolloFeedAlbumMenuContext *context) {\n' + display +
    '\nstatic UIContextMenuConfiguration *QAConfigure(ApolloFeedAlbumMenuContext *context, UIContextMenuConfiguration *(^nativeConfiguration)(void)) {\n' + configure + '    return [UIContextMenuConfiguration new];\n}\n' +
    '\nstatic UIContextMenuConfiguration *QAFactory(id<NSCopying> identifier, UIContextMenuContentPreviewProvider previewProvider, UIContextMenuActionProvider actionProvider) {\n' + factory +
    '\nstatic UITargetedPreview *QAHighlight(ApolloFeedAlbumMenuContext *context) {\n' + highlight +
    '\nstatic UITargetedPreview *QADismiss(ApolloFeedAlbumMenuContext *context) {\n' + dismiss)
model = (root / 'src/ApolloSaveAllMediaItems.m').read_text()
out.joinpath('PostMediaItems.inc').write_text(between(model, '@implementation ApolloSaveAllMediaItem', 'static void ApolloAllDeliver('))
gif = (root / 'src/ApolloMediaAutoplay.m').read_text()
out.joinpath('PostMediaGIF.inc').write_text(between(gif, 'static BOOL ApolloURLStringMatchesEntrySource(', 'void ApolloRegisterInlineGIFNode('))
PY

xcrun --sdk macosx clang++ -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -framework CoreGraphics \
    -I "$test_build_dir" -I "$test_repo_root/src" \
    "$test_repo_root/tests/post_media_menu_tests.mm" \
    "$test_repo_root/src/ApolloMediaMetadata.m" -o "$test_build_dir/tests"
"$test_build_dir/tests"
