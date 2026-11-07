#import "FXInterface.h"
#import <math.h>

// 1.5.12: Drag presentation guard; NEVER alters icon models, occupied grid
// ranges, folder size classes, folder frames, or native drop/placeholder APIs.
//
// iOS 17.1.1 trace v8: a 4x2 folder remains at cell 0..7 and four Apps
// remain at cells 18/19/22/23, yet native drag's visual-only reflow temporarily
// moves three SBIconViews to cells 2/3/4 inside the 4x2 folder. This guard
// rejects ONLY those placements while the App's own model cell is unchanged.
// Normal movement into a free cell, a committed model change, folder drag
// previews, and any page not verified to contain expanded folders pass through.

@interface FXDragVisualZone : NSObject
@property (nonatomic, weak) UIView *list;
@property (nonatomic, weak) UIView *folderHost;
@property (nonatomic, copy) NSString *folderUID;
@property (nonatomic) CGRect occupiedRect;
@property (nonatomic) FXGridRange occupiedRange;
@end
@implementation FXDragVisualZone
@end

@interface FXDragAppSnapshot : NSObject
@property (nonatomic, weak) UIView *list;
@property (nonatomic, weak) id icon;
@property (nonatomic, copy) NSString *iconUID;
@property (nonatomic) unsigned long long cellIndex;
@property (nonatomic) CGRect originalRect;
@end
@implementation FXDragAppSnapshot
@end

static BOOL FXAppFrameGuardEnabled = NO;
static NSMapTable<UIView *, FXDragAppSnapshot *> *FXAppFrameSnapshots = nil;
static NSArray<FXDragVisualZone *> *FXDragZones = nil;
// A destination page may realize App views after its folders were captured.
// Throttle resampling; never traverse the page tree on every layout callback.
static NSMapTable<UIView *, NSNumber *> *FXLastAppSampleByList = nil;

static UIView *FXGuardRootList(UIView *host) {
    Class listClass = NSClassFromString(@"SBIconListView");
    for (UIView *parent = host.superview; parent; parent = parent.superview) {
        if (listClass && [parent isKindOfClass:listClass]) return parent;
    }
    return nil;
}

static void FXRecordAppsInList(UIView *view, UIView *list, UIView *dragSource,
                               id listModel, NSUInteger depth) {
    if (!view || depth > 12) return;
    Class iconClass = NSClassFromString(@"SBIconView");
    if (iconClass && [view isKindOfClass:iconClass]) {
        if (view == dragSource || FXGuardRootList(view) != list || !view.window) return;
        id icon = FXObject(view, @"icon");
        if (!icon || FXIsFolder(icon) || ![FXBundleID(icon) length]) return;
        FXGridRange range = FXGridOf(listModel, icon);
        if (range.columns != 1 || range.rows != 1 || range.gridCellIndex >= 48) return;
        NSString *uid = FXIdentifier(icon) ?: FXBundleID(icon);
        if (!uid.length) return;
        FXDragAppSnapshot *already = [FXAppFrameSnapshots objectForKey:view];
        if (already && [already.iconUID isEqualToString:uid] && already.list == list) return;
        CGRect rect = [view.superview convertRect:view.frame toView:list];
        if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
            rect.size.width < 45 || rect.size.width > 105 ||
            rect.size.height < 45 || rect.size.height > 115) return;
        // Late-realized views may already have been incorrectly moved into a
        // 4x2 folder by UIKit. Never make that bad position our baseline.
        for (FXDragVisualZone *zone in FXDragZones) {
            if (zone.list != list) continue;
            CGRect overlap = CGRectIntersection(rect, zone.occupiedRect);
            CGFloat area = rect.size.width * rect.size.height;
            if (!CGRectIsNull(overlap) && area > 0 &&
                overlap.size.width * overlap.size.height > 0.12 * area) return;
        }
        FXDragAppSnapshot *snapshot = [FXDragAppSnapshot new];
        snapshot.list = list;
        snapshot.icon = icon;
        snapshot.iconUID = uid;
        snapshot.cellIndex = range.gridCellIndex;
        snapshot.originalRect = rect;
        [FXAppFrameSnapshots setObject:snapshot forKey:view];
        return;
    }
    for (UIView *subview in view.subviews)
        FXRecordAppsInList(subview, list, dragSource, listModel, depth + 1);
}

