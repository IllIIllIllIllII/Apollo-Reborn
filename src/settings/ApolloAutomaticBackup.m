#import "settings/ApolloAutomaticBackup.h"

#import <UIKit/UIKit.h>
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloBackupRestore.h"

NSNotificationName const ApolloAutomaticBackupDidChangeNotification = @"ApolloAutomaticBackupDidChangeNotification";

static NSString *const kBackupDirectoryName = @"Apollo Reborn Backups";
static NSTimeInterval const kRetryInterval = 15 * 60;
static NSUInteger const kBackupsToKeep = 5;

// A job can be cancelled by expiration or restore without waiting for the worker:
// archive capture sometimes dispatches to main, so waiting here would deadlock.
@interface ApolloAutomaticBackupJob : NSObject
@property (atomic, getter=isCancelled) BOOL cancelled;
@property (atomic, strong) NSFileCoordinator *coordinator;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTask;
- (void)cancel;
@end

@implementation ApolloAutomaticBackupJob
- (instancetype)init {
    if ((self = [super init])) _backgroundTask = UIBackgroundTaskInvalid;
    return self;
}
- (void)cancel {
    self.cancelled = YES;
    [self.coordinator cancel];
}
@end

static NSError *ApolloAutomaticBackupError(NSString *message) {
    return [NSError errorWithDomain:@"ApolloAutomaticBackup" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSInteger ApolloAutomaticBackupDays(NSInteger days) {
    switch (days) {
        case 1: case 3: case 7: case 14: case 30: return days;
        default: return 3;
    }
}

static NSURL *ApolloAutomaticBackupDocumentsURL(void) {
    return [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                inDomains:NSUserDomainMask].firstObject;
}

static NSURL *ApolloAutomaticBackupLocalDirectory(void) {
    return [ApolloAutomaticBackupDocumentsURL() URLByAppendingPathComponent:kBackupDirectoryName isDirectory:YES];
}

static NSURL *ApolloAutomaticBackupStateURL(void) {
    NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"ApolloReborn/AutomaticBackups/state.plist"];
}

// Match only our exact naming scheme. Retention additionally requires this
// installation's random ID, so another phone's or a manual backup is never pruned.
static BOOL ApolloAutomaticBackupIsArchiveName(NSString *name, NSString *installationID) {
    NSString *identifier = installationID
        ? [NSRegularExpression escapedPatternForString:installationID]
        : @"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}";
    NSString *pattern = [NSString stringWithFormat:
        @"^Apollo_Auto_Backup_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}_[0-9]{3}_%@\\.zip$", identifier];
    return [name rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

static BOOL ApolloAutomaticBackupDirectoryIsUsable(NSURL *directory, NSError **error) {
    // attributesOfItemAtPath reports a final symlink itself, rather than following
    // it. Do not let a replaced backup subfolder redirect writes or retention.
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:directory.path error:error];
    if ([attributes[NSFileType] isEqualToString:NSFileTypeDirectory]) return YES;
    if (error) *error = ApolloAutomaticBackupError(@"The backup folder is unavailable. Choose a folder again in Files.");
    return NO;
}

// Coordinate each affected item, including local files that Files may be reading.
// A coordinated write to an ordinary directory does not lock its descendants.
// These helpers finish their coordination before a caller starts another one.
static BOOL ApolloAutomaticBackupReadItem(
    NSURL *url, ApolloAutomaticBackupJob *job, NSError **outError,
    BOOL (^accessor)(NSURL *coordinatedURL, NSError **error)) {
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    job.coordinator = coordinator;
    __block BOOL success = NO;
    __block NSError *workError = nil;
    NSError *coordinationError = nil;
    @try {
        if (!job.isCancelled) {
            [coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *newURL) {
                if (!job.isCancelled) success = accessor(newURL, &workError);
            }];
        }
    } @finally {
        job.coordinator = nil;
    }
    if (coordinationError || !success) {
        if (outError) *outError = workError ?: ApolloAutomaticBackupError(
            job.isCancelled ? @"Backup was interrupted. It will be retried when Apollo is open."
                            : @"The backup folder is unavailable. Reconnect it or choose a folder again in Files.");
        return NO;
    }
    return YES;
}

static BOOL ApolloAutomaticBackupWriteItems(
    NSURL *url, NSFileCoordinatorWritingOptions options,
    NSURL *secondURL, NSFileCoordinatorWritingOptions secondOptions,
    ApolloAutomaticBackupJob *job, NSError **outError,
    BOOL (^accessor)(NSURL *coordinatedURL, NSURL *coordinatedSecondURL, NSError **error)) {
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    job.coordinator = coordinator;
    __block BOOL success = NO;
    __block NSError *workError = nil;
    NSError *coordinationError = nil;
    @try {
        if (!job.isCancelled) {
            if (secondURL) {
                [coordinator coordinateWritingItemAtURL:url options:options
                                      writingItemAtURL:secondURL options:secondOptions
                                                 error:&coordinationError
                                            byAccessor:^(NSURL *newURL, NSURL *newSecondURL) {
                    if (!job.isCancelled) success = accessor(newURL, newSecondURL, &workError);
                }];
            } else {
                [coordinator coordinateWritingItemAtURL:url options:options error:&coordinationError
                                            byAccessor:^(NSURL *newURL) {
                    if (!job.isCancelled) success = accessor(newURL, nil, &workError);
                }];
            }
        }
    } @finally {
        job.coordinator = nil;
    }
    if (coordinationError || !success) {
        if (outError) *outError = workError ?: ApolloAutomaticBackupError(
            job.isCancelled ? @"Backup was interrupted. It will be retried when Apollo is open."
                            : @"The backup folder is unavailable. Reconnect it or choose a folder again in Files.");
        return NO;
    }
    return YES;
}

static NSArray<NSURL *> *ApolloAutomaticBackupArchives(NSURL *directory, NSString *installationID) {
    if (!ApolloAutomaticBackupDirectoryIsUsable(directory, nil)) return @[];
    NSArray<NSURL *> *contents = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:directory
        includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray<NSURL *> *archives = [NSMutableArray array];
    for (NSURL *url in contents) {
        if (!ApolloAutomaticBackupIsArchiveName(url.lastPathComponent, installationID)) continue;
        NSNumber *regular = nil, *symlink = nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        [url getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
        if (regular.boolValue && !symlink.boolValue) [archives addObject:url];
    }
    [archives sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [b.lastPathComponent compare:a.lastPathComponent options:NSLiteralSearch];
    }];
    return archives;
}

static void ApolloAutomaticBackupPrune(NSURL *directory, NSString *installationID,
                                      NSURL *justSaved, ApolloAutomaticBackupJob *job) {
    __block NSArray<NSURL *> *archives = nil;
    if (!ApolloAutomaticBackupReadItem(directory, job, nil, ^BOOL(NSURL *newDirectory, NSError **error) {
        if (!ApolloAutomaticBackupDirectoryIsUsable(newDirectory, error)) return NO;
        archives = ApolloAutomaticBackupArchives(newDirectory, installationID);
        return YES;
    })) return;
    // Always keep the newly saved ZIP, including after the phone's clock moved
    // backwards. Lexical UTC timestamps order the other archives newest first.
    NSUInteger retained = 1;
    for (NSURL *url in archives) {
        if (job.isCancelled) return;
        if ([url.lastPathComponent isEqualToString:justSaved.lastPathComponent]) continue;
        if (retained++ < kBackupsToKeep) continue;
        NSError *error = nil;
        BOOL removed = ApolloAutomaticBackupWriteItems(url, NSFileCoordinatorWritingForDeleting, nil, 0,
            job, &error, ^BOOL(NSURL *newURL, __unused NSURL *unused, NSError **deleteError) {
                if (!ApolloAutomaticBackupDirectoryIsUsable(newURL.URLByDeletingLastPathComponent, deleteError)) return NO;
                // Recheck after coordination: another app may have moved or
                // replaced the item since directory enumeration completed.
                NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:newURL.path error:deleteError];
                if (!attributes) return YES; // Already removed; retention is satisfied.
                if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular] ||
                    ![newURL.lastPathComponent isEqualToString:url.lastPathComponent] ||
                    ![newURL.URLByDeletingLastPathComponent.URLByStandardizingPath.path isEqualToString:
                        url.URLByDeletingLastPathComponent.URLByStandardizingPath.path] ||
                    !ApolloAutomaticBackupIsArchiveName(newURL.lastPathComponent, installationID)) return YES;
                return [NSFileManager.defaultManager removeItemAtURL:newURL error:deleteError];
            });
        if (!removed) {
            ApolloLog(@"[AutomaticBackup] Could not prune an older archive (code %ld)", (long)error.code);
        }
    }
}

