// Interval-based settings archives. Scheduling and UI-facing state are main-thread
// owned; archive compression and coordinated Files-provider I/O run off main.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS
extern NSNotificationName const ApolloAutomaticBackupDidChangeNotification;
__END_DECLS

@interface ApolloAutomaticBackup : NSObject
+ (instancetype)sharedManager;

// Called after the tweak's defaults and account-recovery setup have loaded.
- (void)start;
- (void)suspendForSettingsRestore;

@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) NSInteger intervalDays;
@property (nonatomic, readonly, getter=isBackingUp) BOOL backingUp;
@property (nonatomic, readonly) BOOL usesSelectedFolder;
@property (nonatomic, readonly) NSString *destinationName;
@property (nonatomic, readonly) BOOL hasSavedFolder;
@property (nonatomic, readonly, nullable) NSString *savedFolderName;
@property (nonatomic, readonly, nullable) NSDate *lastBackupDate;
@property (nonatomic, readonly, nullable) NSDate *nextBackupDate;
@property (nonatomic, readonly, nullable) NSString *lastErrorMessage;
@property (nonatomic, readonly) NSArray<NSURL *> *localBackupURLs; // newest first

- (void)setEnabled:(BOOL)enabled;
- (void)setIntervalDays:(NSInteger)days; // supported values: 1, 3, 7, 14, 30
- (void)useLocalFolder;
- (void)useSavedFolderWithCompletion:(void (^)(NSError *_Nullable error))completion;
- (void)selectedFolderURLWithCompletion:(void (^)(NSURL *_Nullable folderURL, NSError *_Nullable error))completion;
// Pass the original folder URL from a UTTypeFolder document picker (asCopy:NO).
// Creates an Apollo Reborn Backups subfolder and remembers the folder permission.
// Completion, like every public completion below, is delivered on the main queue.
- (void)selectFolderURL:(NSURL *)url completion:(void (^)(NSError *_Nullable error))completion;
- (void)backUpNowWithCompletion:(void (^)(NSError *_Nullable error))completion;

// An independent temporary copy remains available while a share/restore UI is up,
// even if retention later removes the original. The caller removes the copy after use.
- (void)prepareLocalBackupAtURL:(NSURL *)url
                    completion:(void (^)(NSURL *_Nullable copyURL, NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
