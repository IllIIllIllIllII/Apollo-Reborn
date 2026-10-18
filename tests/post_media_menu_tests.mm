#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import "ApolloSwiftRuntime.h"
#import "ApolloSaveAllMediaItems.h"
#import "ApolloMediaMetadata.h"

// These doubles model only window membership, hierarchy, coordinate translation
// and action storage. No network request, clipboard write or Photos save occurs.
@interface UIView : NSObject
@property (nonatomic, strong) id window;
@property (nonatomic, weak) UIView *superview;
@property (nonatomic, strong) NSMutableArray<UIView *> *subviews;
@property (nonatomic, weak) id node;
@property (nonatomic) CGRect frame;
@property (nonatomic) BOOL hidden;
@property (nonatomic) CGFloat alpha;
@property (nonatomic, readonly) CGRect bounds;
- (void)addSubview:(UIView *)view;
- (BOOL)isDescendantOfView:(UIView *)view;
- (CGPoint)convertPoint:(CGPoint)point fromView:(UIView *)view;
- (id)asyncdisplaykit_node;
@end
@implementation UIView
- (instancetype)init { if ((self = [super init])) { _subviews = [NSMutableArray array]; _alpha = 1; } return self; }
- (CGRect)bounds { return CGRectMake(0, 0, _frame.size.width, _frame.size.height); }
- (void)addSubview:(UIView *)view { view.superview = self; view.window = self.window; [self.subviews addObject:view]; }
- (BOOL)isDescendantOfView:(UIView *)view { for (UIView *p = self; p; p = p.superview) if (p == view) return YES; return NO; }
- (CGPoint)convertPoint:(CGPoint)point fromView:(UIView *)view {
    for (UIView *p = view; p; p = p.superview) { point.x += p.frame.origin.x; point.y += p.frame.origin.y; }
    for (UIView *p = self; p; p = p.superview) { point.x -= p.frame.origin.x; point.y -= p.frame.origin.y; }
    return point;
}
- (id)asyncdisplaykit_node { return self.node; }
@end
@interface UIImage : NSObject
+ (instancetype)systemImageNamed:(NSString *)name;
@end
@implementation UIImage
+ (instancetype)systemImageNamed:(__unused NSString *)name { return [self new]; }
@end
@interface UIImageView : UIView
@property (nonatomic, strong) UIImage *image;
@end
@implementation UIImageView @end
@interface UIViewController : NSObject
@property (nonatomic, strong) UIView *view;
@property (nonatomic, readonly) UIView *viewIfLoaded;
@property (nonatomic, strong) UIViewController *presentedViewController;
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(dispatch_block_t)completion;
@end
@implementation UIViewController
- (UIView *)viewIfLoaded { return self.view; }
- (void)presentViewController:(UIViewController *)controller animated:(__unused BOOL)animated completion:(dispatch_block_t)completion {
    self.presentedViewController = controller;
    if (completion) completion();
}
@end
@interface QAPopover : NSObject
@property (nonatomic, strong) UIView *sourceView;
@property (nonatomic) CGRect sourceRect;
@end
@implementation QAPopover @end
@interface UIActivityViewController : UIViewController
@property (nonatomic, copy) NSArray *items;
@property (nonatomic, strong) QAPopover *popoverPresentationController;
- (instancetype)initWithActivityItems:(NSArray *)items applicationActivities:(NSArray *)activities;
@end
@implementation UIActivityViewController
- (instancetype)initWithActivityItems:(NSArray *)items applicationActivities:(__unused NSArray *)activities {
    if ((self = [super init])) { self.items = items; self.popoverPresentationController = [QAPopover new]; }
    return self;
}
@end
@interface UIPasteboard : NSObject
@property (nonatomic, strong) NSURL *URL;
+ (instancetype)generalPasteboard;
@end
@implementation UIPasteboard
+ (instancetype)generalPasteboard { static id board; if (!board) board = [self new]; return board; }
@end
@interface UIMenuElement : NSObject @end
@implementation UIMenuElement @end
@interface UIAction : UIMenuElement
@property (nonatomic, copy) NSString *title;
@property (nonatomic) NSUInteger attributes;
@property (nonatomic, copy) void (^handler)(UIAction *);
+ (instancetype)actionWithTitle:(NSString *)title image:(UIImage *)image identifier:(id)identifier handler:(void (^)(UIAction *))handler;
@end
@implementation UIAction
+ (instancetype)actionWithTitle:(NSString *)title image:(__unused UIImage *)image identifier:(__unused id)identifier handler:(void (^)(UIAction *))handler {
    UIAction *action = [self new]; action.title = title; action.handler = handler; return action;
}
@end
static const NSUInteger UIMenuElementAttributesDisabled = 1;
@interface UIDeferredMenuElement : UIMenuElement
@property (nonatomic, copy) void (^provider)(void (^)(NSArray<UIMenuElement *> *));
+ (instancetype)elementWithProvider:(void (^)(void (^)(NSArray<UIMenuElement *> *)))provider;
@end
@implementation UIDeferredMenuElement
+ (instancetype)elementWithProvider:(void (^)(void (^)(NSArray<UIMenuElement *> *)))provider { UIDeferredMenuElement *element = [self new]; element.provider = provider; return element; }
@end
@interface UIMenu : NSObject
@property (nonatomic, copy) NSArray<UIMenuElement *> *children;
+ (instancetype)menuWithTitle:(NSString *)title children:(NSArray *)children;
@end
@implementation UIMenu
+ (instancetype)menuWithTitle:(__unused NSString *)title children:(NSArray *)children { UIMenu *menu = [self new]; menu.children = children; return menu; }
@end
typedef UIViewController *(^UIContextMenuContentPreviewProvider)(void);
typedef UIMenu *(^UIContextMenuActionProvider)(NSArray<UIMenuElement *> *);
@interface UIContextMenuConfiguration : NSObject
@property (nonatomic, copy) id<NSCopying> identifier;
@property (nonatomic, copy) UIContextMenuContentPreviewProvider previewProvider;
@property (nonatomic, copy) UIContextMenuActionProvider actionProvider;
@end
@implementation UIContextMenuConfiguration @end
static UIContextMenuConfiguration *QAOriginalConfiguration(id<NSCopying> identifier, UIContextMenuContentPreviewProvider previewProvider, UIContextMenuActionProvider actionProvider) {
    UIContextMenuConfiguration *configuration = [UIContextMenuConfiguration new];
    configuration.identifier = identifier; configuration.previewProvider = previewProvider; configuration.actionProvider = actionProvider;
    return configuration;
}
@interface UIContextMenuInteraction : NSObject
@property (nonatomic, strong) UIView *view;
@end
@implementation UIContextMenuInteraction @end
@interface UITargetedPreview : NSObject
@property (nonatomic, strong) UIView *view;
- (instancetype)initWithView:(UIView *)view;
@end
@implementation UITargetedPreview
- (instancetype)initWithView:(UIView *)view { if ((self = [super init])) self.view = view; return self; }
@end
@protocol UIContextMenuInteractionAnimating
- (void)addCompletion:(dispatch_block_t)completion;
@end
@interface QAAnimator : NSObject <UIContextMenuInteractionAnimating>
@property (nonatomic, copy) dispatch_block_t completion;
- (void)complete;
@end
@implementation QAAnimator
- (void)addCompletion:(dispatch_block_t)completion { self.completion = completion; }
- (void)complete { dispatch_block_t completion = self.completion; self.completion = nil; if (completion) completion(); }
@end
@interface ApolloFeedGalleryCarouselView : UIView
@property (nonatomic) NSInteger currentIndex;
@property (nonatomic) BOOL contentIsObscured;
@property (nonatomic, copy) NSArray<UIImageView *> *imageViews;
@property (nonatomic) NSInteger openedIndex;
- (void)apollo_openPageAtIndex:(NSInteger)index;
@end
@implementation ApolloFeedGalleryCarouselView
- (void)apollo_openPageAtIndex:(NSInteger)index { self.openedIndex = index; }
@end