// Folder URLs from the iOS picker carry sandbox permission, even when no app-owned
// iCloud container exists. Minimal bookmarks preserve that permission on iOS;
// NSURLBookmarkCreationWithSecurityScope is a macOS-only option.
// Hold scope across the whole operation, but coordinate directory preparation,
// archive publication, and each retention deletion separately. Never wait for a
// provider on the main thread, and never nest coordinated-write accessors.
static BOOL ApolloAutomaticBackupInDirectory(
    NSURL *root, BOOL external, BOOL rootIsBackupDirectory, ApolloAutomaticBackupJob *job, NSError **outError,
    BOOL (^accessor)(NSURL *directory, NSError **error)) {
    if (!root.isFileURL) {
        if (outError) *outError = ApolloAutomaticBackupError(@"Choose the backup folder again in Files.");
        return NO;
    }
    BOOL scoped = external && [root startAccessingSecurityScopedResource];
    BOOL success = NO;
    NSError *workError = nil;
    @try {
        __block NSURL *directory = nil;
        BOOL rootReady = ApolloAutomaticBackupReadItem(root, job, &workError, ^BOOL(NSURL *newRoot, NSError **readError) {
            if (!ApolloAutomaticBackupDirectoryIsUsable(newRoot, readError)) return NO;
            directory = rootIsBackupDirectory ? newRoot
                : [newRoot URLByAppendingPathComponent:kBackupDirectoryName isDirectory:YES];
            return YES;
        });
        BOOL directoryReady = rootReady && ApolloAutomaticBackupWriteItems(directory, 0, nil, 0,
            job, &workError, ^BOOL(NSURL *newDirectory, __unused NSURL *unused, NSError **createError) {
                NSFileManager *fm = NSFileManager.defaultManager;
                if (!ApolloAutomaticBackupDirectoryIsUsable(newDirectory.URLByDeletingLastPathComponent, createError)) return NO;
                NSDictionary *existing = [fm attributesOfItemAtPath:newDirectory.path error:nil];
                if (!existing) {
                    NSDictionary *attributes = external ? nil : @{NSFileProtectionKey: NSFileProtectionComplete};
                    if (![fm createDirectoryAtURL:newDirectory withIntermediateDirectories:NO
                                       attributes:attributes error:createError]) return NO;
                }
                if (!ApolloAutomaticBackupDirectoryIsUsable(newDirectory, createError)) return NO;
                directory = newDirectory;
                return YES;
            });
        if (directoryReady && !job.isCancelled) {
            success = accessor(directory, &workError);
        }
    } @finally {
        // A resolved bookmark can be usable even when startAccessing returns NO.
        // Trust the actual coordinated I/O result, and balance only a YES start.
        if (scoped) [root stopAccessingSecurityScopedResource];
    }
    if (!success && outError) {
        *outError = workError ?: ApolloAutomaticBackupError(@"Backup was interrupted. It will be retried when Apollo is open.");
    }
    return success;
}

