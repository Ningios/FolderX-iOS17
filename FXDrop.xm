#import "FXInterface.h"
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <math.h>

// All drop observations use UIKit's existing SpringBoard destination delegate.
// DO NOT install a second UIDropInteraction on the folder; that steals native
// icon edit/move sessions and makes the layout look like 1x1 on release.
// No log writing, background snapshots, direct SBFolder addIcon:, or fake cells.

static __strong id FXDraggedLeaf = nil;            // Retain the actual pre-lift SBLeafIcon.
static __strong id FXDraggedFolder = nil;          // Folder lifts need visual protection too.
static __weak UIView *FXDraggedFolderHost = nil;
static __weak UIView *FXDraggedOriginList = nil; // Verified pre-lift source page.
static __strong id FXDraggedOriginModel = nil; // Temporary identity only for drag lifetime.
static NSString *FXDraggedUID = nil;
static NSString *FXDraggedBundle = nil;
static __weak UIView *FXHoveredHost = nil;
static NSUInteger FXDragGeneration = 0;
static BOOL FXDragNativeFinalizing = NO; // Native regen must run at commit/end.
static NSUInteger FXNativeHandoffSubmittedGeneration = NSNotFound;

// A live, verified list-cell rect can outlive SpringBoard's transient drag-lift
// rendering pass. Keep it only for the current drag, and reject after page
// scrolling or a folder identity change. This is *not* a synthetic occupancy.
static NSArray<NSDictionary *> *FXDragNativeTargets = nil;
// Visual lock and drop-target authorization are deliberately separate: a
// saved, visibly expanded folder can be held stable without being accepted as
// a new drop target unless its native occupied grid range is proven.
static NSArray<UIView *> *FXDragVisualHosts = nil;
static NSArray<NSDictionary *> *FXCaptureNativeTargets(UIView *window);
static NSArray<UIView *> *FXCaptureVisualHosts(UIView *window);
static UIView *FXCachedTargetForList(UIView *list, CGPoint point);
static void FXSetHoveredHost(UIView *host);
static void FXClearSource(void);
// Only for the independently verified cross-page 2x4x2 + 1x2x2 scenario.
// This guard never changes a folder grid range, size class, or frame.
static BOOL FXCanSkipIncomingTemporaryRegen(UIView *list);
BOOL FXNativeDragIsActive(void) { return FXDraggedLeaf != nil || FXDraggedFolder != nil; }

static BOOL FXIsUsableSource(id icon) {
    Class leaf = NSClassFromString(@"SBLeafIcon");
    if (!icon || (leaf && ![icon isKindOfClass:leaf]) || FXIsFolder(icon)) return NO;
    // Do not require FXListModel here: the lifted icon can already have been
    // replaced by a placeholder by the time performDrop runs.
    return FXIdentifier(icon).length > 0 || FXBundleID(icon).length > 0;
}

static id FXSourceFromDragItem(id item) {
    id candidate = FXObject(item, @"localObject");
    if (FXIsUsableSource(candidate)) return candidate;
    for (NSString *key in @[@"icon", @"draggedIcon", @"sourceIcon", @"leafIcon"]) {
        id sub = FXObject(candidate, key);
        if (FXIsUsableSource(sub)) return sub;
    }
    if ([candidate isKindOfClass:UIView.class]) {
        id sub = FXObject(candidate, @"icon");
        if (FXIsUsableSource(sub)) return sub;
    }
    return nil;
}

// Capture the native source page before %orig replaces the lifted icon with
// a placeholder. A parent SBIconListView is not synthesized from screen x/y.
static UIView *FXNativeParentListForHost(UIView *host) {
    Class listClass = NSClassFromString(@"SBIconListView");
    if (!host || !listClass) return nil;
    for (UIView *v = host.superview; v; v = v.superview) {
        if ([v isKindOfClass:listClass]) return v;
    }
    return nil;
}