// Explicit ivar names match the private Apollo slots read by production code.
@interface QANode : NSObject
@property (nonatomic, strong) id link;
@property (nonatomic, strong) QANode *richMediaNode;
@property (nonatomic, strong) QANode *thumbnailNode;
@property (nonatomic, strong) QANode *albumThumbnailsNode;
@property (nonatomic, strong) QANode *obscuredContentInfoOverlayNode;
@property (nonatomic, strong) QANode *totalImagesNode;
@property (nonatomic, strong) QANode *thumbnailNode1;
@property (nonatomic, strong) QANode *thumbnailNode2;
@property (nonatomic, strong) QANode *thumbnailNode3;
@property (nonatomic, strong) QANode *videoNode;
@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) UIImage *placeholderImage;
@property (nonatomic, strong) id playerLayer;
@property (nonatomic, strong) id player;
@property (nonatomic, strong) UIViewController *closestViewController;
@property (nonatomic) NSUInteger taps;
@property (nonatomic, strong) id tappedNode;
- (BOOL)isNodeLoaded;
- (void)thumbnailTappedWithSender:(id)sender;
- (void)albumThumbnailButtonTappedWithSender:(id)sender;
- (void)didTapVideoNode:(id)sender;
@end
@implementation QANode
@synthesize link, richMediaNode, thumbnailNode, albumThumbnailsNode, obscuredContentInfoOverlayNode, totalImagesNode;
@synthesize thumbnailNode1, thumbnailNode2, thumbnailNode3, videoNode;
- (BOOL)isNodeLoaded { return self.view != nil; }
- (void)thumbnailTappedWithSender:(id)sender { self.taps++; self.tappedNode = sender; }
- (void)albumThumbnailButtonTappedWithSender:(id)sender { self.taps++; self.tappedNode = sender; }
- (void)didTapVideoNode:(id)sender { self.taps++; self.tappedNode = sender; }
@end
@interface QAHeader : QANode @end
@implementation QAHeader @end
@interface QALarge : QANode @end
@implementation QALarge @end
@interface QACompact : QANode @end
@implementation QACompact @end
@interface QANonImageNode : QANode @end
@implementation QANonImageNode
- (BOOL)respondsToSelector:(SEL)selector {
    return selector != @selector(image) && [super respondsToSelector:selector];
}
@end
@interface QALink : NSObject
@property (nonatomic, copy) NSURL *URL;
@property (nonatomic, copy) NSDictionary *mediaMetadata;
@property (nonatomic, copy) NSArray *galleryData;
@property (nonatomic, strong) id mediaVideo;
@property (nonatomic, strong) id crossPostVideo;
@property (nonatomic, strong) id previewVideo;
@property (nonatomic, strong) QALink *crosspostParent;
@end
@implementation QALink @end
static Class ApolloClassRichMediaHeaderCellNode = QAHeader.class;
static Class ApolloClassLargePostCellNode = QALarge.class;
static Class ApolloClassCompactPostCellNode = QACompact.class;
static Class ApolloClassApolloFeedGalleryCarouselView = ApolloFeedGalleryCarouselView.class;
static id ApolloSendObject(id object, SEL selector) {
    if ([object isKindOfClass:NSDictionary.class]) return object[NSStringFromSelector(selector)];
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}
static BOOL ApolloImageChestIsPostURL(__unused NSURL *URL) { return NO; }
static NSInteger sPreferredGIFFallbackFormat;
#define ApolloLog(...) ((void)0)
#include "PostMediaItems.inc"
#include "PostMediaGIF.inc"
#include "PostMediaSelection.inc"