@interface ApolloAutomaticBackup ()
@property (nonatomic, strong) NSMutableDictionary *state;
@property (nonatomic) BOOL stateLoaded;
@property (nonatomic, copy) NSString *stateReadError;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) ApolloAutomaticBackupJob *job;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL suspendedForRestore;
@property (nonatomic, strong) NSURL *selectedFolderURL;
@property (nonatomic) BOOL selectedFolderScopeActive;
@end

@implementation ApolloAutomaticBackup

+ (instancetype)sharedManager {
    static ApolloAutomaticBackup *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [[self alloc] init]; });
    return manager;
}

- (instancetype)init {
    if ((self = [super init])) {
        // The tweak can load for a push while the phone is locked. Do not read a
        // protected file yet: an unreadable existing state is not a new install.
        _state = [NSMutableDictionary dictionary];
        _workQueue = dispatch_queue_create("app.apolloreborn.automatic-backup", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)enabled { return sAutomaticBackupsEnabled; }
- (NSInteger)intervalDays { return ApolloAutomaticBackupDays(sAutomaticBackupIntervalDays); }
- (BOOL)isBackingUp { return self.job != nil; }
- (BOOL)usesSelectedFolder { return sAutomaticBackupDestination == 1; }
- (BOOL)loadStateIfNeeded {
    if (self.stateLoaded) return YES;
    if (!UIApplication.sharedApplication.isProtectedDataAvailable) return NO;
    NSURL *url = ApolloAutomaticBackupStateURL();
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    if (!data && error.code == NSFileReadNoSuchFileError && [error.domain isEqualToString:NSCocoaErrorDomain]) {
        self.stateLoaded = YES;
        self.stateReadError = nil;
        return YES;
    }
    NSDictionary *saved = data ? [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:nil error:&error] : nil;
    if (![saved isKindOfClass:NSDictionary.class]) {
        self.stateReadError = @"Could not read the backup configuration. Unlock the phone and reopen Apollo to try again.";
        // Never overwrite an existing unreadable/corrupt file: it can still
        // contain the only usable permission bookmark for the selected folder.
        return NO;
    }
    self.state = [saved mutableCopy];
    self.stateLoaded = YES;
    self.stateReadError = nil;
    return YES;
}
- (NSString *)destinationName {
    if (!self.usesSelectedFolder) return @"On This iPhone";
    [self loadStateIfNeeded];
    id name = self.state[@"folderName"];
    return [name isKindOfClass:NSString.class] && [name length] ? name : @"Choose a Folder";
}
- (BOOL)hasSavedFolder {
    [self loadStateIfNeeded];
    return [self.state[@"folderBookmark"] isKindOfClass:NSData.class];
}
- (NSString *)savedFolderName {
    [self loadStateIfNeeded];
    id name = self.state[@"folderName"];
    return [name isKindOfClass:NSString.class] && [name length] ? name : nil;
}
- (NSString *)stateKey:(NSString *)suffix {
    return [(self.usesSelectedFolder ? @"folder" : @"local") stringByAppendingString:suffix];
}
- (NSDate *)lastBackupDate {
    [self loadStateIfNeeded];
    id date = self.state[[self stateKey:@"LastSuccess"]];
    return [date isKindOfClass:NSDate.class] ? date : nil;
}
- (NSDate *)nextBackupDate {
    if (!self.enabled) return nil;
    NSDate *last = self.lastBackupDate;
    // An implausibly future last-success after a clock correction must not defer
    // all backups until that old wall-clock date eventually comes around again.
    if (!last || last.timeIntervalSinceNow > 300) return [NSDate date];
    return [last dateByAddingTimeInterval:self.intervalDays * 24 * 60 * 60];
}
- (NSString *)lastErrorMessage {
    [self loadStateIfNeeded];
    if (self.stateReadError) return self.stateReadError;
    id message = self.state[[self stateKey:@"LastError"]];
    return [message isKindOfClass:NSString.class] ? message : nil;
}
- (NSArray<NSURL *> *)localBackupURLs {
    return ApolloAutomaticBackupArchives(ApolloAutomaticBackupLocalDirectory(), nil);
}

- (void)notifyChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloAutomaticBackupDidChangeNotification object:self];
}

