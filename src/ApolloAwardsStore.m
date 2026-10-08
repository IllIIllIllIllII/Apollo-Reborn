#import "ApolloAwardsStore.h"
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

static NSUInteger const kAwardsStoreMaximumEntries = 500;
static NSUInteger const kAwardsStoreMaximumFileBytes = 2 * 1024 * 1024;
// Charging each entry its own binary-plist size overestimates shared strings,
// while this reserve covers the outer dictionary, keys and schema metadata.
static NSUInteger const kAwardsStoreMemoryBudget = 2 * 1024 * 1024 - 32 * 1024;
static NSTimeInterval const kAwardsStoreFreshLifetime = 300;
static NSTimeInterval const kAwardsStoreStaleLifetime = 24 * 60 * 60;

@interface ApolloAwardsStoredEntry : NSObject
@property (nonatomic, copy) NSArray<NSDictionary *> *awards;
@property (nonatomic, copy) NSDate *fetchedDate;
@property (nonatomic) NSUInteger byteCost;
@end
@implementation ApolloAwardsStoredEntry
@end

static BOOL ApolloAwardsStoreMatches(id value, NSString *pattern, NSUInteger maximumLength) {
    if (![value isKindOfClass:NSString.class] || [value length] == 0 || [value length] > maximumLength) return NO;
    return [value rangeOfString:[NSString stringWithFormat:@"\\A(?:%@)\\z", pattern]
                       options:NSRegularExpressionSearch].location != NSNotFound;
}

static NSString *ApolloAwardsStoreKey(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] > 19) return nil;
    NSString *key = [value lowercaseString];
    return ApolloAwardsStoreMatches(key, @"t[13]_[a-z0-9]{1,16}", 19) ? key : nil;
}

static BOOL ApolloAwardsStoreInteger(id value, long long minimum, long long maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number >= minimum && number <= maximum && floor(number) == number;
}