static char kApolloFeedAlbumMenuContext;
static ApolloFeedAlbumMenuContext *sApolloFeedAlbumNativePreviewContext;
static NSUInteger nativeDisplays, nativeEnds, nativeCommits;
static void QANativeDisplay(void) { nativeDisplays++; }
static void QANativeEnd(void) { nativeEnds++; }
static void QANativeCommit(void) { nativeCommits++; }
static NSArray *savedItems;
static NSUInteger imageCopies, imageShares, errors;
static void ApolloFeedAlbumResolve(ApolloFeedAlbumMenuContext *context, void (^completion)(NSArray<ApolloSaveAllMediaItem *> *)) { completion(context.items); }
static void ApolloSaveAllMedia(NSArray *items, __unused UIViewController *presenter) { savedItems = items; }
static void ApolloFeedAlbumImageData(__unused ApolloFeedAlbumMenuContext *context, BOOL share) { if (share) imageShares++; else imageCopies++; }
static const NSUInteger ApolloToastStyleError = 1;
static void ApolloShowToastWithStyle(__unused NSString *title, __unused NSString *message, __unused NSUInteger style, __unused id completion) { errors++; }
static NSArray *resolvedItems;
void ApolloSaveAllMediaResolveLink(__unused id link, ApolloSaveAllMediaResolutionCompletion completion) { completion(resolvedItems, nil); }
#include "PostMediaActions.inc"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static QALink *Link(NSString *URL) { QALink *link = [QALink new]; link.URL = [NSURL URLWithString:URL]; return link; }
static QALink *Album(void) {
    QALink *link = Link(@"https://www.reddit.com/gallery/example");
    link.galleryData = @[@{@"media_id": @"first"}, @{@"media_id": @"second"}];
    link.mediaMetadata = @{@"first": @{@"e": @"Image", @"s": @{@"u": @"https://i.redd.it/first.jpg"}},
                           @"second": @{@"e": @"Image", @"s": @{@"u": @"https://i.redd.it/second.jpg"}}};
    return link;
}
static QANode *NodeOfClass(Class cls, UIView *parent, CGRect frame) {
    QANode *node = [cls new]; node.view = [UIView new]; node.view.frame = frame; node.image = [UIImage new];
    [parent addSubview:node.view]; return node;
}
static QANode *Node(UIView *parent, CGRect frame) { return NodeOfClass(QANode.class, parent, frame); }
static QANode *Cell(Class cls, QALink *link) {
    QANode *cell = [cls new]; cell.view = [UIView new]; cell.view.frame = CGRectMake(0, 0, 300, 600);
    cell.view.window = [NSObject new]; cell.view.node = cell;
    cell.closestViewController = [UIViewController new]; cell.closestViewController.view = cell.view;
    cell.richMediaNode = Node(cell.view, CGRectMake(0, 0, 300, 200));
    cell.richMediaNode.link = link;
    if (cls != QAHeader.class) cell.link = link;
    return cell;
}
static void AddAlbum(QANode *cell) {
    QANode *album = Node(cell.richMediaNode.view, CGRectMake(0, 0, 300, 200));
    cell.richMediaNode.albumThumbnailsNode = album;
    album.thumbnailNode1 = Node(album.view, CGRectMake(0, 0, 140, 200));
    album.thumbnailNode2 = Node(album.view, CGRectMake(150, 0, 150, 200));
    album.totalImagesNode = Node(album.view, CGRectMake(260, 180, 40, 20));
}
static ApolloFeedAlbumMenuContext *Hold(QANode *cell, CGFloat x, CGFloat y) {
    UIContextMenuInteraction *interaction = [UIContextMenuInteraction new]; interaction.view = cell.view;
    return ApolloFeedAlbumContext(interaction, CGPointMake(x, y));
}
static NSArray *Titles(ApolloFeedAlbumMenuContext *context) { return [ApolloFeedAlbumMenu(context).children valueForKey:@"title"]; }
static void Perform(ApolloFeedAlbumMenuContext *context, NSString *title) {
    UIMenu *menu = ApolloFeedAlbumMenu(context);
    for (UIAction *action in menu.children) {
        if (![action.title isEqualToString:title]) continue;
        action.handler(action); QAAnimator *animator = [QAAnimator new]; QAEndMenu(context, animator); [animator complete]; return;
    }
    Check(NO, [@"missing action: " stringByAppendingString:title]);
}
static void Commit(ApolloFeedAlbumMenuContext *context) { QAAnimator *animator = [QAAnimator new]; QACommit(context, animator); [animator complete]; }