// The v15 Frida A/B experiment kept BOTH 4x2 and the 2x2 folder visibly large
// by bypassing regeneration on this exact type of destination page. Do not
// generalize the experiment to other models, ordinary drag pages or widgets.
// Verify the native grid range and make sure every enlarged folder occupies
// distinct cells in the device's 4x6 grid before interfering with anything.
static BOOL FXHasVerifiedABPageLayout(UIView *list) {
    id model = FXObject(list, @"model");
    NSArray *icons = FXObject(model, @"icons");
    if (![icons isKindOfClass:NSArray.class] || icons.count < 3 || icons.count > 24) return NO;
    NSUInteger wide = 0, large = 0;
    uint32_t occupiedMask = 0;
    for (id icon in icons) {
        if (!FXIsFolder(icon)) continue;
        NSUInteger size = FXSize(icon);
        if (size != FXFolderSizeWide && size != FXFolderSizeLarge) continue;
        FXGridRange r = FXGridOf(model, icon);
        BOOL wideFolder = size == FXFolderSizeWide && r.columns == 4 && r.rows == 2;
        BOOL squareFolder = size == FXFolderSizeLarge && r.columns == 2 && r.rows == 2;
        if (!wideFolder && !squareFolder) return NO;
        if (r.gridCellIndex >= 24 || r.gridCellIndex % 4 + r.columns > 4 ||
            r.gridCellIndex / 4 + r.rows > 6) return NO;
        for (NSUInteger row = 0; row < r.rows; row++) {
            for (NSUInteger col = 0; col < r.columns; col++) {
                NSUInteger index = (NSUInteger)r.gridCellIndex + row * 4 + col;
                uint32_t mask = (uint32_t)1 << index;
                if (occupiedMask & mask) return NO;
                occupiedMask |= mask;
            }
        }
        if (wideFolder) ++wide;
        else ++large;
    }
    return wide == 2 && large == 1;
}

// Minimal fail-closed guard: retain UIKit's original temporary regeneration
// everywhere except an incoming *App* drag to a separate verified page. This
// is NOT a permanent ban on regeneration, and does not affect the native drop
// commit, folder dragging, same-page drag, or folder opening/closing.
static BOOL FXCheckingIncomingTemporaryModel = NO;
static BOOL FXCanSkipIncomingTemporaryRegen(UIView *list) {
    if (FXCheckingIncomingTemporaryModel || ![NSThread isMainThread] ||
        !FXDraggedLeaf || FXDraggedFolder || FXDragNativeFinalizing ||
        !list || !list.window || !FXDraggedOriginList ||
        !FXDraggedOriginList.window) return NO;
    Class listClass = NSClassFromString(@"SBIconListView");
    if (!listClass || ![list isKindOfClass:listClass] ||
        list == FXDraggedOriginList ||
        list.bounds.size.width < 350 || list.bounds.size.height < 650 ||
        FXDraggedOriginList.bounds.size.height < 650) return NO;
    id model = FXObject(list, @"model");
    if (!model || model == FXDraggedOriginModel) return NO;
    FXCheckingIncomingTemporaryModel = YES;
    BOOL eligible = NO;
    @try { eligible = FXHasVerifiedABPageLayout(list); }
    @finally { FXCheckingIncomingTemporaryModel = NO; }
    return eligible;
}

static void FXBeginNativeDrag(id icon, NSString *uid, NSString *bundleID,
                              UIView *originList, id originModel,
                              NSArray<NSDictionary *> *verifiedTargets, NSArray<UIView *> *visualHosts) {
    ++FXDragGeneration;
    FXDraggedLeaf = FXIsUsableSource(icon) ? icon : nil;
    FXDraggedFolder = FXIsFolder(icon) ? icon : nil;
    FXDraggedOriginList = originList;
    FXDraggedOriginModel = originModel;
    FXDragNativeFinalizing = NO;
    FXDraggedUID = [uid copy];
    FXDraggedBundle = [bundleID copy];
    FXDragNativeTargets = [verifiedTargets copy];
    FXDragVisualHosts = [visualHosts copy];
    FXNativeHandoffSubmittedGeneration = NSNotFound;
    NSUInteger generation = FXDragGeneration;
    // A cancelled/abandoned native drag should never leave restoration disabled.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(14 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == FXDragGeneration) {
            FXClearSource();
        }
    });
}

static void FXSetHoveredHost(UIView *host) {
    if (FXHoveredHost == host) return;
    if (FXHoveredHost) FXSetDropHoverForHost(FXHoveredHost, NO);
    FXHoveredHost = host;
    if (host) FXSetDropHoverForHost(host, YES);
}

static void FXClearSource(void) {
    FXStopDragAppFrameGuard();
    FXSetHoveredHost(nil);
    for (UIView *host in FXDragVisualHosts)
        FXSetDragVisualLockForHost(host, NO);
    FXDraggedLeaf = nil;
    FXDraggedFolder = nil;
    FXDraggedFolderHost = nil;
    FXDraggedOriginList = nil;
    FXDraggedOriginModel = nil;
    FXDragNativeFinalizing = NO;
    FXDraggedUID = nil;
    FXDraggedBundle = nil;
    FXDragNativeTargets = nil;
    FXDragVisualHosts = nil;
}

