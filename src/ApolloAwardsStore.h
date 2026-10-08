#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A bounded cache of public award metadata. load/save do synchronous disk work;
// call them on a serial background queue. Lookups and mutations only use memory
// and are safe from Texture's background model/layout threads.
@interface ApolloAwardsStore : NSObject
- (instancetype)initWithFileURL:(NSURL *)fileURL;
- (void)load;
- (void)save;
- (void)expireFreshnessForFullName:(NSString *)fullName;
- (nullable NSArray<NSDictionary *> *)awardsForFullName:(NSString *)fullName
                                           allowStale:(BOOL)allowStale
                                                  now:(NSDate *)now;
- (void)storeAwards:(NSArray<NSDictionary *> *)awards
       forFullName:(NSString *)fullName
            atDate:(NSDate *)date;
@end

NS_ASSUME_NONNULL_END
