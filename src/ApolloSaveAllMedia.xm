#import "ApolloSaveAllMedia.h"
#import "ApolloCommon.h"
#import "ApolloGalleryVideoExport.h"
#import "ApolloToast.h"

#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Apollo's media-save completion presents its own Holla success banner. The
// image argument is unused by the success path; this callback only reports a
// completed save and does not write anything to Photos. A fresh manager leaves
// its wallpaper-saving controller unset, selecting the ordinary "Saved!"
// banner rather than the separate wallpaper instructions.
//
// Holla enqueues presentation on the main queue even when invoked on main.
// Queue the one-shot title immediately before that block, then clear it
// immediately after. Existing queued banners run before the title is armed;
// later normal saves cannot inherit a stale batch title. The hook updates only
// a newly attached HollaStatusView that already has the native success label.
// Apollo still owns the icon, styling, sizing, placement, haptics and animation.
static NSString *sApolloSaveAllPendingBannerTitle;
static NSObject *sApolloSaveAllPendingBannerToken;

static BOOL ApolloSaveAllShowNativeSuccess(NSUInteger count) {
    Class managerClass = NSClassFromString(@"Apollo.ShareMediaManager");
    SEL completion = @selector(image:didFinishSavingWithError:contextInfo:);
    id manager = [[managerClass alloc] init];
    if (![manager respondsToSelector:completion]) {
        ApolloLog(@"[SaveAllMedia] native save completion unavailable");
        return NO;
    }

    NSString *title = [NSString stringWithFormat:@"Saved All %lu Items!", (unsigned long)count];
    NSObject *token = [NSObject new];
    dispatch_async(dispatch_get_main_queue(), ^{
        sApolloSaveAllPendingBannerTitle = title;
        sApolloSaveAllPendingBannerToken = token;
    });
    ((void (*)(id, SEL, id, id, void *))objc_msgSend)(manager, completion, nil, nil, NULL);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sApolloSaveAllPendingBannerToken != token) return;
        sApolloSaveAllPendingBannerTitle = nil;
        sApolloSaveAllPendingBannerToken = nil;
        ApolloLog(@"[SaveAllMedia] native success banner was not presented");
    });
    return YES;
}

%hook _TtC6Apollo15HollaStatusView
- (void)didMoveToSuperview {
    %orig;
    if (!sApolloSaveAllPendingBannerToken || !((UIView *)self).superview) return;
    Ivar labelIvar = class_getInstanceVariable(object_getClass(self), "textLabel");
    id value = labelIvar ? object_getIvar(self, labelIvar) : nil;
    if (![value isKindOfClass:UILabel.class]) return;
    UILabel *label = value;
    if (![label.text isEqualToString:@"Saved!"]) return;

    NSString *title = sApolloSaveAllPendingBannerTitle;
    sApolloSaveAllPendingBannerTitle = nil;
    sApolloSaveAllPendingBannerToken = nil;
    // Holla attaches the fully initialized view before measuring/animating it,
    // so its normal layout measures this text and keeps the native checkmark.
    label.text = title;
    ApolloLog(@"[SaveAllMedia] native success banner title=%@", title);
}
%end

// All job state is confined to the main queue. Download completion handlers do
// only file inspection/moves before handing ownership of that file back to the
// main queue. A strong process-wide owner keeps the job alive if the user closes
// the viewer, and also prevents two menus from launching overlapping saves.
@interface ApolloSaveAllMediaJob : NSObject
@property (nonatomic, copy) NSArray<ApolloSaveAllMediaItem *> *items;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, strong) UIAlertController *progressAlert;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDownloadTask *downloadTask;
@property (nonatomic, strong) NSURL *directoryURL;
@property (nonatomic) NSUInteger nextIndex;
@property (nonatomic) NSUInteger savedCount;
@property (nonatomic) NSUInteger failedCount;
@property (nonatomic) BOOL savingVideo;
@property (nonatomic) BOOL cancelled;
@property (nonatomic) BOOL finished;
- (void)start;
- (void)saveNextItem;
- (void)finish;
@end