static void FXScanVisibleNativeTargets(UIView *view, NSMutableArray<NSDictionary *> *targets,
                                       NSUInteger depth) {
    if (!view || depth > 22 || view.hidden || view.alpha < 0.01) return;
    Class iconViewClass = NSClassFromString(@"SBIconView");
    Class listClass = NSClassFromString(@"SBIconListView");
    if (iconViewClass && [view isKindOfClass:iconViewClass]) {
        id icon = FXObject(view, @"icon");
        NSString *uid = FXIdentifier(icon);
        if (!uid.length || !FXIsGenuineLarge(icon)) return;
        UIView *list = view.superview;
        while (list && !(listClass && [list isKindOfClass:listClass])) list = list.superview;
        if (!list || !list.window || list.window != view.window) return;
        CGFloat width = view.bounds.size.width;
        CGFloat height = view.bounds.size.height;
        CGFloat visibleHeight = MAX(0.0, height - 14.0);
        if (MIN(width, visibleHeight) < 99.0) return;
        // Capture exactly the already-rendered native cell footprint BEFORE
        // SpringBoard changes drag placeholders. A wide folder must use its
        // full width, not the central square of a 4x2 host.
        CGRect nativeCell = CGRectMake(0, 0, width, visibleHeight);
        CGRect footprint = [view convertRect:nativeCell toView:list];
        CGPoint origin = [list convertPoint:CGPointZero toView:nil];
        if (!CGRectIntersectsRect(list.bounds, footprint)) return;
        [targets addObject:@{ @"host":view, @"list":list, @"uid":uid,
                             @"sizeClass":@(FXSize(icon)),
                             @"rect":[NSValue valueWithCGRect:footprint],
                             @"listOrigin":[NSValue valueWithCGPoint:origin] }];
        return;
    }
    for (UIView *child in view.subviews) FXScanVisibleNativeTargets(child, targets, depth + 1);
}

static NSArray<NSDictionary *> *FXCaptureNativeTargets(UIView *window) {
    if (!window) return @[];
    NSMutableArray<NSDictionary *> *targets = [NSMutableArray array];
    FXScanVisibleNativeTargets(window, targets, 0);
    return targets;
}

static void FXScanVisualHosts(UIView *view, NSMutableArray<UIView *> *hosts, NSUInteger depth) {
    if (!view || depth > 22 || view.hidden || view.alpha < 0.01) return;
    Class iconClass = NSClassFromString(@"SBIconView");
    if (iconClass && [view isKindOfClass:iconClass]) {
        id icon = FXObject(view, @"icon");
        if (FXIsFolder(icon) && view.window && view.bounds.size.width >= 110.0 &&
            (FXIsGenuineLarge(icon) || FXShouldRenderLarge(icon, view)))
            [hosts addObject:view];
        return;
    }
    for (UIView *sub in view.subviews) FXScanVisualHosts(sub, hosts, depth + 1);
}

static NSArray<UIView *> *FXCaptureVisualHosts(UIView *window) {
    if (!window) return @[];
    NSMutableArray<UIView *> *hosts = [NSMutableArray array];
    FXScanVisualHosts(window, hosts, 0);
    return hosts;
}

// A drag entering an already-loaded or newly-created page must protect that
// page's real expanded hosts BEFORE SpringBoard runs its next reflow. No
// synthetic cells, no 1x1 workaround, and no setFrame on folders.
static BOOL FXUpdatingDestinationPage = NO;
static void FXExtendActiveDragProtectionForList(UIView *list) {
    if (FXUpdatingDestinationPage || !FXNativeDragIsActive() || !list ||
        ![NSThread isMainThread] || !list.window) return;
    Class listClass = NSClassFromString(@"SBIconListView");
    if (!listClass || ![list isKindOfClass:listClass]) return;
    FXUpdatingDestinationPage = YES;
    @try {
        NSArray<UIView *> *visible = FXCaptureVisualHosts(list);
        NSMutableArray<UIView *> *combined = [FXDragVisualHosts mutableCopy];
        if (!combined) combined = [NSMutableArray array];
        for (UIView *host in visible) {
            // An earlier pass may have found the host before SpringBoard
            // instantiated its native image view. The lock is idempotent, so
            // retry it while the destination page is being realized.
            BOOL alreadyKnown = [combined containsObject:host];
            // A lifted large folder must NOT be pinned to its old page.
            BOOL isSource = (host == FXDraggedFolderHost) ||
                (FXDraggedFolder && [FXIdentifier(FXObject(host, @"icon"))
                     isEqualToString:FXIdentifier(FXDraggedFolder)]);
            if (isSource) FXSetDragVisualLockForHostNoPause(host, YES);
            else FXSetDragVisualLockForHost(host, YES);
            if (!alreadyKnown) [combined addObject:host];
        }
        FXDragVisualHosts = [combined copy];
        if (FXDraggedLeaf || FXDraggedFolder) {
            // Do not drop the App-frame guard merely because the moving item
            // is a folder. It still protects model-stable ordinary App views.
            NSArray<NSDictionary *> *newTargets = FXCaptureNativeTargets(list);
            if (newTargets.count) {
                NSMutableArray<NSDictionary *> *targets = [FXDragNativeTargets mutableCopy];
                if (!targets) targets = [NSMutableArray array];
                for (NSDictionary *item in newTargets) {
                    BOOL exists = NO;
                    for (NSDictionary *old in targets)
                        if (old[@"host"] == item[@"host"] &&
                            [old[@"uid"] isEqualToString:item[@"uid"]]) {
                            exists = YES; break;
                        }
                    if (!exists) [targets addObject:item];
                }
                FXDragNativeTargets = [targets copy];
                // Also resample newly materialized ordinary App views on a
                // destination page whose folders were captured earlier.
                FXExtendDragAppFrameGuard(newTargets, FXDraggedFolderHost);
            }
        }
    } @finally { FXUpdatingDestinationPage = NO; }
}