static void TestAlbumSelection(void) {
    for (Class cls in @[QAHeader.class, QALarge.class]) {
        QANode *cell = Cell(cls, Album()); AddAlbum(cell);
        ApolloFeedAlbumMenuContext *context = Hold(cell, 180, 80);
        Check(context != nil && context.collection && context.index == 1, @"post header and feed both capture second album image");
        Check(context.link == cell.richMediaNode.link, @"uses RichMediaNode link for header without a cell link");
        Check([Titles(context) isEqual:@[@"Copy Image", @"Save Image", @"Save All Media", @"Share"]], @"album image has complete modern media menu");
        UIView *selected = cell.richMediaNode.albumThumbnailsNode.thumbnailNode2.view;
        Check(QAHighlight(context).view == selected, @"only pressed album image lifts when menu opens");
        Check(QADismiss(context).view == selected, @"dismissal returns only selected image to its thumbnail");
        Check(Hold(cell, 180, 300) == nil, @"hold outside media retains post menu");
        Check(Hold(cell, 145, 80).albumOverview, @"gap between album images addresses whole album");
        Check(Hold(cell, 280, 190).albumOverview, @"count badge addresses whole album");
        Check([Titles(Hold(cell, 280, 190)) isEqual:@[@"Copy Link", @"Save All Media", @"Share"]], @"album overview retains collection actions");
        Commit(context);
        Check(cell.richMediaNode.tappedNode == cell.richMediaNode.albumThumbnailsNode.thumbnailNode2, @"preview commit opens selected album thumbnail");
        QALink *replacement = Link(@"https://i.redd.it/replacement.jpg");
        cell.richMediaNode.link = replacement; cell.link = replacement;
        Perform(context, @"Save Image");
        Check(savedItems.count == 1 && [((ApolloSaveAllMediaItem *)savedItems[0]).URL.lastPathComponent isEqual:@"second.jpg"], @"reused cell saves immutable original selection");
        Commit(context);
        Check(cell.richMediaNode.taps == 1, @"reused header/feed cell cannot commit into another post");
        Check(QADismiss(context) == nil, @"reused header/feed cell cannot animate back into another post");
    }
    QANode *cell = Cell(QAHeader.class, Album()); AddAlbum(cell);
    cell.richMediaNode.albumThumbnailsNode.thumbnailNode3 = Node(cell.richMediaNode.albumThumbnailsNode.view, CGRectMake(0, 0, 140, 200));
    cell.richMediaNode.albumThumbnailsNode.thumbnailNode1.view.hidden = YES;
    Check(Hold(cell, 50, 80) == nil, @"third thumbnail with only two model items rejects stale index");
    cell.richMediaNode.obscuredContentInfoOverlayNode = Node(cell.richMediaNode.view, CGRectMake(0, 0, 300, 200));
    Check(Hold(cell, 180, 80) == nil, @"obscured media retains reveal behavior");
    cell = Cell(QACompact.class, Album());
    QANode *wrapper = NodeOfClass(QANonImageNode.class, cell.view, CGRectMake(0, 0, 80, 80));
    cell.thumbnailNode = wrapper;
    wrapper.thumbnailNode = Node(wrapper.view, wrapper.view.frame);
    ApolloFeedAlbumMenuContext *compact = Hold(cell, 20, 20);
    Check(compact.albumOverview, @"compact album thumbnail remains collection overview");
    Check(compact.sourceView == wrapper.view, @"compact hold still targets wrapper view");
    Check(compact.thumbnail == wrapper.thumbnailNode && compact.previewImage == wrapper.thumbnailNode.image,
          @"compact preview captures the inner image node instead of its wrapper");
    Commit(compact);
    Check(cell.tappedNode == wrapper.thumbnailNode && cell.taps == 1, @"compact preview opens using inner image node");
    wrapper.thumbnailNode = nil;
    Commit(Hold(cell, 20, 20));
    Check(cell.taps == 1, @"compact preview with missing image sender cannot commit");
    wrapper.thumbnailNode = [QANonImageNode new];
    Commit(Hold(cell, 20, 20));
    Check(cell.taps == 1, @"compact preview rejects sender without image support");
}