static ApolloSaveAllMediaJob *sApolloSaveAllMediaJob;

static void ApolloSaveAllMediaOnMain(void (^block)(void)) {
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

static void ApolloSaveAllMediaRemoveFile(NSURL *fileURL) {
    if (fileURL) [[NSFileManager defaultManager] removeItemAtURL:fileURL error:NULL];
}

@implementation ApolloSaveAllMediaJob

- (void)start {
    // Check once up front so denied permission never downloads an entire post.
    // The shared video exporter rechecks the already-decided permission before
    // its Photos write, but will not present a second authorization request.
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus result) {
            ApolloSaveAllMediaOnMain(^{ [self startWithAuthorization:result]; });
        }];
    } else {
        [self startWithAuthorization:status];
    }
}

- (void)startWithAuthorization:(PHAuthorizationStatus)status {
    if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
        self.finished = YES;
        if (sApolloSaveAllMediaJob == self) sApolloSaveAllMediaJob = nil;
        UIViewController *presenter = self.presenter;
        if (!presenter.viewIfLoaded.window || presenter.presentedViewController) {
            ApolloShowToastWithStyle(@"Photos Access Required", @"Allow adding photos in Settings.",
                                    ApolloToastStyleError, nil);
            return;
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Photos Access Required"
            message:@"Allow Apollo to add photos in Settings, then try Save All Media again."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Open Settings" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]
                                               options:@{} completionHandler:nil];
        }]];
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIViewController *presenter = self.presenter;
    if (!presenter.viewIfLoaded.window || presenter.presentedViewController || presenter.isBeingDismissed) {
        self.finished = YES;
        if (sApolloSaveAllMediaJob == self) sApolloSaveAllMediaJob = nil;
        ApolloShowToastWithStyle(@"Couldn't Start Saving", @"Open the post and try again.",
                                ApolloToastStyleError, nil);
        return;
    }

    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"ApolloSaveAllMedia-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.directoryURL = [NSURL fileURLWithPath:directory isDirectory:YES];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:self.directoryURL
                                 withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        ApolloLog(@"[SaveAllMedia] temporary directory failed domain=%@ code=%ld",
                  directoryError.domain, (long)directoryError.code);
        self.finished = YES;
        if (sApolloSaveAllMediaJob == self) sApolloSaveAllMediaJob = nil;
        ApolloShowToastWithStyle(@"Couldn't Start Saving", @"Check available storage and try again.",
                                ApolloToastStyleError, nil);
        return;
    }

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.URLCache = nil;
    configuration.timeoutIntervalForRequest = 60.0;
    configuration.timeoutIntervalForResource = 300.0;
    self.session = [NSURLSession sessionWithConfiguration:configuration];

    self.progressAlert = [UIAlertController alertControllerWithTitle:@"Saving All Media"
        message:[NSString stringWithFormat:@"Preparing %lu items…", (unsigned long)self.items.count]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak ApolloSaveAllMediaJob *weakSelf = self;
    [self.progressAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [weakSelf cancel];
    }]];
    // Start from the presentation completion so a very fast response cannot
    // finish/dismiss this controller while UIKit is still presenting it.
    [presenter presentViewController:self.progressAlert animated:YES completion:^{ [self saveNextItem]; }];
    ApolloLog(@"[SaveAllMedia] started count=%lu", (unsigned long)self.items.count);
}

- (void)updateProgress:(NSString *)stage {
    if (self.cancelled || self.finished) return;
    self.progressAlert.message = [NSString stringWithFormat:@"Item %lu of %lu\n%@\n%lu saved",
        (unsigned long)(self.nextIndex + 1), (unsigned long)self.items.count,
        stage, (unsigned long)self.savedCount];
}