- (BOOL)saveState:(NSError **)error {
    if (![self loadStateIfNeeded]) {
        if (error) *error = ApolloAutomaticBackupError(self.stateReadError ?: @"Unlock the phone and try again.");
        return NO;
    }
    NSURL *url = ApolloAutomaticBackupStateURL();
    NSURL *directory = url.URLByDeletingLastPathComponent;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *underlying = nil;
    BOOL success = [fm createDirectoryAtURL:directory withIntermediateDirectories:YES
                               attributes:@{NSFileProtectionKey: NSFileProtectionComplete} error:&underlying];
    // Permission bookmarks, installation ID and last-run state belong to this
    // installation. They must not migrate in a ZIP or an iOS device backup.
    if (success) success = [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&underlying];
    NSData *data = success ? [NSPropertyListSerialization dataWithPropertyList:self.state
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&underlying] : nil;
    success = data && [data writeToURL:url options:(NSDataWritingAtomic | NSDataWritingFileProtectionComplete)
                                error:&underlying];
    if (!success) {
        ApolloLog(@"[AutomaticBackup] Could not persist backup state (code %ld)", (long)underlying.code);
        if (error) *error = ApolloAutomaticBackupError(@"Could not save the backup configuration. Check the phone's free space and try again.");
    }
    return success;
}

- (void)start {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
        return;
    }
    if (self.started) return;
    self.started = YES;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(scheduleNextCheck) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(scheduleNextCheck) name:UIApplicationProtectedDataDidBecomeAvailable object:nil];
    [nc addObserver:self selector:@selector(scheduleNextCheck) name:UIApplicationSignificantTimeChangeNotification object:nil];
    [nc addObserver:self selector:@selector(stopTimer) name:UIApplicationWillResignActiveNotification object:nil];
    [self scheduleNextCheck];
}

- (void)stopTimer {
    [self.timer invalidate];
    self.timer = nil;
}

