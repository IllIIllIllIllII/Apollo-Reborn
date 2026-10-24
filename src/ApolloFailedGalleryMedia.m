#import "ApolloFailedGalleryMedia.h"
#import <ImageIO/ImageIO.h>

#ifdef APOLLO_FAILED_GALLERY_TESTING
#define ApolloLog(...) NSLog(__VA_ARGS__)
#else
#import "ApolloCommon.h"
#endif

@implementation ApolloFailedGalleryImage
@end

// Longest a response waits on i.redd.it in total, and how much of each image
// it reads (JPEG/PNG/GIF/WebP all state their size within the first bytes).
static const NSTimeInterval kApolloFailedGalleryWait = 4.0;
static const NSUInteger kApolloFailedGalleryHeaderBytes = 64 * 1024;
static NSArray<NSString *> *ApolloFailedGalleryDefaultExtensions(void) {
    return @[@"jpeg", @"jpg", @"png", @"gif", @"webp"];
}

static BOOL ApolloFailedGalleryEntryFailed(id entry) {
    if (![entry isKindOfClass:NSDictionary.class]) return NO;
    id status = ((NSDictionary *)entry)[@"status"];
    if (![status isKindOfClass:NSString.class] || ![status isEqualToString:@"failed"]) return NO;
    // Only the empty shape: never touch an entry that still carries media.
    return ![((NSDictionary *)entry)[@"s"] isKindOfClass:NSDictionary.class];
}

// The extension a post's thumbnail or preview gives for this media id
// ("preview.redd.it/<id>.jpeg?..."), the likeliest one for every image.
static NSString *ApolloFailedGalleryHintedExtension(NSDictionary *post, NSString *mediaID) {
    for (NSString *key in @[@"thumbnail", @"url_overridden_by_dest", @"url"]) {
        NSString *value = [post[key] isKindOfClass:NSString.class] ? post[key] : nil;
        NSURL *url = value.length ? [NSURL URLWithString:value] : nil;
        NSString *name = url.path.lastPathComponent;
        if (name.length && [name.stringByDeletingPathExtension isEqualToString:mediaID]) {
            NSString *extension = name.pathExtension.lowercaseString;
            if (extension.length) return extension;
        }
    }
    return nil;
}

static NSArray<NSString *> *ApolloFailedGalleryExtensions(NSString *hint) {
    NSMutableArray<NSString *> *extensions = [NSMutableArray array];
    if (hint.length) [extensions addObject:hint];
    for (NSString *extension in ApolloFailedGalleryDefaultExtensions()) {
        if (![extensions containsObject:extension]) [extensions addObject:extension];
    }
    return extensions;
}

static NSDictionary *ApolloFailedGalleryEntry(NSString *mediaID, ApolloFailedGalleryImage *image) {
    BOOL animated = [image.mimeType isEqualToString:@"image/gif"];
    NSMutableDictionary *source = [@{@"u": image.URLString, @"x": @(image.width), @"y": @(image.height)} mutableCopy];
    if (animated) source[@"gif"] = image.URLString;
    return @{
        @"status": @"valid",
        @"e": animated ? @"AnimatedImage" : @"Image",
        @"m": image.mimeType,
        @"id": mediaID,
        @"s": source,
        @"p": @[@{@"u": image.URLString, @"x": @(image.width), @"y": @(image.height)}],
    };
}