static void TestSingleMedia(void) {
    for (NSString *extension in @[@"jpg", @"gif", @"mp4"]) {
        QALink *link = Link([@"https://media.example/original." stringByAppendingString:extension]);
        QANode *cell = Cell(QAHeader.class, link);
        BOOL video = [extension isEqualToString:@"mp4"];
        QANode *media = NodeOfClass(video ? QANonImageNode.class : QANode.class,
                                   cell.richMediaNode.view, CGRectMake(0, 0, 300, 200));
        if (video) cell.richMediaNode.videoNode = media; else cell.richMediaNode.thumbnailNode = media;
        ApolloFeedAlbumMenuContext *context = Hold(cell, 150, 80);
        NSArray *titles = video ? @[@"Copy Link", @"Save Video", @"Share"] : [extension isEqualToString:@"gif"] ? @[@"Copy GIF", @"Save GIF", @"Share"] : @[@"Copy Image", @"Save Image", @"Share"];
        Check(context != nil && !context.collection && [Titles(context) isEqual:titles], @"single image/GIF/video gets matching menu without Save All Media");
        Perform(context, titles[1]);
        Check(savedItems.count == 1 && [((ApolloSaveAllMediaItem *)savedItems[0]).URL isEqual:link.URL], @"single save sends original source, never preview bitmap");
        Commit(context); Check(cell.richMediaNode.tappedNode == media, @"single preview commit uses its media node");
        if (video) {
            ApolloFeedAlbumMenuContext *copy = Hold(cell, 150, 80); Perform(copy, @"Copy Link");
            Check([UIPasteboard.generalPasteboard.URL isEqual:link.URL], @"video Copy Link uses captured video source");
            ApolloFeedAlbumMenuContext *share = Hold(cell, 150, 80); Perform(share, @"Share");
            Check([((UIActivityViewController *)cell.closestViewController.presentedViewController).items isEqual:@[link.URL]], @"video share supplies source URL");
        }
    }
    QANode *page = Cell(QAHeader.class, Link(@"https://example.com/article"));
    page.richMediaNode.thumbnailNode = Node(page.richMediaNode.view, CGRectMake(0, 0, 300, 200));
    Check(Hold(page, 50, 50) == nil, @"ordinary webpage with a preview thumbnail keeps native link menu");
    QANode *unsupported = Cell(QANode.class, Link(@"https://example.com/image.jpg"));
    Check(Hold(unsupported, 50, 50) == nil, @"unrelated cell classes retain native behavior");
}