void FXStartDragAppFrameGuard(NSArray<NSDictionary *> *verifiedTargets, UIView *dragSource) {
    FXAppFrameGuardEnabled = NO;
    FXAppFrameSnapshots = nil;
    FXDragZones = nil;
    FXLastAppSampleByList = nil;
    // SpringBoard can detach the lifted *source folder* from its window
    // inside the original drag callback. The already-verified targets retain
    // their own window checks below, so source.window is not required.
    if (![NSThread isMainThread] || !verifiedTargets.count) return;
    NSMutableArray<FXDragVisualZone *> *zones = [NSMutableArray array];
    NSMutableArray<UIView *> *lists = [NSMutableArray array];
    for (NSDictionary *target in verifiedTargets) {
        UIView *list = target[@"list"];
        UIView *host = target[@"host"];
        NSString *uid = target[@"uid"];
        if (![list isKindOfClass:UIView.class] || ![host isKindOfClass:UIView.class] ||
            !uid.length || !list.window || list.window != host.window ||
            FXGuardRootList(host) != list) continue;
        id icon = FXObject(host, @"icon");
        if (!FXIsFolder(icon) || ![FXIdentifier(icon) isEqualToString:uid]) continue;
        id model = FXObject(list, @"model");
        FXGridRange range = FXGridOf(model, icon);
        NSUInteger size = FXSize(icon);
        if (!((size == FXFolderSizeLarge && range.columns == 2 && range.rows == 2) ||
              (size == FXFolderSizeWide && range.columns == 4 && range.rows == 2))) continue;
        CGRect rect = [target[@"rect"] CGRectValue];
        if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
            rect.size.width < 95 || rect.size.height < 95) continue;
        FXDragVisualZone *zone = [FXDragVisualZone new];
        zone.list = list;
        zone.folderHost = host;
        zone.folderUID = uid;
        zone.occupiedRect = rect;
        zone.occupiedRange = range;
        [zones addObject:zone];
        if (![lists containsObject:list]) [lists addObject:list];
    }
    if (!zones.count) return;
    FXAppFrameSnapshots = [NSMapTable weakToStrongObjectsMapTable];
    FXLastAppSampleByList = [NSMapTable weakToStrongObjectsMapTable];
    for (UIView *list in lists)
        FXRecordAppsInList(list, list, dragSource, FXObject(list, @"model"), 0);
    if (FXAppFrameSnapshots.count) {
        FXDragZones = [zones copy];
        FXAppFrameGuardEnabled = YES;
    } else {
        FXAppFrameSnapshots = nil;
    }
}

// Entering another page can realize its icon views after the source page
// snapshot. Add only model-verified folders; never clear the original guard.
void FXExtendDragAppFrameGuard(NSArray<NSDictionary *> *verifiedTargets, UIView *dragSource) {
    if (![NSThread isMainThread] || !verifiedTargets.count) return;
    if (!FXAppFrameGuardEnabled) {
        FXStartDragAppFrameGuard(verifiedTargets, dragSource);
        return;
    }
    NSMutableArray<FXDragVisualZone *> *zones = [FXDragZones mutableCopy];
    NSMutableArray<UIView *> *listsToSample = [NSMutableArray array];
    for (NSDictionary *target in verifiedTargets) {
        UIView *list = target[@"list"];
        UIView *host = target[@"host"];
        NSString *uid = target[@"uid"];
        if (![list isKindOfClass:UIView.class] || ![host isKindOfClass:UIView.class] ||
            !uid.length || !list.window || host.window != list.window ||
            FXGuardRootList(host) != list) continue;
        id icon = FXObject(host, @"icon");
        if (!FXIsFolder(icon) || ![FXIdentifier(icon) isEqualToString:uid]) continue;
        id model = FXObject(list, @"model");
        FXGridRange range = FXGridOf(model, icon);
        NSUInteger size = FXSize(icon);
        if (!((size == FXFolderSizeLarge && range.columns == 2 && range.rows == 2) ||
              (size == FXFolderSizeWide && range.columns == 4 && range.rows == 2))) continue;
        BOOL exists = NO;
        for (FXDragVisualZone *prior in zones)
            if (prior.folderHost == host && prior.list == list &&
                [prior.folderUID isEqualToString:uid]) { exists = YES; break; }
        if (!exists) {
            CGRect rect = [target[@"rect"] CGRectValue];
            if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
                rect.size.width < 95 || rect.size.height < 95) continue;
            FXDragVisualZone *zone = [FXDragVisualZone new];
            zone.list = list;
            zone.folderHost = host;
            zone.folderUID = uid;
            zone.occupiedRect = rect;
            zone.occupiedRange = range;
            [zones addObject:zone];
        }
        // Even an *existing* folder may gain newly realized ordinary App
        // views while entering a different page. 1.5.13 only scanned if the
        // folder itself was new and missed this important case.
        if (![listsToSample containsObject:list]) [listsToSample addObject:list];
    }
    FXDragZones = [zones copy];
    CFTimeInterval now = CACurrentMediaTime();
    for (UIView *list in listsToSample) {
        NSNumber *last = [FXLastAppSampleByList objectForKey:list];
        if (last && now - last.doubleValue < 0.40) continue;
        [FXLastAppSampleByList setObject:@(now) forKey:list];
        FXRecordAppsInList(list, list, dragSource, FXObject(list, @"model"), 0);
    }
}

