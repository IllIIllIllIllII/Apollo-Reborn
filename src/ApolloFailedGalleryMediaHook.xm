#import "ApolloFailedGalleryMedia.h"
#import "ApolloCommon.h"

// Every Reddit response Apollo parses passes through RDKResponseSerializer,
// for API-key and API-Key-Free accounts alike. AFNetworking runs it on its
// processing queue, so the i.redd.it lookups never block the main thread;
// a main-thread pass (none known) is left alone rather than waited on.
@interface RDKResponseSerializer : NSObject
@end

%hook RDKResponseSerializer
- (id)responseObjectForResponse:(id)response data:(id)data error:(id *)error {
    if ([data isKindOfClass:NSData.class] && ![NSThread isMainThread]) {
        @try {
            data = ApolloRepairFailedGalleryMedia(data, ApolloFailedGalleryNetworkResolver());
        } @catch (NSException *exception) {
            ApolloLog(@"[FailedGallery] Repair failed: %@", exception.reason);
        }
    }
    return %orig(response, data, error);
}
%end
