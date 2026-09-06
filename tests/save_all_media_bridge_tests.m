#import <Foundation/Foundation.h>

extern CFArrayRef ApolloSaveAllMediaCopyURLs(const void *storage);
extern CFArrayRef ApolloTestNilMediaURLs(void);
extern CFArrayRef ApolloTestEmptyMediaURLs(void);
extern CFArrayRef ApolloTestOrderedMediaURLs(void);
extern NSInteger ApolloTestOptionalURLArraySize(void);

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        Check(ApolloTestOptionalURLArraySize() == sizeof(void *), @"native optional URL array fits the checked one-pointer ivar slot");
        Check(ApolloSaveAllMediaCopyURLs(NULL) == NULL, @"NULL storage produces nil");
        Check(ApolloTestNilMediaURLs() == NULL, @"Swift Optional.none produces nil");
        NSArray *empty = CFBridgingRelease(ApolloTestEmptyMediaURLs());
        Check(empty != nil && empty.count == 0, @"Swift some([]) remains a non-nil empty array");
        __weak NSArray *weakCopy = nil;
        @autoreleasepool {
            NSArray<NSURL *> *copy = CFBridgingRelease(ApolloTestOrderedMediaURLs());
            weakCopy = copy;
            Check(copy.count == 3, @"returned array survives the source Swift array's lifetime");
            Check([copy[0].absoluteString isEqualToString:@"https://i.redd.it/first.jpg"] && [copy[1].absoluteString isEqualToString:@"https://i.imgur.com/second.mp4"] && [copy[2] isEqual:copy[0]], @"C bridge preserves URL ordering and duplicates");
        }
        Check(weakCopy == nil, @"CFBridgingRelease balances the Swift passRetained ownership");
    }
    puts("save_all_media_bridge_tests: all 7 checks passed");
    return 0;
}
