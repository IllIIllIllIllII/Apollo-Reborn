#import <Foundation/Foundation.h>
#import "ApolloFailedGalleryMedia.h"

static int failures = 0;
#define EXPECT(cond, msg) do { if (!(cond)) { fprintf(stderr, "FAIL: %s\n", msg); failures++; } } while (0)

static NSData *JSON(id object) { return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL]; }
static id Parse(NSData *data) { return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]; }

// A comments response: [post listing, comments listing].
static NSData *ThreadResponse(NSDictionary *metadata, NSString *thumbnail) {
    NSDictionary *post = @{
        @"id": @"1xdlhq1", @"name": @"t3_1xdlhq1", @"is_gallery": @YES,
        @"url": @"https://www.reddit.com/gallery/1xdlhq1",
        @"thumbnail": thumbnail ?: @"default",
        @"gallery_data": @{@"items": @[@{@"id": @1, @"media_id": @"aaa"}, @{@"id": @2, @"media_id": @"bbb"}]},
        @"media_metadata": metadata,
    };
    return JSON(@[
        @{@"kind": @"Listing", @"data": @{@"children": @[@{@"kind": @"t3", @"data": post}]}},
        @{@"kind": @"Listing", @"data": @{@"children": @[]}},
    ]);
}

static NSDictionary *Metadata(NSData *data) {
    return Parse(data)[0][@"data"][@"children"][0][@"data"][@"media_metadata"];
}

int main(void) {
    @autoreleasepool {
        NSMutableArray<NSString *> *asked = [NSMutableArray array];
        ApolloFailedGalleryImageResolver resolver = ^ApolloFailedGalleryImage *(NSString *mediaID, NSArray<NSString *> *extensions) {
            @synchronized (asked) { [asked addObject:[NSString stringWithFormat:@"%@:%@", mediaID, extensions.firstObject]]; }
            if ([mediaID isEqualToString:@"zzz"]) return nil;
            ApolloFailedGalleryImage *image = [ApolloFailedGalleryImage new];
            image.URLString = [NSString stringWithFormat:@"https://i.redd.it/%@.%@", mediaID, extensions.firstObject];
            image.mimeType = [mediaID isEqualToString:@"bbb"] ? @"image/gif" : @"image/jpeg";
            image.width = 300; image.height = 400;
            return image;
        };

        // Failed entries are rebuilt, with the thumbnail's extension tried first.
        NSData *failed = ThreadResponse(@{@"aaa": @{@"status": @"failed"}, @"bbb": @{@"status": @"failed"}},
                                        @"https://preview.redd.it/aaa.jpeg?width=140&s=x");
        NSDictionary *repaired = Metadata(ApolloRepairFailedGalleryMedia(failed, resolver));
        EXPECT([repaired[@"aaa"][@"status"] isEqual:@"valid"], "aaa becomes valid");
        EXPECT([repaired[@"aaa"][@"s"][@"u"] isEqual:@"https://i.redd.it/aaa.jpeg"], "aaa source URL");
        EXPECT([repaired[@"aaa"][@"s"][@"x"] isEqual:@300] && [repaired[@"aaa"][@"s"][@"y"] isEqual:@400], "aaa size");
        EXPECT([repaired[@"aaa"][@"e"] isEqual:@"Image"], "aaa is an image");
        EXPECT([repaired[@"bbb"][@"e"] isEqual:@"AnimatedImage"] && [repaired[@"bbb"][@"s"][@"gif"] length] > 0, "bbb is a GIF");
        EXPECT([asked containsObject:@"bbb:jpeg"], "the post's hinted extension is tried for every image");

        // A healthy gallery is returned untouched (same object, no lookups).
        [asked removeAllObjects];
        NSData *healthy = ThreadResponse(@{@"aaa": @{@"status": @"valid", @"s": @{@"u": @"https://i.redd.it/aaa.png", @"x": @1, @"y": @1}}}, nil);
        EXPECT(ApolloRepairFailedGalleryMedia(healthy, resolver) == healthy, "healthy data unchanged");
        EXPECT(asked.count == 0, "no lookups for a healthy gallery");

        // An entry that still carries media keeps it even if marked failed.
        NSData *mixed = ThreadResponse(@{@"aaa": @{@"status": @"failed", @"s": @{@"u": @"https://i.redd.it/aaa.png", @"x": @1, @"y": @1}}}, nil);
        EXPECT(ApolloRepairFailedGalleryMedia(mixed, resolver) == mixed, "failed entry with media untouched");

        // An image that can't be found stays failed; the rest are rebuilt.
        NSData *partial = ThreadResponse(@{@"aaa": @{@"status": @"failed"}, @"zzz": @{@"status": @"failed"}}, nil);
        NSDictionary *partialMetadata = Metadata(ApolloRepairFailedGalleryMedia(partial, resolver));
        EXPECT([partialMetadata[@"aaa"][@"status"] isEqual:@"valid"], "found image rebuilt");
        EXPECT([partialMetadata[@"zzz"][@"status"] isEqual:@"failed"], "missing image left failed");

        // Nothing found: the original data comes back.
        NSData *none = ThreadResponse(@{@"zzz": @{@"status": @"failed"}}, nil);
        EXPECT(ApolloRepairFailedGalleryMedia(none, resolver) == none, "nothing found leaves data unchanged");

        // A listing response (top-level dictionary) is repaired too.
        NSData *listing = JSON(@{@"kind": @"Listing", @"data": @{@"children": @[@{@"kind": @"t3", @"data": @{
            @"id": @"p", @"gallery_data": @{@"items": @[]}, @"media_metadata": @{@"aaa": @{@"status": @"failed"}}}}]}});
        NSDictionary *listingMetadata = Parse(ApolloRepairFailedGalleryMedia(listing, resolver))[@"data"][@"children"][0][@"data"][@"media_metadata"];
        EXPECT([listingMetadata[@"aaa"][@"status"] isEqual:@"valid"], "listing gallery rebuilt");
    }
    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("failed gallery media tests passed\n");
    return 0;
}
