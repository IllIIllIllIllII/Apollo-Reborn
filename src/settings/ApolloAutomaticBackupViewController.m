#import "settings/ApolloAutomaticBackupViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>
#import <stdlib.h>

#import "ApolloCommon.h"
#import "settings/ApolloAutomaticBackup.h"
#import "settings/ApolloBackupRestore.h"

static NSString *ApolloBackupDateDescription(NSDate *date) {
    if (!date) return @"Never";
    return [NSDateFormatter localizedStringFromDate:date
                                          dateStyle:NSDateFormatterMediumStyle
                                          timeStyle:NSDateFormatterShortStyle];
}

static NSString *ApolloLocalBackupTitle(NSURL *url) {
    NSDate *date = nil;
    [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
    return date ? ApolloBackupDateDescription(date) : @"Settings Backup";
}

static NSString *ApolloLocalBackupDetail(NSURL *url) {
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (!size) return @"Settings and accounts";
    NSString *sizeDescription = [NSByteCountFormatter stringFromByteCount:size.longLongValue
                                                              countStyle:NSByteCountFormatterCountStyleFile];
    return [NSString stringWithFormat:@"Settings and accounts · %@", sizeDescription];
}

static void ApolloBackupShowAlert(UIViewController *presenter, NSString *title, NSString *message) {
    if (!presenter) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

@interface ApolloLocalBackupsViewController : ApolloSettingsFormViewController <UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@property (nonatomic) BOOL refreshScheduled;
@property (nonatomic) BOOL preparingCopy;
@property (nonatomic, strong) NSURL *pendingBackupURL;
@end

@interface ApolloAutomaticBackupViewController () <UIDocumentPickerDelegate>
@property (nonatomic) BOOL refreshScheduled;
@property (nonatomic) BOOL refreshingRows;
@property (nonatomic) BOOL refreshRequested;
@property (nonatomic) BOOL acceptingFolderSelection;
@property (nonatomic, strong) NSURL *folderExportTemplateURL;
@end

@implementation ApolloAutomaticBackupViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Automatic Backups";
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(backupStateDidChange:)
                                               name:ApolloAutomaticBackupDidChangeNotification
                                             object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshBackupRows];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;
    ApolloAutomaticBackup *manager = ApolloAutomaticBackup.sharedManager;
    BOOL (^canConfigure)(void) = ^BOOL { return !manager.isBackingUp; };

    ApolloSettingsRow *enabled = [ApolloSettingsRow switchRowWithID:@"automatic.enabled"
                                                             title:@"Automatic Backups"
                                                              isOn:^BOOL { return manager.enabled; }
                                                          onToggle:^(UISwitch *sender) {
        [manager setEnabled:sender.isOn];
    }];
    enabled.enabled = canConfigure;

    ApolloSettingsRow *interval = [ApolloSettingsRow valueRowWithID:@"automatic.interval"
                                                              title:@"Interval"
                                                             detail:^NSString * {
        return manager.intervalDays == 1 ? @"Every Day"
            : [NSString stringWithFormat:@"Every %ld Days", (long)manager.intervalDays];
    }
                                                           onSelect:^{ [weakSelf chooseInterval]; }];
    interval.enabled = canConfigure;
    interval.configure = ^(UITableViewCell *cell) { cell.detailTextLabel.numberOfLines = 1; };

    ApolloSettingsRow *destination = [ApolloSettingsRow valueRowWithID:@"automatic.destination"
                                                                 title:@"Save To"
                                                                detail:^NSString * {
        return manager.usesSelectedFolder ? @"Files Folder" : @"On This iPhone";
    }
                                                              onSelect:^{ [weakSelf chooseDestination]; }];
    destination.enabled = canConfigure;
    destination.configure = ^(UITableViewCell *cell) { cell.detailTextLabel.numberOfLines = 1; };

    ApolloSettingsRow *folder = [ApolloSettingsRow customRowWithID:@"automatic.folder"
                                                             cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AutomaticBackupFolder"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"AutomaticBackupFolder"];
        cell.textLabel.text = @"Selected Folder";
        cell.detailTextLabel.text = manager.destinationName;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        [weakSelf apollo_applyPrimaryTextColorToCell:cell];
        return cell;
    } onSelect:nil];
    folder.visible = ^BOOL { return manager.usesSelectedFolder; };

    ApolloSettingsRow *lastBackup = [ApolloSettingsRow valueRowWithID:@"automatic.lastBackup"
                                                                 title:@"Last Backup"
                                                                detail:^NSString * { return ApolloBackupDateDescription(manager.lastBackupDate); }
                                                              onSelect:nil];
    lastBackup.configure = ^(UITableViewCell *cell) { cell.detailTextLabel.numberOfLines = 0; };

    ApolloSettingsRow *nextBackup = [ApolloSettingsRow valueRowWithID:@"automatic.nextBackup"
                                                                 title:@"Next Backup"
                                                                detail:^NSString * {
        NSDate *next = manager.nextBackupDate;
        if (!next || next.timeIntervalSinceNow <= 0) return @"When Apollo Is Open";
        return ApolloBackupDateDescription(next);
    } onSelect:nil];
    nextBackup.visible = ^BOOL { return manager.enabled; };
    nextBackup.configure = ^(UITableViewCell *cell) { cell.detailTextLabel.numberOfLines = 0; };

    ApolloSettingsRow *status = [ApolloSettingsRow customRowWithID:@"automatic.status"
                                                             cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AutomaticBackupStatus"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"AutomaticBackupStatus"];
        cell.textLabel.text = @"Status";
        cell.detailTextLabel.text = manager.isBackingUp ? @"Please Wait…"
            : (manager.lastErrorMessage ?: (manager.enabled ? @"Ready" : @"Automatic Backups Off"));
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        [weakSelf apollo_applyPrimaryTextColorToCell:cell];
        return cell;
    } onSelect:nil];

    ApolloSettingsRow *backupNow = [ApolloSettingsRow customRowWithID:@"automatic.backupNow"
                                                                cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
        // Isolate the busy-state alpha from the form's shared button reuse pool.
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AutomaticBackupNow"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"AutomaticBackupNow"];
        cell.textLabel.text = @"Back Up Now";
        cell.textLabel.numberOfLines = 0;
        [weakSelf apollo_applyAccentActionTextColorToCell:cell];
        cell.contentView.alpha = manager.isBackingUp ? 0.4 : 1.0;
        cell.selectionStyle = manager.isBackingUp ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
        return cell;
    } onSelect:^{ [weakSelf backUpNow]; }];
    backupNow.enabled = canConfigure;

    ApolloSettingsRow *localBackups = [ApolloSettingsRow disclosureRowWithID:@"automatic.localBackups"
                                                                      title:@"Local Backups"
                                                                     detail:^NSString * {
        return [NSString stringWithFormat:@"%lu", (unsigned long)manager.localBackupURLs.count];
    } push:^UIViewController * {
        return [[ApolloLocalBackupsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    }];
    localBackups.configure = ^(UITableViewCell *cell) { cell.detailTextLabel.numberOfLines = 1; };

    return @[
        [ApolloSettingsSection sectionWithTitle:nil
                                          footer:@"Backups run while Apollo is open, or the next time you open it after the interval has passed."
                                            rows:@[enabled]],
        [ApolloSettingsSection sectionWithTitle:@"Schedule & Location"
                                          footer:@"Choose a location in Files, including iCloud Drive. Apollo creates an Apollo Backup Location folder there, with backups in its Apollo Reborn Backups subfolder. Each destination keeps the latest five backups from this installation."
                                            rows:@[interval, destination, folder]],
        [ApolloSettingsSection sectionWithTitle:@"Backup Status"
                                          footer:@"Backup archives are unencrypted and contain your API keys and login credentials. Keep them private."
                                            rows:@[lastBackup, nextBackup, status, backupNow]],
        [ApolloSettingsSection sectionWithTitle:nil
                                          footer:@"Local backups are deleted if you delete Apollo. Open Local Backups to export a copy or restore one. Use Restore Settings in Data for backup ZIPs saved in Files."
                                            rows:@[localBackups]],
    ];
}

- (void)backupStateDidChange:(__unused NSNotification *)notification {
    // Setters can notify synchronously from a switch handler. Defer the row
    // reload so UIKit finishes delivering that control event before replacing
    // its cell, and coalesce the saving/status notifications from one turn.
    if (self.refreshScheduled) return;
    self.refreshScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.refreshScheduled = NO;
        [weakSelf refreshBackupRows];
    });
}

