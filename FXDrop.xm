#import "FXInterface.h"
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <math.h>

// All drop observations use UIKit's existing SpringBoard destination delegate.
// DO NOT install a second UIDropInteraction on the folder; that steals native
// icon edit/move sessions and makes the layout look like 1x1 on release.
// No log writing, background snapshots, direct SBFolder addIcon:, or fake cells.

static __strong id FXDraggedLeaf = nil;            // Retain the actual pre-lift SBLeafIcon.
static NSString *FXDraggedUID = nil;
static NSString *FXDraggedBundle = nil;
static __weak UIView *FXHoveredHost = nil;
static NSUInteger FXDragGeneration = 0;
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
BOOL FXNativeDragIsActive(void) { return FXDraggedLeaf != nil; }

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

static void FXBeginNativeDrag(id icon, NSString *uid, NSString *bundleID,
                              NSArray<NSDictionary *> *verifiedTargets, NSArray<UIView *> *visualHosts) {
    ++FXDragGeneration;
    FXDraggedLeaf = icon;
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
    FXSetHoveredHost(nil);
    for (UIView *host in FXDragVisualHosts)
        FXSetDragVisualLockForHost(host, NO);
    FXDraggedLeaf = nil;
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

// List-level hit adjustment: only within a *real*, live 2x2 folder and
// only when a native SpringBoard icon drag is in progress. A visual 2x2 frame
// without verified model occupancy must not be treated as a drop destination.
BOOL FXResolveNativeFolderListHit(UIView *list, CGPoint point,
                                  id stock, id *replacement, NSUInteger *index) {
    if (!FXNativeDragIsActive() || !list || !list.window ||
        !CGRectContainsPoint(list.bounds, point)) return NO;
    // Do not blindly trust a stock hit on ANOTHER folder: during native
    // placeholder reflow, a 4x2 folder's cell can temporarily be hit as the
    // neighboring icon. Only a pre-lift VERIFIED 4x2 footprint may override
    // such a hit; normal 2x2 stock behavior is left unchanged.
    // Native hover can return a placeholder while the folder's image is
    // momentarily reduced. The pre-lift cache was captured only from a
    // genuinely occupied 2x2/4x2 SBFolderIcon in THIS list.
    UIView *cached = FXCachedTargetForList(list, point);
    UIView *host = cached ?: FXLargeFolderHostInTree(list, list, point, 0);
    id folder = FXObject(host, @"icon");
    if (!host || (!cached && !FXIsGenuineLarge(folder))) return NO;
    if (FXIsFolder(stock)) {
        if ([FXIdentifier(stock) isEqualToString:FXIdentifier(folder)]) return NO;
        // The old hit may be a neighboring 1x1 folder; only override it
        // when the original 4x2 cell was verified before drag lift.
        if (!cached || !FXWasCapturedWideHost(list, cached)) return NO;
    }
    SEL indexSelector = NSSelectorFromString(@"indexOfIcon:");
    // Different iOS 17 SpringBoardHome builds expose the list position on
    // SBIconListView or on its SBIconListModel. Neither is fabricated.
    id indexOwner = [list respondsToSelector:indexSelector] ? list : FXListModel(folder);
    if (!indexOwner || ![indexOwner respondsToSelector:indexSelector]) return NO;
    NSMethodSignature *sig = [indexOwner methodSignatureForSelector:indexSelector];
    if (!sig || sig.numberOfArguments != 3) return NO;
    NSUInteger (*getIndex)(id, SEL, id) =
        (NSUInteger (*)(id, SEL, id))objc_msgSend;
    NSUInteger position = getIndex(indexOwner, indexSelector, folder);
    if (position == NSNotFound) return NO;
    if (replacement) *replacement = folder;
    if (index) *index = position;
    return YES;
}

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
    NSString *sourceUID = valid ? [FXIdentifier(possibleSource) copy] : nil;
    NSString *bundleID = valid ? [FXBundleID(possibleSource) copy] : nil;
    // 1.5.5: a second drag may begin before the 1.4-second drag-end visual
    // guard from the previous session has expired. Release its per-icon native
    // pause assertion and picture lock BEFORE sampling the next native grid.
    // The old session's asynchronous cleanup is generation-checked below.
    if (valid && FXDraggedLeaf) FXClearSource();
    NSArray<NSDictionary *> *nativeTargets = valid ? FXCaptureNativeTargets(self.window) : nil;
    NSArray<UIView *> *visualHosts = valid ? FXCaptureVisualHosts(self.window) : nil;
    // Install the visual lock before %orig; keep actual drop-target admission
    // restricted to the separate, verified native grid-range list.
    for (UIView *host in visualHosts) FXSetDragVisualLockForHost(host, YES);
    id result = %orig;
    if (valid && (sourceUID.length || bundleID.length) &&
        [result isKindOfClass:NSArray.class] && [result count] > 0) {
        FXBeginNativeDrag(possibleSource, sourceUID, bundleID, nativeTargets, visualHosts);
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

// SpringBoardHome sometimes loads these private classes AFTER tweak startup.
// Retry a bounded number of times; initialize each Logos group only once.
static BOOL FXSourceInstalled = NO;
static BOOL FXSourceEndInstalled = NO;
static BOOL FXDestinationInstalled = NO;
static BOOL FXDestinationExitInstalled = NO;
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
        FXSourceEndInstalled && FXDestinationExitInstalled)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FXInstallHooks(attempt + 1); });
}

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{ FXInstallHooks(0); });
}