void FXStopDragAppFrameGuard(void) {
    FXAppFrameGuardEnabled = NO;
    FXDragZones = nil;
    FXAppFrameSnapshots = nil;
    FXLastAppSampleByList = nil;
}

static BOOL FXRejectTransientAppPosition(UIView *view, CGRect proposed) {
    if (!FXAppFrameGuardEnabled || !view || ![NSThread isMainThread] ||
        !view.window || !view.superview || !isfinite(proposed.origin.x) ||
        !isfinite(proposed.origin.y) || proposed.size.width < 45 ||
        proposed.size.width > 105 || proposed.size.height < 45 ||
        proposed.size.height > 115) return NO;
    FXDragAppSnapshot *snap = [FXAppFrameSnapshots objectForKey:view];
    UIView *list = snap.list;
    if (!snap || !list || FXGuardRootList(view) != list || !list.window ||
        ![FXIdentifier(FXObject(view, @"icon")) isEqualToString:snap.iconUID]) return NO;
    id model = FXObject(list, @"model");
    FXGridRange appRange = FXGridOf(model, FXObject(view, @"icon"));
    if (appRange.columns != 1 || appRange.rows != 1 ||
        appRange.gridCellIndex != snap.cellIndex) return NO;
    CGRect proposedInList = [view.superview convertRect:proposed toView:list];
    for (FXDragVisualZone *zone in FXDragZones) {
        if (zone.list != list || !zone.folderHost.window ||
            ![FXIdentifier(FXObject(zone.folderHost, @"icon")) isEqualToString:zone.folderUID]) continue;
        // Never trust stale saved geometry if the folder genuinely resized.
        FXGridRange current = FXGridOf(model, FXObject(zone.folderHost, @"icon"));
        if (current.gridCellIndex != zone.occupiedRange.gridCellIndex ||
            current.columns != zone.occupiedRange.columns ||
            current.rows != zone.occupiedRange.rows) continue;
        CGRect candidateOverlap = CGRectIntersection(proposedInList, zone.occupiedRect);
        CGRect originalOverlap = CGRectIntersection(snap.originalRect, zone.occupiedRect);
        CGFloat area = proposedInList.size.width * proposedInList.size.height;
        CGFloat overlap = CGRectIsNull(candidateOverlap) ? 0 :
            candidateOverlap.size.width * candidateOverlap.size.height;
        CGFloat originalArea = CGRectIsNull(originalOverlap) ? 0 :
            originalOverlap.size.width * originalOverlap.size.height;
        if (area > 0 && overlap / area > 0.58 && originalArea < area * 0.08)
            return YES; // Reject *only* wrong App visual frame, not grid mutation.
    }
    return NO;
}

%hook SBIconView
- (void)setFrame:(CGRect)frame {
    if (FXRejectTransientAppPosition((UIView *)self, frame)) return;
    %orig;
}
- (void)setCenter:(CGPoint)center {
    UIView *view = (UIView *)self;
    CGRect desired = CGRectMake(center.x - view.bounds.size.width * 0.5,
                                center.y - view.bounds.size.height * 0.5,
                                view.bounds.size.width, view.bounds.size.height);
    if (FXRejectTransientAppPosition(view, desired)) return;
    %orig;
}
%end