- (void)refreshBackupRows {
    if (!self.isViewLoaded) return;
    if (self.refreshingRows) {
        self.refreshRequested = YES;
        return;
    }
    self.refreshingRows = YES;
    __weak typeof(self) weakSelf = self;
    // The form ends its beginUpdates/endUpdates block synchronously, but the
    // inserted/deleted cells can still be animating. Wait for that transaction
    // before reloading any surviving rows, and serialize subsequent refreshes.
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            for (NSString *rowID in @[@"automatic.enabled", @"automatic.interval", @"automatic.destination",
                                      @"automatic.folder", @"automatic.lastBackup", @"automatic.nextBackup",
                                      @"automatic.status", @"automatic.backupNow", @"automatic.localBackups"]) {
                [strongSelf reloadRowWithID:rowID];
            }
            strongSelf.refreshingRows = NO;
            if (strongSelf.refreshRequested) {
                strongSelf.refreshRequested = NO;
                [strongSelf refreshBackupRows];
            }
        });
    }];
    [self visibilityDidChange];
    [CATransaction commit];
}

- (void)chooseInterval {
    ApolloAutomaticBackup *manager = ApolloAutomaticBackup.sharedManager;
    if (manager.isBackingUp) return;
    NSArray<NSNumber *> *days = @[@1, @3, @7, @14, @30];
    NSUInteger current = [days indexOfObject:@(manager.intervalDays)];
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"automatic.interval"], @"Backup Interval",
                                @[@"Every Day", @"Every 3 Days", @"Every 7 Days", @"Every 14 Days", @"Every 30 Days"],
                                current == NSNotFound ? 1 : (NSInteger)current, ^(NSInteger pickedIndex) {
        if (!manager.isBackingUp) [manager setIntervalDays:days[(NSUInteger)pickedIndex].integerValue];
    });
}

