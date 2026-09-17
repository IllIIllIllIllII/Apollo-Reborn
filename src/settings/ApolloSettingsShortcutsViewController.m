#import "ApolloSettingsShortcutsViewController.h"
#import "ApolloSettingsRouter.h"
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"

NSArray<NSString *> *ApolloSettingsShortcutCatalog(void) {
    return @[@"theme-manager", @"saved-categories", @"automatic-backups", @"feature-requests", @"bug-reports",
        @"tag-filters", @"translation", @"picture-in-picture", @"apollo-ai", @"open-in-app",
        @"inline-media", @"rich-link-previews", @"crash-reports"];
}

NSArray<NSString *> *ApolloSettingsShortcutIDs(void) {
    id saved = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeySettingsTabShortcuts];
    if (![saved isKindOfClass:NSArray.class]) {
        return @[@"theme-manager", @"saved-categories", @"automatic-backups", @"feature-requests", @"bug-reports"];
    }
    NSMutableArray *valid = [NSMutableArray array];
    for (id identifier in saved) {
        if ([identifier isKindOfClass:NSString.class] && [ApolloSettingsShortcutCatalog() containsObject:identifier]
            && ![valid containsObject:identifier]) [valid addObject:identifier];
    }
    return valid;
}

NSString *ApolloSettingsShortcutTitle(NSString *identifier) {
    if ([identifier isEqualToString:@"feature-requests"]) return @"Feature Requests";
    if ([identifier isEqualToString:@"bug-reports"]) return @"Bug Reports";
    if ([identifier isEqualToString:@"automatic-backups"]) return @"Backup Settings";
    return ApolloSettingsRouteTitle(identifier);
}

UIImage *ApolloSettingsShortcutImage(NSString *identifier, UITraitCollection *traits, CGFloat size) {
    __block UIImage *image;
    [traits performAsCurrentTraitCollection:^{
        if ([identifier isEqualToString:@"feature-requests"] || [identifier isEqualToString:@"bug-reports"]) {
            BOOL requests = [identifier isEqualToString:@"feature-requests"];
            image = ApolloEmojiSettingsIcon(requests ? @"💡" : @"🐛", requests ? UIColor.systemYellowColor : UIColor.systemRedColor, size);
        } else {
            NSDictionary *symbols = @{@"theme-manager": @"paintbrush.fill", @"saved-categories": @"apollo.saved-categories",
                @"automatic-backups": @"square.and.arrow.up.fill", @"tag-filters": @"tag.fill", @"translation": @"character.bubble.fill",
                @"picture-in-picture": @"pip.fill", @"apollo-ai": @"sparkles", @"open-in-app": @"arrow.up.forward.app.fill",
                @"inline-media": @"play.rectangle.fill", @"rich-link-previews": @"link", @"crash-reports": @"bandage"};
            UIColor *color = UIColor.systemBlueColor;
            if ([identifier isEqualToString:@"theme-manager"]) color = ApolloThemeManagerIconColor();
            else if ([identifier isEqualToString:@"saved-categories"]) color = UIColor.systemGreenColor;
            else if ([identifier isEqualToString:@"picture-in-picture"]) color = UIColor.systemPurpleColor;
            else if ([identifier isEqualToString:@"translation"]) color = UIColor.systemTealColor;
            else if ([identifier isEqualToString:@"apollo-ai"]) color = UIColor.systemIndigoColor;
            else if ([identifier isEqualToString:@"inline-media"]) color = UIColor.systemPinkColor;
            else if ([identifier isEqualToString:@"tag-filters"] || [identifier isEqualToString:@"crash-reports"]) color = UIColor.systemOrangeColor;
            UIImage *tile = ApolloSettingsIconTileImage(symbols[identifier], color, traits);
            image = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)] imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [tile drawInRect:CGRectMake(0, 0, size, size)];
            }];
        }
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

@interface ApolloSettingsShortcutsViewController ()
@property (nonatomic, strong) NSMutableArray<NSString *> *included;
@end