- (void)scheduleNextCheck {
    [self stopTimer];
    UIApplication *app = UIApplication.sharedApplication;
    if (!self.started || !self.enabled || self.isBackingUp || self.suspendedForRestore ||
        app.applicationState != UIApplicationStateActive || !app.isProtectedDataAvailable) return;
    if (![self loadStateIfNeeded]) {
        [self notifyChange];
        return;
    }
    NSTimeInterval delay = MAX(2, self.nextBackupDate.timeIntervalSinceNow);
    id attempted = self.state[[self stateKey:@"LastAttempt"]];
    NSDate *lastSuccess = self.lastBackupDate;
    BOOL previousAttemptFailed = [attempted isKindOfClass:NSDate.class] &&
        (!lastSuccess || [lastSuccess compare:attempted] == NSOrderedAscending);
    if (previousAttemptFailed && [attempted timeIntervalSinceNow] <= 300) {
        delay = MAX(delay, [attempted timeIntervalSinceNow] + kRetryInterval);
    }
    // No periodic polling: one foreground timer for the due date. An inactive app
    // has no timer; becoming active always recomputes from the last successful save.
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        [weakSelf runBackupAutomatically:YES completion:nil];
    }];
    self.timer.tolerance = MIN(60, delay / 10);
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)setEnabled:(BOOL)enabled {
    if (self.isBackingUp || self.suspendedForRestore || self.enabled == enabled) return;
    sAutomaticBackupsEnabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:UDKeyAutomaticBackupsEnabled];
    [self notifyChange];
    [self scheduleNextCheck];
}

- (void)setIntervalDays:(NSInteger)days {
    if (self.isBackingUp || self.suspendedForRestore) return;
    days = ApolloAutomaticBackupDays(days);
    if (sAutomaticBackupIntervalDays == days) return;
    sAutomaticBackupIntervalDays = days;
    [[NSUserDefaults standardUserDefaults] setInteger:days forKey:UDKeyAutomaticBackupIntervalDays];
    [self notifyChange];
    [self scheduleNextCheck];
}

- (void)useLocalFolder {
    if (self.isBackingUp || self.suspendedForRestore || !self.usesSelectedFolder) return;
    if (self.selectedFolderScopeActive) [self.selectedFolderURL stopAccessingSecurityScopedResource];
    self.selectedFolderURL = nil;
    self.selectedFolderScopeActive = NO;
    sAutomaticBackupDestination = 0;
    [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:UDKeyAutomaticBackupDestination];
    [self notifyChange];
    [self scheduleNextCheck];
}

- (void)useSavedFolderWithCompletion:(void (^)(NSError *))completion {
    if (self.isBackingUp || self.suspendedForRestore || ![self loadStateIfNeeded]) {
        completion(ApolloAutomaticBackupError(@"The previous Files folder is unavailable."));
        return;
    }
    NSData *bookmark = [self.state[@"folderBookmark"] isKindOfClass:NSData.class]
        ? self.state[@"folderBookmark"] : nil;
    if (!bookmark) {
        completion(ApolloAutomaticBackupError(@"Choose a backup location in Files first."));
        return;
    }
    dispatch_async(self.workQueue, ^{
        BOOL stale = NO;
        NSError *error = nil;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil
                                   bookmarkDataIsStale:&stale error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!url) {
                completion(ApolloAutomaticBackupError(@"Choose the backup folder again in Files."));
                return;
            }
            [self selectFolderURL:url completion:completion];
        });
    });
}

- (void)selectedFolderURLWithCompletion:(void (^)(NSURL *, NSError *))completion {
    if (self.selectedFolderURL) {
        completion(self.selectedFolderURL, nil);
        return;
    }
    if (![self loadStateIfNeeded]) {
        completion(nil, ApolloAutomaticBackupError(self.stateReadError ?: @"Unlock the phone and try again."));
        return;
    }
    NSData *bookmark = [self.state[@"folderBookmark"] isKindOfClass:NSData.class]
        ? self.state[@"folderBookmark"] : nil;
    dispatch_async(self.workQueue, ^{
        BOOL stale = NO;
        NSError *error = nil;
        NSURL *url = bookmark ? [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil
                                              bookmarkDataIsStale:&stale error:&error] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (url) {
                self.selectedFolderURL = url;
                self.selectedFolderScopeActive = [url startAccessingSecurityScopedResource];
            }
            completion(url, url ? nil : ApolloAutomaticBackupError(@"Choose the backup folder again in Files."));
        });
    });
}

- (ApolloAutomaticBackupJob *)beginJob {
    [self stopTimer];
    ApolloAutomaticBackupJob *job = [ApolloAutomaticBackupJob new];
    self.job = job;
    __weak typeof(self) weakSelf = self;
    job.backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Apollo Settings Backup"
        expirationHandler:^{
            [job cancel];
            [weakSelf endBackgroundTimeForJob:job];
        }];
    [self notifyChange];
    return job;
}

- (void)endBackgroundTimeForJob:(ApolloAutomaticBackupJob *)job {
    if (job.backgroundTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:job.backgroundTask];
        job.backgroundTask = UIBackgroundTaskInvalid;
    }
}