static void TestOriginalSources(void) {
    QALink *gif = Link(@"https://preview.redd.it/animation.gif?format=mp4");
    gif.mediaMetadata = @{@"animation": @{@"status": @"valid", @"e": @"AnimatedImage", @"m": @"image/gif", @"s": @{@"mp4": gif.URL.absoluteString}}};
    ApolloSaveAllMediaItem *item = ApolloFeedAlbumSingleItem(gif, nil);
    Check([item.URL.absoluteString isEqual:@"https://i.redd.it/animation.gif"] && !item.isVideo, @"GIF metadata recovers original animation instead of MP4 preview");
    gif.URL = [NSURL URLWithString:@"https://preview.redd.it/unrelated.jpg"];
    Check([ApolloFeedAlbumSingleItem(gif, nil).URL isEqual:gif.URL], @"unrelated GIF metadata cannot replace selected image");
    QALink *video = Link(@"https://redgifs.com/watch/example");
    video.mediaVideo = @{@"fallbackURL": [NSURL URLWithString:@"https://v.redd.it/example/CMAF_480.mp4"]};
    video.previewVideo = @{@"fallbackURL": [NSURL URLWithString:@"https://v.redd.it/example/CMAF_240.mp4"]};
    QANode *rich = [QANode new]; rich.videoNode = [QANode new];
    NSURL *playing = [NSURL URLWithString:@"https://media.example/original.mp4"];
    rich.videoNode.playerLayer = @{@"player": @{@"currentItem": @{@"asset": @{@"URL": playing}}}};
    Check([ApolloFeedAlbumSingleItem(video, rich).URL isEqual:playing], @"playing original video wins over API preview");
    rich.videoNode.playerLayer = @{@"player": @{@"currentItem": @{@"asset": @{@"URL": [NSURL URLWithString:@"https://media.example/playlist.m3u8"]}}}};
    Check([ApolloFeedAlbumSingleItem(video, rich).URL isEqual:video.mediaVideo[@"fallbackURL"]], @"HLS playing asset falls back to downloadable API source");
    video.mediaVideo = nil;
    video.crossPostVideo = @{@"fallbackURL": [NSURL URLWithString:@"https://v.redd.it/parent/CMAF_720.mp4"]};
    Check([ApolloFeedAlbumSingleItem(video, rich).URL isEqual:video.crossPostVideo[@"fallbackURL"]], @"crosspost original precedes preview rendition");
    video.crossPostVideo = nil; video.previewVideo = nil;
    Check(ApolloFeedAlbumSingleItem(video, rich) == nil, @"unsupported playlist never becomes an image save");
    rich.videoNode.playerLayer = nil;
    rich.videoNode.player = @{@"currentItem": @{@"asset": @{@"URL": playing}}};
    Check([ApolloFeedAlbumSingleItem(video, rich).URL isEqual:playing], @"direct player property also supplies original asset");
    QALink *crosspost = Link(@"https://www.reddit.com/r/test/comments/outer"); crosspost.crosspostParent = video;
    Check([ApolloFeedAlbumSingleItem(crosspost, rich).URL isEqual:playing], @"single crosspost resolves media from original post");
    video.crosspostParent = crosspost;
    Check([ApolloFeedAlbumSingleItem(crosspost, rich).URL isEqual:playing], @"cyclic crossposts terminate safely");
    video.crosspostParent = nil; rich.videoNode.player = nil;
    NSURL *DASH = [NSURL URLWithString:@"https://v.redd.it/example/DASHPlaylist.mpd"];
    video.mediaVideo = @{@"URL": DASH};
    Check([ApolloFeedAlbumSingleItem(video, rich).URL isEqual:DASH], @"Reddit model DASH URL retains audio-capable exporter handle");
    video.mediaVideo = @{@"URL": [NSURL URLWithString:@"https://media.example/DASHPlaylist.mpd"]};
    Check(ApolloFeedAlbumSingleItem(video, rich) == nil, @"unsupported external DASH source retains native path");
    Check([ApolloFeedAlbumSingleItem(Link(@"https://i.imgur.com/example.gifv"), nil).URL.pathExtension isEqual:@"mp4"], @"gifv resolves to downloadable MP4 animation");
    Check(ApolloFeedAlbumSingleItem(Link(@"file:///private/image.jpg"), nil) == nil, @"non-network file source is ineligible");
}