// Gallery posts (kind t3) anywhere in a listing or comments response.
static void ApolloFailedGalleryCollectPosts(id node, NSMutableArray<NSMutableDictionary *> *posts, NSUInteger depth) {
    if (depth > 8) return;
    if ([node isKindOfClass:NSArray.class]) {
        for (id child in (NSArray *)node) ApolloFailedGalleryCollectPosts(child, posts, depth + 1);
        return;
    }
    if (![node isKindOfClass:NSMutableDictionary.class]) return;
    NSMutableDictionary *dictionary = node;
    id data = dictionary[@"data"];
    if ([dictionary[@"kind"] isEqual:@"t3"] && [data isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *post = data;
        if ([post[@"gallery_data"] isKindOfClass:NSDictionary.class] &&
            [post[@"media_metadata"] isKindOfClass:NSMutableDictionary.class]) {
            [posts addObject:post];
        }
        return;
    }
    if ([data isKindOfClass:NSDictionary.class]) ApolloFailedGalleryCollectPosts(data[@"children"], posts, depth + 1);
}

NSData *ApolloRepairFailedGalleryMedia(NSData *data, ApolloFailedGalleryImageResolver resolver) {
    if (data.length == 0 || !resolver) return data;
    // Cheap check before parsing: nearly every response has no failed media.
    static NSData *needle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ needle = [@"\"failed\"" dataUsingEncoding:NSUTF8StringEncoding]; });
    if ([data rangeOfData:needle options:0 range:NSMakeRange(0, data.length)].location == NSNotFound) return data;

    id root = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
    if (!root) return data;
    NSMutableArray<NSMutableDictionary *> *posts = [NSMutableArray array];
    ApolloFailedGalleryCollectPosts(root, posts, 0);

    // Every failed media id, with the extensions to try for it.
    NSMutableArray<NSDictionary *> *jobs = [NSMutableArray array];
    for (NSMutableDictionary *post in posts) {
        NSMutableDictionary *metadata = post[@"media_metadata"];
        NSString *postHint = nil;
        for (NSString *mediaID in metadata.allKeys) {
            NSString *hint = ApolloFailedGalleryHintedExtension(post, mediaID);
            if (hint) { postHint = hint; break; }
        }
        for (NSString *mediaID in metadata.allKeys) {
            if (!ApolloFailedGalleryEntryFailed(metadata[mediaID])) continue;
            NSString *hint = ApolloFailedGalleryHintedExtension(post, mediaID) ?: postHint;
            [jobs addObject:@{@"post": post, @"id": mediaID, @"extensions": ApolloFailedGalleryExtensions(hint)}];
        }
    }
    if (jobs.count == 0) return data;

    NSMutableDictionary<NSString *, ApolloFailedGalleryImage *> *found = [NSMutableDictionary dictionary];
    NSObject *lock = [NSObject new];
    dispatch_group_t group = dispatch_group_create();
    for (NSDictionary *job in jobs) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            ApolloFailedGalleryImage *image = resolver(job[@"id"], job[@"extensions"]);
            if (image) @synchronized (lock) { found[job[@"id"]] = image; }
        });
    }
    if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloFailedGalleryWait * NSEC_PER_SEC))) != 0) {
        ApolloLog(@"[FailedGallery] Timed out finding %lu failed gallery image(s); using what was found", (unsigned long)jobs.count);
    }

    NSUInteger repaired = 0;
    @synchronized (lock) {
        for (NSDictionary *job in jobs) {
            ApolloFailedGalleryImage *image = found[job[@"id"]];
            if (!image) continue;
            NSMutableDictionary *metadata = ((NSMutableDictionary *)job[@"post"])[@"media_metadata"];
            metadata[job[@"id"]] = ApolloFailedGalleryEntry(job[@"id"], image);
            repaired++;
        }
    }
    ApolloLog(@"[FailedGallery] Rebuilt %lu of %lu failed gallery image(s) from i.redd.it", (unsigned long)repaired, (unsigned long)jobs.count);
    if (repaired == 0) return data;
    NSData *rewritten = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
    return rewritten ?: data;
}

#pragma mark - Network resolver

// One image's header from i.redd.it, or nil when it isn't there under this
// extension (a missing name answers 404 with a placeholder PNG). `notThere`
// says the nil is a definite 404 rather than a failed request.
static ApolloFailedGalleryImage *ApolloFailedGalleryFetch(NSString *mediaID, NSString *extension, BOOL *notThere) {
    *notThere = NO;
    NSString *urlString = [NSString stringWithFormat:@"https://i.redd.it/%@.%@", mediaID, extension];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = kApolloFailedGalleryWait;
    [request setValue:[NSString stringWithFormat:@"bytes=0-%lu", (unsigned long)kApolloFailedGalleryHeaderBytes - 1] forHTTPHeaderField:@"Range"];

    __block NSData *body = nil;
    __block NSHTTPURLResponse *http = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, __unused NSError *error) {
        body = data;
        http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloFailedGalleryWait * NSEC_PER_SEC)));
    if (http.statusCode == 404) *notThere = YES;
    if (!http || (http.statusCode != 200 && http.statusCode != 206) || body.length == 0) return nil;
    NSString *mimeType = http.MIMEType.lowercaseString;
    if (![mimeType hasPrefix:@"image/"]) return nil;

    CGImageSourceRef imageSource = CGImageSourceCreateIncremental(NULL);
    CGImageSourceUpdateData(imageSource, (__bridge CFDataRef)body, false);
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL));
    CFRelease(imageSource);
    NSInteger width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] integerValue];
    NSInteger height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] integerValue];
    if (width <= 0 || height <= 0) return nil;

    ApolloFailedGalleryImage *image = [ApolloFailedGalleryImage new];
    image.URLString = urlString;
    image.mimeType = mimeType;
    image.width = width;
    image.height = height;
    return image;
}

ApolloFailedGalleryImageResolver ApolloFailedGalleryNetworkResolver(void) {
    static NSCache<NSString *, id> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 500;
    });
    return ^ApolloFailedGalleryImage *(NSString *mediaID, NSArray<NSString *> *extensions) {
        id cached = [cache objectForKey:mediaID];
        if (cached) return [cached isKindOfClass:ApolloFailedGalleryImage.class] ? cached : nil;
        BOOL allNotThere = YES;
        for (NSString *extension in extensions) {
            BOOL notThere = NO;
            ApolloFailedGalleryImage *image = ApolloFailedGalleryFetch(mediaID, extension, &notThere);
            if (image) {
                [cache setObject:image forKey:mediaID];
                return image;
            }
            allNotThere = allNotThere && notThere;
        }
        // Remember a definite miss, so scrolling past the post doesn't probe
        // again; a failed request is retried next time.
        if (allNotThere) [cache setObject:NSNull.null forKey:mediaID];
        return nil;
    };
}
