#import "ApolloAwards.h"

%hook RDKResponseSerializer
- (id)responseObjectForResponse:(id)response data:(id)data error:(id *)error {
    id object = %orig;
    if ([response isKindOfClass:NSHTTPURLResponse.class] && (!error || !*error)) {
        ApolloAwardsObserveListingResponse(response, object);
    }
    return object;
}
%end

%ctor { %init; }