- (void)chooseDestination {
    ApolloAutomaticBackup *manager = ApolloAutomaticBackup.sharedManager;
    if (manager.isBackingUp) return;
    __weak typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"automatic.destination"], @"Backup Location",
                                @[@"On This iPhone", @"Choose Location in Files"], manager.usesSelectedFolder ? 1 : 0,
                                ^(NSInteger pickedIndex) {
        if (manager.isBackingUp) return;
        if (pickedIndex == 0) {
            [manager useLocalFolder];
        } else {
            [weakSelf chooseFilesFolder];
        }
    });
}

- (void)chooseFilesFolder {
    NSURL *templateURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:@"Apollo Backup Location" isDirectory:YES];
    [NSFileManager.defaultManager removeItemAtURL:templateURL error:nil];
    NSError *templateError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:templateURL
                                withIntermediateDirectories:YES attributes:nil error:&templateError]) {
        ApolloBackupShowAlert(self, @"Unable to Open Files", templateError.localizedDescription);
        return;
    }
    self.folderExportTemplateURL = templateURL;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForExportingURLs:@[templateURL] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)acceptFilesFolderURL:(NSURL *)folderURL fromPicker:(UIDocumentPickerViewController *)controller {
    if (!folderURL || self.acceptingFolderSelection) return;
    self.acceptingFolderSelection = YES;
    ApolloLog(@"[AutomaticBackup] Files folder picker returned a folder");
    __weak typeof(self) weakSelf = self;
    // Accept the security-scoped URL before asking the remote Files UI to close.
    // Folder acceptance must not depend on UIKit's dismissal completion path.
    [ApolloAutomaticBackup.sharedManager selectFolderURL:folderURL completion:^(NSError *error) {
        typeof(self) strongSelf = weakSelf;
        strongSelf.acceptingFolderSelection = NO;
        ApolloLog(@"[AutomaticBackup] Files folder selection %@ (code %ld)",
                  error ? @"failed" : @"completed", (long)error.code);
        if (error) ApolloBackupShowAlert(weakSelf, @"Folder Unavailable", error.localizedDescription);
        [NSFileManager.defaultManager removeItemAtURL:strongSelf.folderExportTemplateURL error:nil];
        strongSelf.folderExportTemplateURL = nil;
    }];
    [controller dismissViewControllerAnimated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [self acceptFilesFolderURL:urls.firstObject fromPicker:controller];
}

// A few older Files providers still deliver the original single-URL delegate
// callback even when the picker was created with the modern content-type API.
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    [self acceptFilesFolderURL:url fromPicker:controller];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.acceptingFolderSelection = NO;
    [NSFileManager.defaultManager removeItemAtURL:self.folderExportTemplateURL error:nil];
    self.folderExportTemplateURL = nil;
    [controller dismissViewControllerAnimated:YES completion:nil];
}