- (void)cancel {
    if (self.cancelled || self.finished) return;
    self.cancelled = YES;
    if (self.downloadTask) {
        [self.downloadTask cancel];
    } else if (self.savingVideo) {
        // The existing video exporter owns its download/mux/Photos operations
        // and has no cancellation token. Do not pretend that we stopped it:
        // count its real result, then stop before starting another item.
        ApolloShowToastWithStyle(@"Stopping After This Video", @"The current video may still be saved.",
                                ApolloToastStyleInfo, nil);
    }
    ApolloLog(@"[SaveAllMedia] cancellation requested completed=%lu",
              (unsigned long)(self.savedCount + self.failedCount));
}

- (void)saveNextItem {
    if (self.finished) return;
    if (self.cancelled || self.nextIndex >= self.items.count) {
        [self finish];
        return;
    }

    ApolloSaveAllMediaItem *item = self.items[self.nextIndex];
    if (item.isVideo) {
        self.savingVideo = YES;
        ApolloGallerySaveVideoToPhotosStrict(item.URL, ^(NSString *text) {
            [self updateProgress:text];
        }, ^(BOOL success, NSString *message) {
            self.savingVideo = NO;
            [self completedItem:success];
        });
    } else {
        [self updateProgress:@"Downloading original image…"];
        [self downloadImage:item];
    }
}

- (void)downloadImage:(ApolloSaveAllMediaItem *)item {
    NSURL *directoryURL = self.directoryURL;
    self.downloadTask = [self.session downloadTaskWithURL:item.URL
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        @autoreleasepool {
            NSInteger httpStatus = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            NSURL *fileURL = nil;
            NSString *typeIdentifier = nil;
            // Never turn a server error page or a thumbnail re-encode into a
            // successful save. ImageIO checks the downloaded original's type
            // without decoding its pixels or loading all images into memory.
            if (location && !error && httpStatus >= 200 && httpStatus < 300) {
                CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)location,
                    (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache: @NO});
                if (source) {
                    if (CGImageSourceGetCount(source) > 0) {
                        typeIdentifier = [(__bridge NSString *)CGImageSourceGetType(source) copy];
                    }
                    CFRelease(source);
                }
                if (typeIdentifier.length > 0) {
                    NSString *extension = [UTType typeWithIdentifier:typeIdentifier].preferredFilenameExtension ?: @"img";
                    fileURL = [directoryURL URLByAppendingPathComponent:
                        [NSUUID.UUID.UUIDString stringByAppendingPathExtension:extension] isDirectory:NO];
                    NSError *moveError = nil;
                    // Download locations expire at the end of this callback,
                    // so retain the file before returning to the main queue.
                    if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:fileURL error:&moveError]) {
                        ApolloLog(@"[SaveAllMedia] image move failed domain=%@ code=%ld",
                                  moveError.domain, (long)moveError.code);
                        fileURL = nil;
                    }
                }
            }
            if (!fileURL && error.code != NSURLErrorCancelled) {
                ApolloLog(@"[SaveAllMedia] image download/validation failed HTTP=%ld domain=%@ code=%ld",
                          (long)httpStatus, error.domain ?: @"none", (long)error.code);
            }
            ApolloSaveAllMediaOnMain(^{
                self.downloadTask = nil;
                if (self.cancelled || self.finished) {
                    ApolloSaveAllMediaRemoveFile(fileURL);
                    [self finish];
                } else if (!fileURL) {
                    [self completedItem:NO];
                } else {
                    [self saveImageFile:fileURL typeIdentifier:typeIdentifier];
                }
            });
        }
    }];
    [self.downloadTask resume];
}

- (void)saveImageFile:(NSURL *)fileURL typeIdentifier:(NSString *)typeIdentifier {
    [self updateProgress:@"Adding image to Photos…"];
    // File-backed resources preserve GIF/APNG animation, color profiles, and
    // original resolution. Photos reads the file asynchronously; it stays on
    // disk until the completion callback confirms that the write has ended.
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetResourceCreationOptions *options = [[PHAssetResourceCreationOptions alloc] init];
        options.uniformTypeIdentifier = typeIdentifier;
        PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
        [request addResourceWithType:PHAssetResourceTypePhoto fileURL:fileURL options:options];
    } completionHandler:^(BOOL success, NSError *error) {
        ApolloSaveAllMediaRemoveFile(fileURL);
        if (!success) {
            ApolloLog(@"[SaveAllMedia] Photos image write failed domain=%@ code=%ld",
                      error.domain, (long)error.code);
        }
        ApolloSaveAllMediaOnMain(^{ [self completedItem:success]; });
    }];
}