static BOOL ApolloAwardsStoreText(id value, BOOL allowEmpty) {
    if (![value isKindOfClass:NSString.class] || [value length] > 128 || (!allowEmpty && [value length] == 0)) return NO;
    return [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

static BOOL ApolloAwardsStoreAssetURL(id value, BOOL animation) {
    if (![value isKindOfClass:NSString.class] || [value length] == 0 || [value length] > 2048) return NO;
    NSURLComponents *URL = [NSURLComponents componentsWithString:value];
    if (![URL.scheme isEqualToString:@"https"] || URL.user || URL.password || URL.port || URL.query || URL.fragment ||
        ![URL.path isEqualToString:URL.percentEncodedPath] ||
        ![URL.path hasSuffix:animation ? @".json" : @"_128.png"]) return NO;
    // Keep disk data as constrained as the live parser; a corrupted cache
    // must not turn native image loading into arbitrary third-party requests.
    BOOL knownPath = ([URL.host isEqualToString:@"i.redd.it"] && [URL.path hasPrefix:@"/snoovatar/snoo_assets/marketing/"]) ||
                     ([URL.host isEqualToString:@"www.redditstatic.com"] && [URL.path hasPrefix:@"/marketplace-assets/v1/core/awards/"]);
    if (!knownPath) return NO;
    for (NSString *part in URL.path.pathComponents) {
        if ([part isEqualToString:@"."] || [part isEqualToString:@".."]) return NO;
    }
    return YES;
}

static BOOL ApolloAwardsStoreIconURL(id value) {
    return ApolloAwardsStoreAssetURL(value, NO);
}

static NSArray<NSDictionary *> *ApolloAwardsStoreValidatedAwards(id value) {
    if (![value isKindOfClass:NSArray.class] || [value count] > 128) return nil;
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:[value count]];
    NSMutableSet *seen = [NSMutableSet set];
    for (id object in value) {
        if (![object isKindOfClass:NSDictionary.class]) return nil;
        NSDictionary *award = object;
        NSString *identifier = award[@"id"];
        if (!ApolloAwardsStoreMatches(identifier, @"award_[A-Za-z0-9_-]{1,120}", 126) || [seen containsObject:identifier] ||
            !ApolloAwardsStoreText(award[@"name"], NO) || !ApolloAwardsStoreText(award[@"description"], YES) ||
            !ApolloAwardsStoreInteger(award[@"count"], 1, 999999999) || !ApolloAwardsStoreIconURL(award[@"icon_url"]) ||
            !ApolloAwardsStoreInteger(award[@"icon_width"], 128, 128) || !ApolloAwardsStoreInteger(award[@"icon_height"], 128, 128)) return nil;
        id icons = award[@"resized_icons"];
        if (![icons isKindOfClass:NSArray.class] || [icons count] != 1 || ![icons[0] isKindOfClass:NSDictionary.class]) return nil;
        NSDictionary *icon = icons[0];
        if (!ApolloAwardsStoreIconURL(icon[@"url"]) || ![icon[@"url"] isEqual:award[@"icon_url"]] ||
            !ApolloAwardsStoreInteger(icon[@"width"], 128, 128) || !ApolloAwardsStoreInteger(icon[@"height"], 128, 128)) return nil;
        [seen addObject:identifier];
        // Rebuild an immutable allowlist instead of keeping mutable caller
        // objects or unknown serialized fields in the shared cache.
        NSMutableDictionary *validated = [@{@"id": [identifier copy], @"name": [award[@"name"] copy],
                           @"description": [award[@"description"] copy], @"count": @([award[@"count"] longLongValue]),
                           @"icon_url": [award[@"icon_url"] copy], @"icon_width": @128, @"icon_height": @128,
                           @"resized_icons": @[@{@"url": [icon[@"url"] copy], @"width": @128, @"height": @128}]} mutableCopy];
        // An invalid optional animation must not discard otherwise valid
        // static awards. Apply the same CDN/path contract as the live parser.
        if (ApolloAwardsStoreAssetURL(award[@"animation_url"], YES)) {
            validated[@"animation_url"] = [award[@"animation_url"] copy];
        }
        [result addObject:[validated copy]];
    }
    return [result copy];
}

static BOOL ApolloAwardsStoreUsable(ApolloAwardsStoredEntry *entry, NSDate *now, BOOL allowStale) {
    NSTimeInterval age = [now timeIntervalSinceDate:entry.fetchedDate];
    NSTimeInterval lifetime = allowStale && entry.awards.count > 0 ? kAwardsStoreStaleLifetime : kAwardsStoreFreshLifetime;
    // A small clock adjustment is harmless, but a corrupt/far-future timestamp
    // must not keep data fresh indefinitely.
    return isfinite(age) && age >= -60 && age < lifetime;
}

static ApolloAwardsStoredEntry *ApolloAwardsStoreEntry(id awards, id fetchedDate) {
    if (![fetchedDate isKindOfClass:NSDate.class] || !isfinite([fetchedDate timeIntervalSinceReferenceDate])) return nil;
    NSArray *validated = ApolloAwardsStoreValidatedAwards(awards);
    if (!validated) return nil;
    NSData *encoded = [NSPropertyListSerialization dataWithPropertyList:@{@"fetchedDate": fetchedDate, @"awards": validated}
                                                                format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!encoded || encoded.length > kAwardsStoreMemoryBudget) return nil;
    ApolloAwardsStoredEntry *entry = [ApolloAwardsStoredEntry new];
    entry.awards = validated;
    entry.fetchedDate = fetchedDate;
    entry.byteCost = encoded.length;
    return entry;
}

@implementation ApolloAwardsStore {
    NSURL *_fileURL;
    NSLock *_lock;
    NSMutableDictionary<NSString *, ApolloAwardsStoredEntry *> *_entries;
    NSUInteger _byteCost;
}

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    if ((self = [super init])) {
        _fileURL = [fileURL copy];
        _lock = [NSLock new];
        _entries = [NSMutableDictionary new];
    }
    return self;
}

- (void)removeKeyLocked:(NSString *)key {
    ApolloAwardsStoredEntry *entry = _entries[key];
    _byteCost -= entry.byteCost;
    [_entries removeObjectForKey:key];
}

- (void)pruneLockedAtDate:(NSDate *)now {
    for (NSString *key in _entries.allKeys) {
        if (!ApolloAwardsStoreUsable(_entries[key], now, YES)) [self removeKeyLocked:key];
    }
    while (_entries.count > kAwardsStoreMaximumEntries || _byteCost > kAwardsStoreMemoryBudget) {
        NSString *oldest = nil;
        for (NSString *key in _entries) {
            if (!oldest || [_entries[key].fetchedDate compare:_entries[oldest].fetchedDate] == NSOrderedAscending ||
                ([_entries[key].fetchedDate isEqual:_entries[oldest].fetchedDate] && [key compare:oldest] == NSOrderedAscending)) oldest = key;
        }
        if (!oldest) break;
        [self removeKeyLocked:oldest];
    }
}

- (NSArray<NSDictionary *> *)awardsForFullName:(NSString *)fullName allowStale:(BOOL)allowStale now:(NSDate *)now {
    NSString *key = ApolloAwardsStoreKey(fullName);
    if (!key || ![now isKindOfClass:NSDate.class]) return nil;
    [_lock lock];
    ApolloAwardsStoredEntry *entry = _entries[key];
    NSArray *awards = entry && ApolloAwardsStoreUsable(entry, now, allowStale) ? entry.awards : nil;
    [_lock unlock];
    return awards;
}