- (void)backUpNow {
    ApolloAutomaticBackup *manager = ApolloAutomaticBackup.sharedManager;
    if (manager.isBackingUp) return;
    __weak typeof(self) weakSelf = self;
    [manager backUpNowWithCompletion:^(NSError *error) {
        if (error) ApolloBackupShowAlert(weakSelf, @"Backup Failed", error.localizedDescription);
        else ApolloBackupShowAlert(weakSelf, @"Backup Complete", @"Your settings backup was saved to the selected location.");
    }];
}

@end

@implementation ApolloLocalBackupsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Local Backups";
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(backupStateDidChange:)
                                               name:ApolloAutomaticBackupDidChangeNotification
                                             object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshLocalBackups];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_pendingBackupURL) [NSFileManager.defaultManager removeItemAtURL:_pendingBackupURL error:nil];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;
    ApolloAutomaticBackup *manager = ApolloAutomaticBackup.sharedManager;
    NSArray<NSURL *> *urls = manager.localBackupURLs;
    NSMutableArray<ApolloSettingsRow *> *rows = [NSMutableArray array];

    // This stable identity remains in the model even when hidden, so a dynamic
    // archive list can rebuild its one section without table-index arithmetic.
    ApolloSettingsRow *empty = [ApolloSettingsRow customRowWithID:@"local.backups.anchor"
                                                            cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LocalBackupsEmpty"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LocalBackupsEmpty"];
        cell.textLabel.text = @"No Local Backups";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    } onSelect:nil];
    empty.visible = ^BOOL { return urls.count == 0; };
    [rows addObject:empty];

    for (NSURL *url in urls) {
        NSString *rowID = [@"local.backup." stringByAppendingString:url.lastPathComponent];
        ApolloSettingsRow *backup = [ApolloSettingsRow customRowWithID:rowID
                                                                 cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LocalBackupArchive"];
            if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"LocalBackupArchive"];
            cell.textLabel.text = ApolloLocalBackupTitle(url);
            cell.textLabel.numberOfLines = 0;
            cell.detailTextLabel.text = ApolloLocalBackupDetail(url);
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            BOOL enabled = !manager.isBackingUp && !weakSelf.preparingCopy;
            cell.textLabel.enabled = enabled;
            cell.contentView.alpha = enabled ? 1.0 : 0.4;
            cell.accessoryType = enabled ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
            cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
            if (enabled) [weakSelf apollo_applyPrimaryTextColorToCell:cell];
            return cell;
        } onSelect:^{ [weakSelf showActionsForBackupURL:url rowID:rowID]; }];
        backup.enabled = ^BOOL { return !manager.isBackingUp && !weakSelf.preparingCopy; };
        [rows addObject:backup];
    }

    return @[[ApolloSettingsSection sectionWithTitle:@"Saved on This iPhone"
                                               footer:@"The latest five local backups are kept, newest first. Tap one to export it to Files or restore it. These backups are deleted if you delete Apollo."
                                                 rows:rows]];
}

