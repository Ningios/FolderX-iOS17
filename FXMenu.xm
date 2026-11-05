#import "FXInterface.h"
#import <dispatch/dispatch.h>

// The *existing* SpringBoard context menu remains responsible for the
// preview, Rename, Edit Home Screen and other native actions. This adds only
// one contextual size action, without installing a second menu interaction.
%group FXFolderMenuHooks
%hook SBIconView
- (id)contextMenuInteraction:(id)interaction configurationForMenuAtLocation:(CGPoint)location {
    id value = %orig;
    UIView *host = (UIView *)self;
    if (!FXIsFolder(FXObject(host, @"icon")) ||
        ![value isKindOfClass:UIContextMenuConfiguration.class]) return value;

    UIContextMenuConfiguration *nativeConfig = (UIContextMenuConfiguration *)value;
    // Use the configuration's provided blocks. Never recreate the preview or
    // replace SpringBoard's action provider with unrelated app shortcuts.
    // On iOS some menu configurations have private block getters. If they
    // cannot be recovered safely, keep SpringBoard's entire original menu
    // intact rather than wiping out Rename / Edit / App shortcuts.
    id providerObject = FXObject(nativeConfig, @"actionProvider");
    id previewObject = FXObject(nativeConfig, @"previewProvider");
    if (!providerObject) {
        @try { providerObject = [nativeConfig valueForKey:@"_actionProvider"]; }
        @catch (__unused NSException *exception) {}
    }
    if (!providerObject) return value;
    UIContextMenuActionProvider provider = (UIContextMenuActionProvider)providerObject;
    UIContextMenuContentPreviewProvider preview = (UIContextMenuContentPreviewProvider)previewObject;
    id identifier = nativeConfig.identifier;
    __weak UIView *weakHost = host;
    NSString *folderUID = [FXIdentifier(FXObject(host, @"icon")) copy];

    return [UIContextMenuConfiguration configurationWithIdentifier:identifier
                                                    previewProvider:preview
                                                     actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIView *liveHost = weakHost;
        id icon = FXObject(liveHost, @"icon");
        UIMenu *nativeMenu = provider ? provider(suggested) : nil;
        NSArray<UIMenuElement *> *nativeChildren = nativeMenu ? nativeMenu.children : suggested;
        if (!liveHost || !FXIsFolder(icon) ||
            ![FXIdentifier(icon) isEqualToString:folderUID])
            return nativeMenu ?: [UIMenu menuWithChildren:nativeChildren ?: @[]];

        NSMutableArray<UIMenuElement *> *sizes = [NSMutableArray array];
        NSMutableArray<NSNumber *> *classes = [NSMutableArray arrayWithArray:@[@(FXFolderSizeSmall), @(FXFolderSizeLarge)]];
        // Always show the requested 4x2 option for discoverability, but keep
        // it disabled until the native 4x2 enum mapping is actually verified.
        // A guessed class can permanently corrupt the Home Screen layout.
        BOOL supportsWide = FXCanUseWideGrid();
        [classes addObject:@(FXFolderSizeWide)];
        for (NSNumber *candidate in classes) {
            FXFolderSize desired = (FXFolderSize)candidate.unsignedIntegerValue;
            NSString *title = desired == FXFolderSizeSmall ? @"小文件夹" :
                              desired == FXFolderSizeLarge ? @"2×2 大文件夹" :
                              (supportsWide ? @"4×2 横向文件夹" : @"4×2 横向文件夹（未验证）");
            NSString *symbol = desired == FXFolderSizeWide ? @"rectangle.grid.2x2" : @"square.grid.2x2";
            UIAction *item = [UIAction actionWithTitle:title
                                                image:[UIImage systemImageNamed:symbol]
                                           identifier:nil
                                              handler:^(__unused UIAction *action) {
                // Wait for the native context menu to dismiss before changing
                // grid occupancy, avoiding a disappearing preview mid-morph.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    BOOL success = FXCommitSizeForIdentifier(folderUID, desired);
                    if (success) {
                        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
                    } else {
                        [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeError];
                    }
                });
            }];
            if (desired == FXFolderSizeWide && !supportsWide)
                item.attributes = UIMenuElementAttributesDisabled;
            if (FXSize(icon) == desired) item.state = UIMenuElementStateOn;
            [sizes addObject:item];
        }
        UIMenu *sizeMenu = [UIMenu menuWithTitle:@"文件夹大小"
                                            image:[UIImage systemImageNamed:@"square.resize"]
                                       identifier:nil
                                          options:UIMenuOptionsDisplayInline
                                         children:sizes];
        NSMutableArray<UIMenuElement *> *children =
            [NSMutableArray arrayWithObject:sizeMenu];
        if (nativeChildren) [children addObjectsFromArray:nativeChildren];
        return [UIMenu menuWithTitle:nativeMenu.title ?: @""
                              image:nativeMenu.image
                         identifier:nativeMenu.identifier
                            options:nativeMenu.options
                           children:children];
    }];
}
%end
%end

static void FXInstallFolderMenuHook(NSUInteger attempt) {
    Class cls = NSClassFromString(@"SBIconView");
    SEL sel = @selector(contextMenuInteraction:configurationForMenuAtLocation:);
    if (cls && class_getInstanceMethod(cls, sel)) {
        %init(FXFolderMenuHooks);
        return;
    }
    if (attempt >= 12) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FXInstallFolderMenuHook(attempt + 1); });
}
%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{ FXInstallFolderMenuHook(0); });
}
