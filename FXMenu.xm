#import "FXInterface.h"
#import <dispatch/dispatch.h>

// Preserve the native preview, Rename, Edit Home Screen and app actions.
// Add only the per-folder entry-block toggle; resizing is corner-pan only.
%group FXFolderMenuHooks
%hook SBIconView
- (id)contextMenuInteraction:(id)interaction configurationForMenuAtLocation:(CGPoint)location {
    id value = %orig;
    UIView *host = (UIView *)self;
    id menuIcon = FXObject(host, @"icon");
    if (!FXIsFolder(menuIcon) ||
        ![value isKindOfClass:UIContextMenuConfiguration.class]) return value;
    NSNumber *saved = FXSavedSize(menuIcon);
    BOOL isLarge = FXIsGenuineLarge(menuIcon) ||
        ((FXSize(menuIcon) == FXFolderSizeLarge || FXSize(menuIcon) == FXFolderSizeWide ||
          saved.unsignedIntegerValue == FXFolderSizeLarge ||
          saved.unsignedIntegerValue == FXFolderSizeWide) && host.bounds.size.width >= 105.0);
    if (!isLarge || !FXIdentifier(menuIcon).length) return value;

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

        // Do not expose any folder-size command in 3D Touch. The existing
        // bottom-right pan handle is the sole size-changing gesture.
        BOOL blocked = FXFolderEntryBlocked(icon);
        UIAction *blockOpen = [UIAction actionWithTitle:@"禁止进入文件夹"
                                               image:[UIImage systemImageNamed:@"lock"]
                                          identifier:nil
                                             handler:^(__unused UIAction *action) {
            // The host/preview may be recycled as the menu dismisses. Use the
            // stable folder identity, not a captured SBIconView pointer.
            FXSetFolderEntryBlockedByIdentifier(folderUID, !blocked);
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        }];
        blockOpen.state = blocked ? UIMenuElementStateOn : UIMenuElementStateOff;
        NSMutableArray<UIMenuElement *> *children =
            [NSMutableArray arrayWithObject:blockOpen];
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

// Tap interception alone is insufficient: SpringBoardHome may reach the
// manager's native open entry without invoking SBIconView's _handleTap or
// performTap. Always suppress the *opening* for a blocked expanded folder,
// even if a native drag is pending, without altering native insertion,
// corner-handle resize, previews, or an internal App's direct launch.
// Each selector is installed separately after a runtime availability check;
// iOS builds may implement only one of these entry points.
%group FXManagerOpenFolderGate
%hook SBHIconManager
- (void)openFolderIcon:(id)icon location:(id)location animated:(BOOL)animated withCompletion:(id)completion {
    if (FXShouldBlockFolderOpenIcon(icon)) return;
    %orig;
}
%end
%end

%group FXManagerPushFolderGate
%hook SBHIconManager
- (void)pushExpandedIcon:(id)icon location:(id)location animated:(BOOL)animated completionHandler:(id)completion {
    if (FXShouldBlockFolderOpenIcon(icon)) return;
    %orig;
}
%end
%end

static BOOL FXManagerOpenGateInstalled = NO;
static BOOL FXManagerPushGateInstalled = NO;
// The two methods are private. Never install a Logos replacement if its ABI
// does not match the void(id, id, BOOL, block) signature being hooked.
static BOOL FXManagerOpenSelectorABI(Class cls, SEL selector) {
    if (!cls || !class_getInstanceMethod(cls, selector)) return NO;
    NSMethodSignature *sig = [cls instanceMethodSignatureForSelector:selector];
    if (!sig || sig.numberOfArguments != 6 || sig.methodReturnType[0] != 'v') return NO;
    const char *a = [sig getArgumentTypeAtIndex:2];
    const char *b = [sig getArgumentTypeAtIndex:3];
    const char *flag = [sig getArgumentTypeAtIndex:4];
    const char *last = [sig getArgumentTypeAtIndex:5];
    return a && a[0] == '@' && b && b[0] == '@' &&
           flag && (flag[0] == 'B' || flag[0] == 'c') &&
           last && last[0] == '@';
}
static void FXInstallManagerOpenGates(NSUInteger attempt) {
    Class cls = NSClassFromString(@"SBHIconManager");
    if (cls) {
        if (!FXManagerOpenGateInstalled &&
            FXManagerOpenSelectorABI(cls, @selector(openFolderIcon:location:animated:withCompletion:))) {
            %init(FXManagerOpenFolderGate);
            FXManagerOpenGateInstalled = YES;
        }
        if (!FXManagerPushGateInstalled &&
            FXManagerOpenSelectorABI(cls, @selector(pushExpandedIcon:location:animated:completionHandler:))) {
            %init(FXManagerPushFolderGate);
            FXManagerPushGateInstalled = YES;
        }
    }
    if (attempt >= 12 || (FXManagerOpenGateInstalled && FXManagerPushGateInstalled)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FXInstallManagerOpenGates(attempt + 1); });
}
%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{ FXInstallManagerOpenGates(0); });
}