- (void)backupStateDidChange:(__unused NSNotification *)notification {
    if (self.refreshScheduled) return;
    self.refreshScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.refreshScheduled = NO;
        [weakSelf refreshLocalBackups];
    });
}

- (void)refreshLocalBackups {
    if (!self.isViewLoaded) return;
    [self rebuildSectionContainingRowID:@"local.backups.anchor" withRowAnimation:UITableViewRowAnimationNone];
}

- (void)showActionsForBackupURL:(NSURL *)url rowID:(NSString *)rowID {
    if (self.preparingCopy || ApolloAutomaticBackup.sharedManager.isBackingUp) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:ApolloLocalBackupTitle(url)
                                                                   message:@"This unencrypted backup contains API keys and login credentials."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Export" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf prepareBackupURL:url forRestore:NO];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [weakSelf prepareBackupURL:url forRestore:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *source = [self cellForRowID:rowID] ?: self.view;
    sheet.popoverPresentationController.sourceView = source;
    sheet.popoverPresentationController.sourceRect = source.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)prepareBackupURL:(NSURL *)url forRestore:(BOOL)restore {
    if (self.preparingCopy || self.pendingBackupURL) return;
    self.preparingCopy = YES;
    [self refreshLocalBackups];
    __weak typeof(self) weakSelf = self;
    [ApolloAutomaticBackup.sharedManager prepareLocalBackupAtURL:url completion:^(NSURL *copyURL, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.view.window) {
            if (copyURL) [NSFileManager.defaultManager removeItemAtURL:copyURL error:nil];
            strongSelf.preparingCopy = NO;
            return;
        }
        strongSelf.preparingCopy = NO;
        [strongSelf refreshLocalBackups];
        if (!copyURL) {
            ApolloBackupShowAlert(strongSelf, @"Backup Unavailable", error.localizedDescription ?: @"Could not open this backup.");
            return;
        }
        // Keep an independent copy while the picker/confirmation is visible;
        // automatic retention may remove the original archive in the meantime.
        strongSelf.pendingBackupURL = copyURL;
        if (restore) [strongSelf confirmRestore];
        else [strongSelf exportPreparedBackup];
    }];
}

- (void)exportPreparedBackup {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForExportingURLs:@[self.pendingBackupURL] asCopy:YES];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
    picker.presentationController.delegate = self;
}

- (void)cleanupPreparedBackup {
    if (self.pendingBackupURL) [NSFileManager.defaultManager removeItemAtURL:self.pendingBackupURL error:nil];
    self.pendingBackupURL = nil;
}

- (void)documentPicker:(__unused UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(__unused NSArray<NSURL *> *)urls {
    [self cleanupPreparedBackup];
}

- (void)documentPickerWasCancelled:(__unused UIDocumentPickerViewController *)controller {
    [self cleanupPreparedBackup];
}

- (void)presentationControllerDidDismiss:(__unused UIPresentationController *)presentationController {
    [self cleanupPreparedBackup];
}

- (void)confirmRestore {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Confirm Restore"
                                                                   message:@"This will replace all existing settings and logged-in accounts with the backup. This cannot be undone."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        [weakSelf cleanupPreparedBackup];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [weakSelf restorePreparedBackup];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restorePreparedBackup {
    NSURL *url = self.pendingBackupURL;
    if (!url) return;
    NSString *errorTitle = nil;
    NSString *errorMessage = nil;
    BOOL restored = ApolloBackupRestoreRestoreFromZipURL(url, &errorTitle, &errorMessage);
    [self cleanupPreparedBackup];
    if (!restored) {
        ApolloBackupShowAlert(self, errorTitle ?: @"Restore Failed", errorMessage ?: @"Could not restore this backup.");
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restore Complete"
                                                                   message:@"Settings successfully restored. Apollo needs to restart to apply changes."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close App" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        exit(0);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