- (void)finishJob:(ApolloAutomaticBackupJob *)job {
    [self endBackgroundTimeForJob:job];
    if (self.job == job) self.job = nil;
    [self notifyChange];
    [self scheduleNextCheck];
}

- (void)suspendForSettingsRestore {
    self.suspendedForRestore = YES;
    [self stopTimer];
    [self.job cancel];
    ApolloLog(@"[AutomaticBackup] Suspended for settings restore until relaunch");
}

- (void)selectFolderURL:(NSURL *)url completion:(void (^)(NSError *))completion {
    if (self.isBackingUp || self.suspendedForRestore) {
        completion(ApolloAutomaticBackupError(@"Wait for the current operation to finish."));
        return;
    }
    if (![self loadStateIfNeeded]) {
        completion(ApolloAutomaticBackupError(self.stateReadError ?: @"Unlock the phone and try again."));
        return;
    }
    if (self.selectedFolderScopeActive) [self.selectedFolderURL stopAccessingSecurityScopedResource];
    self.selectedFolderURL = url;
    self.selectedFolderScopeActive = [url startAccessingSecurityScopedResource];
    NSError *bookmarkError = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
        includingResourceValuesForKeys:nil relativeToURL:nil error:&bookmarkError];
    if (!bookmark) {
        if (self.selectedFolderScopeActive) [url stopAccessingSecurityScopedResource];
        self.selectedFolderURL = nil;
        self.selectedFolderScopeActive = NO;
        completion(ApolloAutomaticBackupError(@"Could not remember this folder. Please try again."));
        return;
    }
    ApolloAutomaticBackupJob *job = [self beginJob];
    dispatch_async(self.workQueue, ^{
        @autoreleasepool {
            NSError *error = nil;
            BOOL rootIsBackupDirectory = [url.lastPathComponent isEqualToString:kBackupDirectoryName];
            BOOL success = ApolloAutomaticBackupInDirectory(url, YES, rootIsBackupDirectory, job, &error,
                ^BOOL(NSURL *directory, NSError **writeError) {
                    // A bookmark alone says nothing about write permission. Probe
                    // the folder now, before changing a working destination.
                    NSURL *probe = [directory URLByAppendingPathComponent:
                        [@".apollo-backup-probe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
                    BOOL writable = ApolloAutomaticBackupWriteItems(probe, 0, nil, 0, job, writeError,
                        ^BOOL(NSURL *newProbe, __unused NSURL *unused, NSError **probeError) {
                            if (!ApolloAutomaticBackupDirectoryIsUsable(newProbe.URLByDeletingLastPathComponent, probeError)) return NO;
                            if (![[NSData data] writeToURL:newProbe options:NSDataWritingWithoutOverwriting error:probeError]) return NO;
                            // This empty, newly created probe never escapes its
                            // exclusive item coordination or becomes a document.
                            return [NSFileManager.defaultManager removeItemAtURL:newProbe error:probeError];
                        });
                    if (!writable) return NO;
                    return !job.isCancelled;
                });
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *resultError = error;
                if (success && !job.isCancelled && !self.suspendedForRestore) {
                    NSMutableDictionary *previous = [self.state mutableCopy];
                    self.state[@"folderBookmark"] = bookmark;
                    self.state[@"folderName"] = url.lastPathComponent.length ? url.lastPathComponent : @"Files Folder";
                    self.state[@"folderIsBackupDirectory"] = @(rootIsBackupDirectory);
                    [self.state removeObjectForKey:@"folderLastSuccess"];
                    [self.state removeObjectForKey:@"folderLastAttempt"];
                    [self.state removeObjectForKey:@"folderLastError"];
                    if ([self saveState:&resultError]) {
                        sAutomaticBackupDestination = 1;
                        [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:UDKeyAutomaticBackupDestination];
                    } else {
                        self.state = previous;
                    }
                } else if (!resultError) {
                    resultError = ApolloAutomaticBackupError(@"Folder selection was interrupted. Please choose the folder again.");
                }
                [self finishJob:job];
                completion(resultError);
            });
        }
    });
}

- (void)backUpNowWithCompletion:(void (^)(NSError *))completion {
    [self runBackupAutomatically:NO completion:completion];
}