static void TestDeferredAlbum(void) {
    QANode *cell = Cell(QAHeader.class, Link(@"https://imgur.com/a/example")); AddAlbum(cell);
    ApolloFeedAlbumMenuContext *context = Hold(cell, 180, 80);
    Check(context != nil && context.items.count == 0 && context.index == 1, @"unresolved provider retains selected album index");
    UIMenu *menu = ApolloFeedAlbumMenu(context);
    Check([menu.children.firstObject isKindOfClass:UIDeferredMenuElement.class], @"unknown provider media waits before choosing action types");
    resolvedItems = ApolloSaveAllMediaItemsFromURLs(@[[NSURL URLWithString:@"https://media.example/first.jpg"], [NSURL URLWithString:@"https://media.example/second.mp4"]], nil);
    __block NSArray *children;
    ((UIDeferredMenuElement *)menu.children.firstObject).provider(^(NSArray *items) { children = items; });
    Check([[children valueForKey:@"title"] isEqual:@[@"Copy Link", @"Save Video", @"Save All Media", @"Share"]], @"resolved provider video gets video actions and collection save");
    Perform(context, @"Save Video");
    Check([((ApolloSaveAllMediaItem *)savedItems.firstObject).URL.lastPathComponent isEqual:@"second.mp4"], @"deferred video action keeps selected second item");
    context = Hold(cell, 180, 80); menu = ApolloFeedAlbumMenu(context);
    resolvedItems = @[resolvedItems.firstObject];
    ((UIDeferredMenuElement *)menu.children.firstObject).provider(^(NSArray *items) { children = items; });
    Check(children.count == 1 && ((UIAction *)children.firstObject).attributes == UIMenuElementAttributesDisabled, @"partial provider result cannot save wrong album item");
}