static UIView *FXCachedTargetForList(UIView *list, CGPoint point) {
    if (!list.window || !FXNativeDragIsActive()) return nil;
    CGPoint currentOrigin = [list convertPoint:CGPointZero toView:nil];
    for (NSDictionary *entry in FXDragNativeTargets) {
        if (entry[@"list"] != list) continue;
        CGPoint oldOrigin = [entry[@"listOrigin"] CGPointValue];
        if (fabs(currentOrigin.x - oldOrigin.x) > 5 ||
            fabs(currentOrigin.y - oldOrigin.y) > 5) continue;
        CGRect rect = [entry[@"rect"] CGRectValue];
        if (!CGRectContainsPoint(CGRectInset(rect, 7, 7), point)) continue;
        UIView *host = entry[@"host"];
        id current = FXObject(host, @"icon");
        NSString *uid = entry[@"uid"];
        if (!host.window || ![FXIdentifier(current) isEqualToString:uid]) continue;
        // The underlying root list must still contain this specific folder.
        if (!FXListModel(current) || !FXIsFolder(current)) continue;
        NSNumber *saved = FXSavedSize(current);
        BOOL stillIntendedLarge = FXSize(current) == FXFolderSizeLarge ||
                                   FXSize(current) == FXFolderSizeWide ||
                                   saved.unsignedIntegerValue == FXFolderSizeLarge ||
                                   saved.unsignedIntegerValue == FXFolderSizeWide;
        if (stillIntendedLarge) return host;
    }
    return nil;
}

// A captured size-class is stronger evidence than a preference saved before a
// later resize. Call this only for a host already returned from the verified
// pre-lift target cache; the live class can briefly change during reflow.
static BOOL FXWasCapturedWideHost(UIView *list, UIView *host) {
    if (!list || !host) return NO;
    for (NSDictionary *entry in FXDragNativeTargets) {
        if (entry[@"list"] == list && entry[@"host"] == host &&
            [entry[@"sizeClass"] unsignedIntegerValue] == FXFolderSizeWide)
            return YES;
    }
    return NO;
}

static UIView *FXLargeFolderHostInTree(UIView *view, UIView *list, CGPoint p, NSUInteger depth) {
    if (!view || depth > 12 || view.hidden || view.alpha < 0.01) return nil;
    Class iconViewClass = NSClassFromString(@"SBIconView");
    if (iconViewClass && [view isKindOfClass:iconViewClass]) {
        id folderIcon = FXObject(view, @"icon");
        // During a native drag, SpringBoard may temporarily report 1x1.
        // Preserve the user's persisted 2x2 folder as a drop candidate,
        // without modifying the model during the drag.
        NSNumber *saved = FXSavedSize(folderIcon);
        BOOL intendedLarge = FXIsFolder(folderIcon) && saved &&
            (saved.unsignedIntegerValue == FXFolderSizeLarge ||
             saved.unsignedIntegerValue == FXFolderSizeWide);
        // A drag placeholder can temporarily make the list-model lookup fail.
        // Geometry only selects a *candidate*. The actual native mutation has
        // separate live-model validation after the drop finishes.
        if (FXIsFolder(folderIcon) &&
            (FXShouldRenderLarge(folderIcon, view) || intendedLarge) &&
            view.bounds.size.width >= 99 && view.bounds.size.height >= 99) {
            // The *existing* rendered host footprint, not a synthesized 2x2
            // placeholder, defines the hover target. Keep a small inner inset.
            // Use the same complete native cell footprint as pre-lift target
            // capture; the former centred square discarded both side wings
            // of a true 4x2 (338x158) folder.
            CGRect local = CGRectMake(0, 0, view.bounds.size.width,
                                      MAX(0, view.bounds.size.height - 14.0));
            CGRect target = [view convertRect:local toView:list];
            if (CGRectContainsPoint(CGRectInset(target, 7, 7), p)) return view;
        }
        return nil;
    }
    for (UIView *child in view.subviews) {
        UIView *match = FXLargeFolderHostInTree(child, list, p, depth + 1);
        if (match) return match;
    }
    return nil;
}