@implementation ApolloSettingsShortcutsViewController
- (void)viewDidLoad {
    self.included = [ApolloSettingsShortcutIDs() mutableCopy];
    [super viewDidLoad];
    self.title = @"Shortcuts";
    [self updateEditButton];
}

- (void)updateEditButton {
    UIBarButtonItem *button;
    if (self.editing) {
        button = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]
            style:UIBarButtonItemStyleDone target:self action:@selector(toggleEditing)];
        if (@available(iOS 26.0, *)) button.style = UIBarButtonItemStyleProminent;
        button.accessibilityLabel = @"Done editing shortcuts";
    } else {
        button = [[UIBarButtonItem alloc] initWithTitle:@"Edit" style:UIBarButtonItemStylePlain target:self action:@selector(toggleEditing)];
    }
    // Inherit the navigation bar tint so Edit and Done follow the active theme.
    self.navigationItem.rightBarButtonItem = button;
}

- (void)toggleEditing {
    [self setEditing:!self.editing animated:YES];
    [self updateEditButton];
}

- (void)save {
    [[NSUserDefaults standardUserDefaults] setObject:self.included forKey:UDKeySettingsTabShortcuts];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;
    NSMutableArray *includedRows = [NSMutableArray array];
    NSMutableArray *availableRows = [NSMutableArray array];
    NSMutableArray *ordered = [self.included mutableCopy];
    for (NSString *identifier in ApolloSettingsShortcutCatalog()) {
        if (![ordered containsObject:identifier]) [ordered addObject:identifier];
    }
    for (NSString *identifier in ordered) {
        ApolloSettingsRow *row = [ApolloSettingsRow valueRowWithID:identifier title:ApolloSettingsShortcutTitle(identifier) detail:nil onSelect:nil];
        row.configure = ^(UITableViewCell *cell) {
            cell.imageView.image = ApolloSettingsShortcutImage(identifier, weakSelf.traitCollection, 29);
            cell.showsReorderControl = [weakSelf.included containsObject:identifier];
        };
        NSMutableArray *rows = [self.included containsObject:identifier] ? includedRows : availableRows;
        [rows addObject:row];
    }
    return @[[ApolloSettingsSection sectionWithTitle:@"Included" footer:@"Press and hold the Settings tab to open these shortcuts. Changes are saved automatically. Remove all shortcuts to disable the menu." rows:includedRows],
        [ApolloSettingsSection sectionWithTitle:@"Available" footer:@"Tap Edit to add, remove, or reorder shortcuts." rows:availableRows]];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self rowAtIndexPath:indexPath] != nil;
}
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self.included containsObject:[self rowAtIndexPath:indexPath].rowID] ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleInsert;
}
- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    return @"Remove";
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *identifier = [self rowAtIndexPath:indexPath].rowID;
    if (!identifier) return;
    if (style == UITableViewCellEditingStyleDelete) [self.included removeObject:identifier];
    else if (style == UITableViewCellEditingStyleInsert && ![self.included containsObject:identifier]) [self.included addObject:identifier];
    [self save];
    // Let UIKit finish the delete confirmation / reorder transaction before
    // replacing its snapshot. Keep the editor active for the next change.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self rebuildForm];
        [self.tableView setEditing:self.editing animated:NO];
    });
}
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self.included containsObject:[self rowAtIndexPath:indexPath].rowID];
}
- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)source toProposedIndexPath:(NSIndexPath *)proposed {
    return [self.included containsObject:[self rowAtIndexPath:proposed].rowID] ? proposed : source;
}
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination {
    NSString *identifier = [self rowAtIndexPath:source].rowID;
    NSString *target = [self rowAtIndexPath:destination].rowID;
    NSUInteger index = [self.included indexOfObject:target];
    if (!identifier || index == NSNotFound) return;
    [self.included removeObject:identifier];
    [self.included insertObject:identifier atIndex:index];
    [self save];
    // Let UIKit finish the delete confirmation / reorder transaction before
    // replacing its snapshot. Keep the editor active for the next change.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self rebuildForm];
        [self.tableView setEditing:self.editing animated:NO];
    });
}
@end