- (void)completedItem:(BOOL)success {
    if (self.finished) return;
    if (success) self.savedCount++;
    else self.failedCount++;
    self.nextIndex++;
    // A later main-queue turn gives cancellation a chance to stop a batch of
    // cached/fast responses before the next request begins.
    dispatch_async(dispatch_get_main_queue(), ^{ [self saveNextItem]; });
}

- (void)finish {
    if (self.finished) return;
    self.finished = YES;
    [self.session finishTasksAndInvalidate];
    self.session = nil;
    ApolloSaveAllMediaRemoveFile(self.directoryURL);
    self.directoryURL = nil;
    if (sApolloSaveAllMediaJob == self) sApolloSaveAllMediaJob = nil;

    NSUInteger total = self.items.count;
    NSUInteger skipped = total - self.savedCount - self.failedCount;
    BOOL allSaved = self.savedCount == total;
    NSString *title = allSaved
        ? [NSString stringWithFormat:@"Saved All %lu Items!", (unsigned long)total]
        : [NSString stringWithFormat:@"Saved %lu of %lu Items", (unsigned long)self.savedCount, (unsigned long)total];
    NSString *detail = nil;
    if (self.cancelled && skipped > 0) {
        detail = self.failedCount > 0
            ? [NSString stringWithFormat:@"Cancelled · %lu failed · %lu skipped", (unsigned long)self.failedCount, (unsigned long)skipped]
            : [NSString stringWithFormat:@"Cancelled · %lu skipped", (unsigned long)skipped];
    } else if (self.failedCount > 0) {
        detail = [NSString stringWithFormat:@"%lu could not be saved to Photos.", (unsigned long)self.failedCount];
    }
    ApolloToastStyle style = allSaved ? ApolloToastStyleSuccess
        : (self.failedCount > 0 ? ApolloToastStyleError : ApolloToastStyleInfo);
    void (^showResult)(void) = ^{
        if (allSaved && ApolloSaveAllShowNativeSuccess(total)) return;
        ApolloShowToastWithStyle(title, detail, style, nil);
    };
    UIAlertController *progress = self.progressAlert;
    self.progressAlert = nil;
    if (progress.presentingViewController && !progress.isBeingDismissed) {
        [progress dismissViewControllerAnimated:YES completion:showResult];
    } else {
        showResult();
    }
    ApolloLog(@"[SaveAllMedia] finished saved=%lu failed=%lu skipped=%lu cancelled=%d",
              (unsigned long)self.savedCount, (unsigned long)self.failedCount,
              (unsigned long)skipped, self.cancelled);
}

@end

void ApolloSaveAllMedia(NSArray<ApolloSaveAllMediaItem *> *items, UIViewController *presenter) {
    NSArray<ApolloSaveAllMediaItem *> *snapshot = [items copy];
    ApolloSaveAllMediaOnMain(^{
        if (sApolloSaveAllMediaJob) {
            ApolloShowToastWithStyle(@"Already Saving Media", @"Wait for the current save to finish.",
                                    ApolloToastStyleInfo, nil);
            return;
        }
        if (snapshot.count == 0) {
            ApolloShowToastWithStyle(@"No Media to Save", nil, ApolloToastStyleInfo, nil);
            return;
        }
        ApolloSaveAllMediaJob *job = [[ApolloSaveAllMediaJob alloc] init];
        job.items = snapshot;
        job.presenter = presenter;
        sApolloSaveAllMediaJob = job;
        [job start];
    });
}