// No SBIconListView.iconAtPoint:index: override. In contrast with the
// ordinary drop destination callback, hit testing can affect native placeholder
// reflow. Keep original SpringBoard results and observe the live destination.

static UIView *FXFolderAtDropLocation(UIDropInteraction *interaction, id<UIDropSession> session) {
    UIView *list = interaction.view;
    Class listClass = NSClassFromString(@"SBIconListView");
    if (!list || !listClass || ![list isKindOfClass:listClass] || !list.window ||
        !session || session.items.count != 1) return nil;
    CGPoint point = [session locationInView:list];
    if (!CGRectContainsPoint(list.bounds, point)) return nil;
    // A native placeholder can temporarily relocate the 4x2 SBIconView to
    // (0,0) or shrink it to 60x74. The live tree may then pick an unrelated
    // icon. Prefer the footprint recorded BEFORE the lift for verified 4x2
    // folders, while retaining the prior live-first 2x2 behavior.
    UIView *cached = FXCachedTargetForList(list, point);
    if (cached && FXWasCapturedWideHost(list, cached)) return cached;
    UIView *live = FXLargeFolderHostInTree(list, list, point, 0);
    return live ?: cached;
}

static BOOL FXFolderHasApp(id folderIcon, NSString *uid, NSString *bid) {
    id folder = FXObject(folderIcon, @"folder");
    NSMutableArray *collected = [NSMutableArray array];
    NSUInteger count = FXUnsigned(folder, @"listCount");
    SEL sel = NSSelectorFromString(@"listAtIndex:");
    // Prefer the actual native page lists. On some iOS 17 builds allIcons
    // reports only the first nine, so using it when non-nil causes a false
    // "not in folder" result for icons 10-12 in a wide folder.
    if (count != NSUIntegerMax && count <= 20 &&
        [folder respondsToSelector:sel]) {
        id (*getList)(id, SEL, NSUInteger) =
            (id (*)(id, SEL, NSUInteger))objc_msgSend;
        for (NSUInteger i = 0; i < count; ++i) {
            id page = getList(folder, sel, i);
            id pageIcons = FXObject(page, @"icons");
            if ([pageIcons isKindOfClass:NSArray.class])
                [collected addObjectsFromArray:pageIcons];
        }
    }
    // allIcons is a fallback, not authoritative when native pages exist.
    id apps = collected.count ? collected : FXObject(folder, @"allIcons");
    if ([apps isKindOfClass:NSSet.class]) apps = [apps allObjects];
    if (![apps isKindOfClass:NSArray.class]) return NO;
    for (id app in (NSArray *)apps) {
        if (uid.length) {
            if ([FXIdentifier(app) isEqualToString:uid]) return YES;
        } else if (bid.length && [FXBundleID(app) isEqualToString:bid]) {
            return YES;
        }
    }
    return NO;
}