static void TestNativeAnimatedPreview(void) {
    UIViewController *nativePreview = [UIViewController new];
    UIAction *legacyAction = [UIAction actionWithTitle:@"Open in Safari" image:nil identifier:nil handler:nil];
    UIMenu *legacyMenu = [UIMenu menuWithTitle:@"" children:@[legacyAction]];
    UIContextMenuContentPreviewProvider preview = ^{ return nativePreview; };
    UIContextMenuActionProvider legacyActions = ^(__unused NSArray *suggested) { return legacyMenu; };
    UIContextMenuConfiguration *ordinary = QAFactory(@"ordinary", preview, legacyActions);
    Check(ordinary.previewProvider() == nativePreview && ordinary.actionProvider(@[]) == legacyMenu,
          @"configuration factory outside media scope preserves native preview and actions");
    Check(objc_getAssociatedObject(ordinary, &kApolloFeedAlbumMenuContext) == nil,
          @"ordinary menu does not acquire a media selection");

    QALink *link = Album();
    NSMutableDictionary *metadata = [link.mediaMetadata mutableCopy];
    metadata[@"second"] = @{@"e": @"AnimatedImage", @"s": @{@"gif": @"https://i.redd.it/second.gif"}};
    link.mediaMetadata = metadata;
    QANode *cell = Cell(QAHeader.class, link); AddAlbum(cell);
    ApolloFeedAlbumMenuContext *first = Hold(cell, 50, 80);
    ApolloFeedAlbumMenuContext *second = Hold(cell, 180, 80);
    __block NSUInteger nativeCalls = 0;
    UIContextMenuConfiguration *(^makeNative)(void) = ^{
        nativeCalls++;
        return QAFactory(@"live-media", preview, legacyActions);
    };
    QAConfigure(first, makeNative);
    Check(nativeCalls == 0 && !first.nativePreview, @"still first album item retains still-image preview");
    UIContextMenuConfiguration *animated = QAConfigure(second, makeNative);
    Check(nativeCalls == 1 && second.nativePreview, @"selected second GIF routes through native live preview");
    Check(animated.previewProvider() == nativePreview, @"animated factory preserves native previewProvider result");
    Check([(NSString *)animated.identifier isEqual:@"live-media"], @"animated factory preserves native configuration identifier");
    Check([[animated.actionProvider(@[legacyAction]).children valueForKey:@"title"] isEqual:@[@"Copy GIF", @"Save GIF", @"Save All Media", @"Share"]],
          @"animated factory replaces legacy actions with selected GIF actions");
    Check(objc_getAssociatedObject(animated, &kApolloFeedAlbumMenuContext) == second,
          @"animated configuration retains exact second-item selection");
    Check(sApolloFeedAlbumNativePreviewContext == nil, @"normal native configuration restores empty interception scope");

    // Reverse the item types: the selected still image must not inherit the
    // first member's native-animation path.
    metadata[@"first"] = metadata[@"second"];
    metadata[@"second"] = @{@"e": @"Image", @"s": @{@"u": @"https://i.redd.it/second.jpg"}};
    link.mediaMetadata = metadata;
    ApolloFeedAlbumMenuContext *stillSecond = Hold(cell, 180, 80);
    QAConfigure(stillSecond, makeNative);
    Check(nativeCalls == 1 && !stillSecond.nativePreview, @"selected still second item ignores first item's GIF type");

    ApolloFeedAlbumMenuContext *previous = [ApolloFeedAlbumMenuContext new];
    sApolloFeedAlbumNativePreviewContext = previous;
    QAConfigure(second, makeNative);
    Check(sApolloFeedAlbumNativePreviewContext == previous, @"successful nested configuration restores prior interception scope");
    BOOL caught = NO;
    @try {
        QAConfigure(second, ^UIContextMenuConfiguration *{
            Check(sApolloFeedAlbumNativePreviewContext == second, @"native callback sees current selection scope");
            @throw [NSException exceptionWithName:@"FixtureFailure" reason:nil userInfo:nil];
        });
    } @catch (NSException *exception) { caught = [exception.name isEqual:@"FixtureFailure"]; }
    Check(caught && sApolloFeedAlbumNativePreviewContext == previous,
          @"throwing native configuration restores prior interception scope");
    sApolloFeedAlbumNativePreviewContext = nil;

    NSUInteger displays = nativeDisplays, ends = nativeEnds, commits = nativeCommits;
    QADisplay(second);
    Check(nativeDisplays == displays + 1, @"animated menu keeps native display/playback lifecycle");
    QADisplay(first);
    Check(nativeDisplays == displays + 1, @"still menu does not enter native playback lifecycle");
    Perform(second, @"Save GIF");
    Check(nativeEnds == ends + 1 && second.ended && second.pendingAction == nil,
          @"animated dismissal runs native cleanup and deferred media action");
    Check([((ApolloSaveAllMediaItem *)savedItems.firstObject).URL.lastPathComponent isEqual:@"second.gif"],
          @"animated menu saves originally selected GIF after model changes");
    Commit(second);
    Check(nativeCommits == commits + 1 && cell.richMediaNode.taps == 0,
          @"animated preview commits through native player lifecycle");
    cell.richMediaNode.link = Link(@"https://i.redd.it/reused.jpg");
    Commit(second);
    Check(nativeCommits == commits + 1, @"reused animated preview cannot commit another post");
    Check(QAHighlight(second) == nil && QADismiss(second) == nil,
          @"reused animated preview cannot target another post's thumbnail");

    for (NSString *extension in @[@"gif", @"mp4"]) {
        QANode *singleCell = Cell(QAHeader.class, Link([@"https://media.example/live." stringByAppendingString:extension]));
        QANode *media = Node(singleCell.richMediaNode.view, CGRectMake(0, 0, 300, 200));
        if ([extension isEqual:@"mp4"]) singleCell.richMediaNode.videoNode = media;
        else singleCell.richMediaNode.thumbnailNode = media;
        ApolloFeedAlbumMenuContext *single = Hold(singleCell, 80, 80);
        UIContextMenuConfiguration *configuration = QAConfigure(single, makeNative);
        Check(single.nativePreview && configuration.previewProvider() == nativePreview,
              @"single GIF/video keeps native preview even without a usable poster");
        Check(configuration.actionProvider(@[]).children.count == 3,
              @"single animated preview keeps media menu without Save All Media");
    }
}

int main(void) {
    @autoreleasepool {
        TestAlbumSelection(); TestSingleMedia(); TestOriginalSources(); TestDeferredAlbum(); TestNativeAnimatedPreview();
        Check(errors == 0, @"valid selections produce no error toasts");
    }
    printf("post_media_menu_tests: all %lu checks passed\n", (unsigned long)checks);
    return 0;
}