- (void)storeAwards:(NSArray<NSDictionary *> *)awards forFullName:(NSString *)fullName atDate:(NSDate *)date {
    NSString *key = ApolloAwardsStoreKey(fullName);
    if (!key) return;
    ApolloAwardsStoredEntry *entry = ApolloAwardsStoreEntry(awards, date);
    NSDate *now = [NSDate date];
    if (!entry || !ApolloAwardsStoreUsable(entry, now, YES)) return;
    [_lock lock];
    ApolloAwardsStoredEntry *existing = _entries[key];
    if (!existing || [existing.fetchedDate compare:date] != NSOrderedDescending) {
        if (existing) [self removeKeyLocked:key];
        _entries[key] = entry;
        _byteCost += entry.byteCost;
    }
    [self pruneLockedAtDate:now];
    [_lock unlock];
}

- (void)load {
    if (!_fileURL.isFileURL) return;
    NSNumber *size = nil;
    if (![_fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil] || size.unsignedLongLongValue > kAwardsStoreMaximumFileBytes) return;
    NSData *data = [NSData dataWithContentsOfURL:_fileURL options:0 error:nil];
    if (!data || data.length > kAwardsStoreMaximumFileBytes) return;
    id root = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    if (![root isKindOfClass:NSDictionary.class] || !ApolloAwardsStoreInteger(root[@"schemaVersion"], 1, 1)) return;
    id records = root[@"entries"];
    if (![records isKindOfClass:NSDictionary.class] || [records count] > kAwardsStoreMaximumEntries) return;
    NSDate *now = [NSDate date];
    NSMutableDictionary *loaded = [NSMutableDictionary new];
    for (id fullName in records) {
        NSString *key = ApolloAwardsStoreKey(fullName);
        id record = records[fullName];
        if (!key || ![record isKindOfClass:NSDictionary.class]) continue;
        ApolloAwardsStoredEntry *entry = ApolloAwardsStoreEntry(record[@"awards"], record[@"fetchedDate"]);
        if (entry && ApolloAwardsStoreUsable(entry, now, YES)) {
            ApolloAwardsStoredEntry *previous = loaded[key];
            if (!previous || [previous.fetchedDate compare:entry.fetchedDate] == NSOrderedAscending) loaded[key] = entry;
        }
    }
    [_lock lock];
    for (NSString *key in loaded) {
        ApolloAwardsStoredEntry *existing = _entries[key];
        ApolloAwardsStoredEntry *entry = loaded[key];
        // Network results may arrive before asynchronous startup hydration.
        // A saved value may replace only an older memory value, never an equal
        // timestamp that could already have a corrected in-memory payload.
        if (existing && [existing.fetchedDate compare:entry.fetchedDate] != NSOrderedAscending) continue;
        if (existing) [self removeKeyLocked:key];
        _entries[key] = entry;
        _byteCost += entry.byteCost;
    }
    [self pruneLockedAtDate:now];
    [_lock unlock];
}

- (void)save {
    if (!_fileURL.isFileURL) return;
    [_lock lock];
    [self pruneLockedAtDate:[NSDate date]];
    NSDictionary *snapshot = [_entries copy];
    [_lock unlock];
    NSMutableDictionary *records = [NSMutableDictionary new];
    for (NSString *key in snapshot) {
        ApolloAwardsStoredEntry *entry = snapshot[key];
        records[key] = @{@"fetchedDate": entry.fetchedDate, @"awards": entry.awards};
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"schemaVersion": @1, @"entries": records}
                                                                format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data || data.length > kAwardsStoreMaximumFileBytes) return;
    [[NSFileManager defaultManager] createDirectoryAtURL:_fileURL.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToURL:_fileURL options:NSDataWritingAtomic error:nil];
}

- (void)expireFreshnessForFullName:(NSString *)fullName {
    NSString *key = ApolloAwardsStoreKey(fullName);
    if (!key) return;
    [_lock lock];
    ApolloAwardsStoredEntry *entry = _entries[key];
    if (entry.awards.count == 0) {
        if (entry) [self removeKeyLocked:key];
    } else if ([entry.fetchedDate timeIntervalSinceNow] > -kAwardsStoreFreshLifetime) {
        // Entries are immutable once published to a save snapshot; replace
        // this record instead of mutating an in-progress disk write's date.
        ApolloAwardsStoredEntry *stale = [ApolloAwardsStoredEntry new];
        stale.awards = entry.awards;
        stale.fetchedDate = [NSDate dateWithTimeIntervalSinceNow:-kAwardsStoreFreshLifetime - 1];
        stale.byteCost = entry.byteCost;
        _entries[key] = stale;
    }
    [_lock unlock];
}

@end