static BOOL FXNativeMoveIntoFolder(id source, id folderIcon) {
    if (!FXIsUsableSource(source) || !FXIsFolder(folderIcon) || !FXListModel(folderIcon)) return NO;
    Class controllerClass = NSClassFromString(@"SBIconController");
    id controller = FXObject((id)controllerClass, @"sharedInstance");
    id manager = FXObject(controller, @"iconManager");
    id dragManager = FXObject(manager, @"iconDragManager");
    SEL managerSEL = NSSelectorFromString(@"addIcons:intoFolderIcon:openFolderOnFinish:completion:");
    SEL dragSEL = NSSelectorFromString(@"addIcons:intoFolderIcon:openFolderOnFinish:");
    NSArray *icons = @[source];
    @try {
        if ([manager respondsToSelector:managerSEL]) {
            NSMethodSignature *sig = [manager methodSignatureForSelector:managerSEL];
            const char *argType = sig && sig.numberOfArguments == 6 ? [sig getArgumentTypeAtIndex:2] : NULL;
            const char *completionType = sig && sig.numberOfArguments == 6 ? [sig getArgumentTypeAtIndex:5] : NULL;
            if (sig && sig.numberOfArguments == 6 && sig.methodReturnType[0] == 'v' &&
                argType && argType[0] == '@' && completionType &&
                completionType[0] == '@') {
                void (^completion)(void) = ^{};
                ((void (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(manager, managerSEL,
                                                                     icons, folderIcon, NO, completion);
                return YES;
            }
        }
        if ([dragManager respondsToSelector:dragSEL]) {
            NSMethodSignature *sig = [dragManager methodSignatureForSelector:dragSEL];
            if (sig && sig.numberOfArguments == 5 && sig.methodReturnType[0] == 'v') {
                ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(dragManager, dragSEL,
                                                                 icons, folderIcon, NO);
                return YES;
            }
        }
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return NO;
}

// A native drop can complete asynchronously. Repair ONLY if the user released
// one actual home-screen icon INSIDE the real expanded folder's bounds, the
// icon still belongs to the root list and no duplicate is in the target.
// No direct SBFolder mutations or manual removal of the source icon.
static id FXLiveRootApp(NSString *uid, NSString *bundleID) {
    id controller = FXObject((id)NSClassFromString(@"SBIconController"), @"sharedInstance");
    id root = FXObject(FXObject(controller, @"iconManager"), @"rootFolder");
    NSUInteger count = FXUnsigned(root, @"listCount");
    SEL listSel = NSSelectorFromString(@"listAtIndex:");
    if (!root || count == NSUIntegerMax || count > 40 || ![root respondsToSelector:listSel]) return nil;
    id (*listCall)(id, SEL, NSUInteger) = (id (*)(id, SEL, NSUInteger))objc_msgSend;
    for (NSUInteger i = 0; i < count; i++) {
        id list = listCall(root, listSel, i);
        id icons = FXObject(list, @"icons");
        if (![icons isKindOfClass:NSArray.class]) continue;
        for (id icon in (NSArray *)icons) {
            if (!FXIsUsableSource(icon)) continue;
            if ((uid.length && [FXIdentifier(icon) isEqualToString:uid]) ||
                (!uid.length && bundleID.length &&
                 [FXBundleID(icon) isEqualToString:bundleID])) return icon;
        }
    }
    return nil;
}

static BOOL FXReconcileAfterNativeDrop(id source, id folder, NSString *uid,
                                       NSString *bundleID, NSUInteger generation) {
    if (generation != FXDragGeneration ||
        FXNativeHandoffSubmittedGeneration == generation) return NO;
    // Rebind both ends after SpringBoard's native placeholder/layout mutation.
    // A UI-associated SBFolderIcon may be recycled during performDrop.
    NSString *folderUID = FXIdentifier(folder);
    id currentFolder = folderUID.length ? FXFolderWithIdentifier(folderUID) : nil;
    if (!FXIsFolder(currentFolder) || !FXListModel(currentFolder) ||
        FXFolderHasApp(currentFolder, uid, bundleID)) return NO; // native drop succeeded
    // Never insert a stale SBLeafIcon that is no longer present on the desktop.
    // Rebind to the current native root-list icon instead of the pre-lift pointer.
    id liveSource = FXLiveRootApp(uid, bundleID);
    if (!liveSource && FXIsUsableSource(source) && FXListModel(source)) liveSource = source;
    if (liveSource && FXIsUsableSource(liveSource) &&
        FXNativeMoveIntoFolder(liveSource, currentFolder)) {
        FXNativeHandoffSubmittedGeneration = generation;
        return YES;
    }
    return NO;
}

// Install only if this iOS 17.1.1 image actually provides the selectors. The
// native delegate remains responsible for proposal, placeholder and layout.
%group FXSourceHooks
%hook SBIconView
- (id)dragInteraction:(id)interaction itemsForBeginningSession:(id)session {
    if (FXResizeGestureActiveForHost((UIView *)self)) return @[];
    id possibleSource = FXObject(self, @"icon");
    // Validate and capture ALL identity data BEFORE SpringBoard replaces the
    // icon with a placeholder in %orig. 1.1/0.4.x often captured too late.
    BOOL valid = FXIsUsableSource(possibleSource);
    BOOL folderDrag = FXIsFolder(possibleSource);
    BOOL eligible = valid || folderDrag;
    NSString *sourceUID = eligible ? [FXIdentifier(possibleSource) copy] : nil;
    NSString *bundleID = valid ? [FXBundleID(possibleSource) copy] : nil;
    UIView *originList = eligible ? FXNativeParentListForHost((UIView *)self) : nil;
    id originModel = originList ? FXObject(originList, @"model") : FXListModel(possibleSource);
    // 1.5.5: a second drag may begin before the 1.4-second drag-end visual
    // guard from the previous session has expired. Release its per-icon native
    // pause assertion and picture lock BEFORE sampling the next native grid.
    // The old session's asynchronous cleanup is generation-checked below.
    if (eligible && FXNativeDragIsActive()) FXClearSource();
    // Logos only emits `@class SBIconView;`; go through id/UIView so `window`
    // resolves instead of failing on a forward declaration.
    UIView *selfView = (UIView *)(id)self;
    NSArray<NSDictionary *> *nativeTargets = eligible ? FXCaptureNativeTargets(selfView.window) : nil;
    NSArray<UIView *> *visualHosts = eligible ? FXCaptureVisualHosts(selfView.window) : nil;
    // Install the visual lock before %orig; keep actual drop-target admission
    // restricted to the separate, verified native grid-range list.
    for (UIView *host in visualHosts) {
        if (folderDrag && host == (UIView *)self)
            FXSetDragVisualLockForHostNoPause(host, YES);
        else FXSetDragVisualLockForHost(host, YES);
    }
    id result = %orig;
    if (eligible && (sourceUID.length || bundleID.length || folderDrag) &&
        [result isKindOfClass:NSArray.class] && [result count] > 0) {
        FXBeginNativeDrag(possibleSource, sourceUID, bundleID, originList, originModel, nativeTargets, visualHosts);
        if (folderDrag) FXDraggedFolderHost = (UIView *)self;
        // v9 confirmed that lifting a *folder* can move four ordinary App
        // views into a stationary 4x2 folder while their model ranges remain
        // unchanged. The v8 App-frame guard is equally valid for that case.
        // Exclude the actual lifted icon view; never pin the folder's frame.
        if (nativeTargets.count)
            FXStartDragAppFrameGuard(nativeTargets, (UIView *)self);
    } else {
        for (UIView *host in visualHosts) FXSetDragVisualLockForHost(host, NO);
    }
    return result;
}
%end
%end

%group FXDestinationHooks
%hook SBIconListViewDraggingDestinationDelegate
- (UIDropProposal *)dropInteraction:(UIDropInteraction *)interaction sessionDidUpdate:(id<UIDropSession>)session {
    FXExtendActiveDragProtectionForList(interaction.view);
    UIDropProposal *proposal = %orig; // use SpringBoard's own operation
    UIView *folderHost = FXFolderAtDropLocation(interaction, session);
    BOOL nativePermitsDrop = proposal &&
        (proposal.operation == UIDropOperationCopy ||
         (proposal.operation == UIDropOperationMove && session.allowsMoveOperation));
    FXSetHoveredHost(nativePermitsDrop ? folderHost : nil);
    return proposal;
}
- (void)dropInteraction:(UIDropInteraction *)interaction performDrop:(id<UIDropSession>)session {
    UIView *targetHost = FXFolderAtDropLocation(interaction, session);
    id folder = FXObject(targetHost, @"icon");
    id source = FXDraggedLeaf;
    if (!FXIsUsableSource(source) && session.items.count == 1)
        source = FXSourceFromDragItem(session.items.firstObject);
    NSString *uid = [FXIdentifier(source) copy] ?: [FXDraggedUID copy];
    NSString *bundleID = [FXBundleID(source) copy] ?: [FXDraggedBundle copy];
    NSUInteger generation = FXDragGeneration;
    // Native drop/model commit must be free to reflow normally.
    FXStopDragAppFrameGuard();
    FXDragNativeFinalizing = YES; // Resume original temporary model before drop.
    // Never skip UIKit's original drop coordinator. A normal 1x1 folder can
    // insert synchronously here; when it succeeds no handoff is attempted.
    %orig;
    NSNumber *saved = FXSavedSize(folder);
    BOOL targetWasLarge = folder && (FXSize(folder) == FXFolderSizeLarge ||
                                     FXSize(folder) == FXFolderSizeWide ||
                                     saved.unsignedIntegerValue == FXFolderSizeLarge ||
                                     saved.unsignedIntegerValue == FXFolderSizeWide);
    if (source && folder && (uid.length || bundleID.length) && targetWasLarge) {
        // %orig may still have its internal icon-drag coordinator on the
        // stack. Let it return before asking SpringBoard's native manager to
        // accept the icon. The next main-queue turn is early enough to retain
        // its active drag preview on many builds, unlike the old 0.55s repair.
        // Every attempt checks that native insertion did not already succeed.
        dispatch_async(dispatch_get_main_queue(), ^{
            FXReconcileAfterNativeDrop(source, folder, uid, bundleID, generation);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            FXReconcileAfterNativeDrop(source, folder, uid, bundleID, generation);
        });
        // Keep the proven 1.4.6 late repair only if the source remains a
        // live root icon and neither early handoff nor native insertion won.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            FXReconcileAfterNativeDrop(source, folder, uid, bundleID, generation);
        });
    }
    FXSetHoveredHost(nil);
}
%end
%end

// No additional drag gesture. Only observe the existing native drag-end.
%group FXDestinationExitHooks
%hook SBIconListViewDraggingDestinationDelegate
- (void)dropInteraction:(UIDropInteraction *)interaction sessionDidExit:(id<UIDropSession>)session {
    %orig;
    FXSetHoveredHost(nil);
}
%end
%end

%group FXSourceEndHooks
%hook SBIconView
- (void)dragInteraction:(id)interaction session:(id)session didEndWithOperation:(UIDropOperation)operation {
    FXDragNativeFinalizing = YES; // Allow original regen on cancel/end too.
    FXStopDragAppFrameGuard(); // Stop BEFORE native final reflow.
    %orig;
    NSUInteger generation = FXDragGeneration;
    // At the first turn after UIKit has ended its drag, return layout control
    // to SpringBoard. Keep the existing image-only visual lock and 1.4-second
    // cleanup separately so the native drop handoff is not disrupted.
    NSArray<UIView *> *hosts = [FXDragVisualHosts copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != FXDragGeneration) return;
        for (UIView *host in hosts) FXReleaseDragLayoutPauseForHost(host);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == FXDragGeneration) {
            FXClearSource();
        }
    });
}
%end
%end