- (void)runBackupAutomatically:(BOOL)automatic completion:(void (^)(NSError *))completion {
    UIApplication *app = UIApplication.sharedApplication;
    if (self.isBackingUp || self.suspendedForRestore ||
        app.applicationState != UIApplicationStateActive || !app.isProtectedDataAvailable ||
        (automatic && (!self.enabled || self.nextBackupDate.timeIntervalSinceNow > 0))) {
        if (completion) completion(ApolloAutomaticBackupError(@"Keep Apollo open and wait for the current operation to finish, then try again."));
        [self scheduleNextCheck];
        return;
    }
    if (![self loadStateIfNeeded]) {
        [self notifyChange];
        if (completion) completion(ApolloAutomaticBackupError(self.stateReadError ?: @"Unlock the phone and try again."));
        return;
    }
    NSString *installationID = [self.state[@"installationID"] isKindOfClass:NSString.class]
        ? self.state[@"installationID"] : nil;
    if (!installationID || ![[NSUUID alloc] initWithUUIDString:installationID]) {
        installationID = NSUUID.UUID.UUIDString;
        self.state[@"installationID"] = installationID;
    }
    NSString *prefix = self.usesSelectedFolder ? @"folder" : @"local";
    self.state[[prefix stringByAppendingString:@"LastAttempt"]] = [NSDate date];
    NSError *stateError = nil;
    if (![self saveState:&stateError]) {
        self.state[[prefix stringByAppendingString:@"LastError"]] = stateError.localizedDescription;
        [self notifyChange];
        [self scheduleNextCheck];
        if (completion) completion(stateError);
        return;
    }
    BOOL external = self.usesSelectedFolder;
    NSData *bookmark = [self.state[@"folderBookmark"] isKindOfClass:NSData.class]
        ? self.state[@"folderBookmark"] : nil;
    ApolloAutomaticBackupJob *job = [self beginJob];
    ApolloLog(@"[AutomaticBackup] Starting %@ backup to %@ storage",
              automatic ? @"scheduled" : @"requested", external ? @"Files" : @"local");
    dispatch_async(self.workQueue, ^{
        @autoreleasepool {
            NSError *error = nil;
            NSURL *zip = nil;
            __block NSData *refreshedBookmark = nil;
            BOOL saved = NO;
            @try {
                BOOL stale = NO;
                NSURL *root = external ? self.selectedFolderURL : ApolloAutomaticBackupDocumentsURL();
                if (external && !root && bookmark) {
                    root = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil
                                        bookmarkDataIsStale:&stale error:&error];
                    if (root) {
                        self.selectedFolderURL = root;
                        self.selectedFolderScopeActive = [root startAccessingSecurityScopedResource];
                    }
                }
                if (!root) {
                    error = ApolloAutomaticBackupError(@"Choose the backup folder again in Files.");
                } else if (!job.isCancelled) {
                    zip = ApolloBackupRestoreCreateBackupZip(&error);
                    if (zip && !job.isCancelled) {
                        BOOL rootIsBackupDirectory = external && [self.state[@"folderIsBackupDirectory"] boolValue];
                        saved = ApolloAutomaticBackupInDirectory(root, external, rootIsBackupDirectory, job, &error,
                            ^BOOL(NSURL *directory, NSError **writeError) {
                                if (stale) {
                                    refreshedBookmark = [root bookmarkDataWithOptions:0
                                        includingResourceValuesForKeys:nil relativeToURL:nil error:writeError];
                                    if (!refreshedBookmark) return NO;
                                }
                                NSDateFormatter *formatter = [NSDateFormatter new];
                                formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
                                formatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
                                formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
                                formatter.dateFormat = @"yyyy-MM-dd_HHmmss_SSS";
                                NSString *name = [NSString stringWithFormat:@"Apollo_Auto_Backup_%@_%@.zip",
                                    [formatter stringFromDate:[NSDate date]], installationID];
                                NSURL *destination = [directory URLByAppendingPathComponent:name];
                                NSURL *pending = [directory URLByAppendingPathComponent:
                                    [NSString stringWithFormat:@".%@.%@.pending", name, NSUUID.UUID.UUIDString]];
                                __block NSURL *published = nil;
                                BOOL success = ApolloAutomaticBackupWriteItems(
                                    pending, NSFileCoordinatorWritingForMoving, destination, 0, job, writeError,
                                    ^BOOL(NSURL *newPending, NSURL *newDestination, NSError **publishError) {
                                        NSFileManager *fm = NSFileManager.defaultManager;
                                        NSURL *parent = newPending.URLByDeletingLastPathComponent;
                                        if (!ApolloAutomaticBackupDirectoryIsUsable(parent, publishError) ||
                                            ![parent.URLByStandardizingPath.path isEqualToString:
                                                newDestination.URLByDeletingLastPathComponent.URLByStandardizingPath.path]) {
                                            if (publishError) *publishError = ApolloAutomaticBackupError(@"The backup folder moved. Please try again.");
                                            return NO;
                                        }
                                        @try {
                                            if (![fm copyItemAtURL:zip toURL:newPending error:publishError]) return NO;
                                            if (!external && ![fm setAttributes:@{NSFileProtectionKey: NSFileProtectionComplete}
                                                ofItemAtPath:newPending.path error:publishError]) return NO;
                                            if (job.isCancelled) return NO;
                                            // Both names stay exclusively coordinated during
                                            // the copy and same-directory atomic publication.
                                            // A partial archive never appears under a ZIP name.
                                            NSFileCoordinator *coordinator = job.coordinator;
                                            [coordinator itemAtURL:newPending willMoveToURL:newDestination];
                                            if (![fm moveItemAtURL:newPending toURL:newDestination error:publishError]) return NO;
                                            [coordinator itemAtURL:newPending didMoveToURL:newDestination];
                                            published = newDestination;
                                            return YES;
                                        } @finally {
                                            [fm removeItemAtURL:newPending error:nil];
                                        }
                                    });
                                // The publication coordinator must have released both URLs
                                // before enumeration and separately coordinated deletions.
                                if (success) ApolloAutomaticBackupPrune(published.URLByDeletingLastPathComponent,
                                    installationID, published, job);
                                return success;
                            });
                    }
                }
            } @catch (__unused NSException *exception) {
                error = ApolloAutomaticBackupError(@"Could not complete the backup. Please try again.");
            } @finally {
                if (zip) [NSFileManager.defaultManager removeItemAtURL:zip error:nil];
            }
            BOOL interrupted = job.isCancelled;
            if (!saved || interrupted) {
                error = error ?: ApolloAutomaticBackupError(@"Backup was interrupted. It will be retried when Apollo is open.");
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *resultError = error;
                if (!self.suspendedForRestore) {
                    if (saved && !interrupted) {
                        self.state[[prefix stringByAppendingString:@"LastSuccess"]] = [NSDate date];
                        [self.state removeObjectForKey:[prefix stringByAppendingString:@"LastError"]];
                        if (refreshedBookmark) self.state[@"folderBookmark"] = refreshedBookmark;
                        ApolloLog(@"[AutomaticBackup] Archive saved to %@ storage", external ? @"Files" : @"local");
                    } else {
                        // Store a useful status, without logging paths, file contents,
                        // usernames, or any provider's detailed error description.
                        self.state[[prefix stringByAppendingString:@"LastError"]] = resultError.localizedDescription;
                        ApolloLog(@"[AutomaticBackup] Backup failed or was interrupted (code %ld)", (long)resultError.code);
                    }
                    NSError *persistError = nil;
                    if (![self saveState:&persistError] && !resultError) {
                        resultError = ApolloAutomaticBackupError(@"Backup was saved, but its schedule could not be remembered. Check the phone's free space.");
                        self.state[[prefix stringByAppendingString:@"LastError"]] = resultError.localizedDescription;
                    }
                }
                [self finishJob:job];
                if (completion) completion(resultError);
            });
        }
    });
}