// Observe only while a native drag is in progress. Protect newly realized
// destination-page hosts before their own normal layout pass. The original
// SpringBoard list layout remains completely in charge of cell placement.
%group FXIncomingPageProtectionHooks
%hook SBIconListView
- (void)layoutSubviews {
    FXExtendActiveDragProtectionForList((UIView *)self);
    %orig;
}
%end
%end

// A/B-confirmed incoming-page regression: SpringBoard rebinds real 4x2/2x2
// icons into 60x74 temporary views in regenerateTemporaryDisplayedModelIfNecessary.
// Skipping it ONLY for an incoming app drag and this exact native model has
// preserved all three large hosts on the user's iOS 17.1.1 test. Unlike a
// blanket layout hook, this never overrides native size policy.
%group FXIncomingTemporaryModelGuardHooks
%hook SBIconListView
- (void)regenerateTemporaryDisplayedModelIfNecessary {
    if (FXCanSkipIncomingTemporaryRegen((UIView *)self)) return;
    %orig;
}
%end
%end

// SpringBoardHome sometimes loads these private classes AFTER tweak startup.
// Retry a bounded number of times; initialize each Logos group only once.
static BOOL FXSourceInstalled = NO;
static BOOL FXSourceEndInstalled = NO;
static BOOL FXDestinationInstalled = NO;
static BOOL FXDestinationExitInstalled = NO;
static BOOL FXIncomingPageInstalled = NO;
static BOOL FXIncomingTempModelInstalled = NO;
static void FXInstallHooks(int attempt) {
    Class icon = NSClassFromString(@"SBIconView");
    if (!FXSourceInstalled && icon &&
        class_getInstanceMethod(icon, @selector(dragInteraction:itemsForBeginningSession:))) {
        %init(FXSourceHooks);
        FXSourceInstalled = YES;
    }
    if (!FXSourceEndInstalled && icon &&
        class_getInstanceMethod(icon, @selector(dragInteraction:session:didEndWithOperation:))) {
        %init(FXSourceEndHooks);
        FXSourceEndInstalled = YES;
    }
    Class listClass = NSClassFromString(@"SBIconListView");
    if (!FXIncomingPageInstalled && listClass &&
        class_getInstanceMethod(listClass, @selector(layoutSubviews))) {
        %init(FXIncomingPageProtectionHooks);
        FXIncomingPageInstalled = YES;
    }
    // Independent selector gate: do not install/replace a missing private
    // selector on OS builds that lack the tested iOS 17.1.1 entry point.
    if (!FXIncomingTempModelInstalled && listClass &&
        class_getInstanceMethod(listClass,
            @selector(regenerateTemporaryDisplayedModelIfNecessary))) {
        %init(FXIncomingTemporaryModelGuardHooks);
        FXIncomingTempModelInstalled = YES;
    }
    Class delegate = NSClassFromString(@"SBIconListViewDraggingDestinationDelegate");
    if (!FXDestinationInstalled && delegate &&
        class_getInstanceMethod(delegate, @selector(dropInteraction:sessionDidUpdate:)) &&
        class_getInstanceMethod(delegate, @selector(dropInteraction:performDrop:))) {
        %init(FXDestinationHooks);
        FXDestinationInstalled = YES;
    }
    if (!FXDestinationExitInstalled && delegate &&
        class_getInstanceMethod(delegate, @selector(dropInteraction:sessionDidExit:))) {
        %init(FXDestinationExitHooks);
        FXDestinationExitInstalled = YES;
    }
    if (attempt >= 12 || (FXSourceInstalled && FXDestinationInstalled &&
        FXSourceEndInstalled && FXDestinationExitInstalled && FXIncomingPageInstalled &&
        FXIncomingTempModelInstalled)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FXInstallHooks(attempt + 1); });
}

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{ FXInstallHooks(0); });
}