- (void)prepareLocalBackupAtURL:(NSURL *)url completion:(void (^)(NSURL *, NSError *))completion {
    if (self.isBackingUp || self.suspendedForRestore) {
        completion(nil, ApolloAutomaticBackupError(@"Wait for the current operation to finish."));
        return;
    }
    ApolloAutomaticBackupJob *job = [self beginJob];
    dispatch_async(self.workQueue, ^{
        @autoreleasepool {
            NSURL *directory = ApolloAutomaticBackupLocalDirectory().URLByResolvingSymlinksInPath;
            NSURL *candidate = url.URLByResolvingSymlinksInPath;
            BOOL owned = [candidate.URLByDeletingLastPathComponent.path isEqualToString:directory.path] &&
                         ApolloAutomaticBackupIsArchiveName(url.lastPathComponent, nil);
            NSError *error = nil;
            NSURL *copy = nil;
            if (owned && !job.isCancelled) {
                NSString *name = [NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, url.lastPathComponent];
                copy = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:name];
                if (![NSFileManager.defaultManager copyItemAtURL:url toURL:copy error:&error]) copy = nil;
            }
            if (!copy || job.isCancelled) {
                if (copy) [NSFileManager.defaultManager removeItemAtURL:copy error:nil];
                copy = nil;
                error = ApolloAutomaticBackupError(@"This backup is no longer available. Refresh the list and choose another backup.");
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishJob:job];
                completion(copy, error);
            });
        }
    });
}

@end
