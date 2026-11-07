#import "FXCore.h"
#import <dispatch/dispatch.h>
#import <math.h>
#import <string.h>
#import <stdint.h>

// Separate preferences from every FolderExpand/FolderX 0.x experiment.
static NSString *const FXPreferencesDomain = @"com.huhansibuxin.folderx.fresh";
static NSString *const FXSizeMapKey = @"folderSizeByIdentifier";
static NSString *const FXBlockedOpenMapKey = @"folderOpenBlockedByIdentifier";
static char kFXRestoreScheduled;
static char kFXEditingObserved;

id FXObject(id obj, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    id (*call)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return call(obj, sel);
}

NSUInteger FXUnsigned(id obj, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!obj || ![obj respondsToSelector:sel]) return NSUIntegerMax;
    NSUInteger (*call)(id, SEL) = (NSUInteger (*)(id, SEL))objc_msgSend;
    return call(obj, sel);
}

BOOL FXBoolean(id obj, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!obj || ![obj respondsToSelector:sel]) return NO;
    BOOL (*call)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    return call(obj, sel);
}

BOOL FXIsFolder(id icon) {
    Class cls = NSClassFromString(@"SBFolderIcon");
    return cls && [icon isKindOfClass:cls];
}

NSString *FXIdentifier(id icon) {
    id value = FXObject(icon, @"uniqueIdentifier");
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

NSUInteger FXSize(id icon) {
    return FXUnsigned(icon, @"gridSizeClass");
}

static id FXRootFolder(void) {
    Class cls = NSClassFromString(@"SBIconController");
    id controller = FXObject((id)cls, @"sharedInstance");
    return FXObject(FXObject(controller, @"iconManager"), @"rootFolder");
}

id FXListModel(id icon) {
    if (!icon) return nil;
    id root = FXRootFolder();
    if (!root) return nil;
    SEL indexSel = NSSelectorFromString(@"indexOfListContainingIcon:");
    SEL listSel = NSSelectorFromString(@"listAtIndex:");
    NSUInteger count = FXUnsigned(root, @"listCount");
    if (![root respondsToSelector:listSel] || count == NSUIntegerMax || count > 100) return nil;
    if ([root respondsToSelector:indexSel]) {
        NSInteger (*indexCall)(id, SEL, id) = (NSInteger (*)(id, SEL, id))objc_msgSend;
        NSInteger index = indexCall(root, indexSel, icon);
        if (index >= 0 && (NSUInteger)index < count) {
            id (*listCall)(id, SEL, NSUInteger) = (id (*)(id, SEL, NSUInteger))objc_msgSend;
            id list = listCall(root, listSel, (NSUInteger)index);
            if (list) return list;
        }
    }
    SEL containsSel = NSSelectorFromString(@"containsIcon:");
    id (*listCall)(id, SEL, NSUInteger) = (id (*)(id, SEL, NSUInteger))objc_msgSend;
    for (NSUInteger index = 0; index < count; index++) {
        id list = listCall(root, listSel, index);
        if ([list respondsToSelector:containsSel]) {
            BOOL (*containsCall)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
            if (containsCall(list, containsSel, icon)) return list;
        }
    }
    return nil;
}

// SpringBoard may recycle SBIcon / SBIconView while editing a page. A resize
// request sent to the recycled object can succeed syntactically yet mutate no
// live list. Resolve by stable uniqueIdentifier before any model write.
static id FXCurrentRootIcon(id candidate) {
    NSString *uid = FXIdentifier(candidate);
    if (!uid.length) return candidate;
    id root = FXRootFolder();
    NSUInteger count = FXUnsigned(root, @"listCount");
    SEL getList = NSSelectorFromString(@"listAtIndex:");
    if (!root || count == NSUIntegerMax || count > 80 ||
        ![root respondsToSelector:getList]) return candidate;
    id (*get)(id, SEL, NSUInteger) = (id (*)(id, SEL, NSUInteger))objc_msgSend;
    for (NSUInteger i = 0; i < count; ++i) {
        id list = get(root, getList, i);
        id values = FXObject(list, @"icons");
        if (![values isKindOfClass:NSArray.class]) continue;
        for (id item in (NSArray *)values) {
            if ([FXIdentifier(item) isEqualToString:uid]) return item;
        }
    }
    return candidate;
}

FXGridRange FXGridOf(id model, id icon) {
    FXGridRange zero = {0, 0, 0};
    SEL sel = NSSelectorFromString(@"gridRangeForIcon:gridCellInfoOptions:");
    if (!icon || !model || ![model respondsToSelector:sel]) return zero;
    // This is a returned C struct, not an Objective-C object. A wrong ABI
    // declaration can corrupt registers on arm64e. Fail closed if it differs.
    NSMethodSignature *signature = [model methodSignatureForSelector:sel];
    if (!signature || signature.numberOfArguments != 4 ||
        signature.methodReturnLength != sizeof(FXGridRange) ||
        signature.methodReturnType[0] != '{') return zero;
    FXGridRange (*call)(id, SEL, id, NSUInteger) =
        (FXGridRange (*)(id, SEL, id, NSUInteger))objc_msgSend;
    return call(model, sel, icon, 0);
}

BOOL FXIsGenuineLarge(id icon) {
    icon = FXCurrentRootIcon(icon);
    if (!FXIsFolder(icon)) return NO;
    FXGridRange range = FXGridOf(FXListModel(icon), icon);
    return (FXSize(icon) == FXFolderSizeLarge && range.columns == 2 && range.rows == 2) ||
           (FXSize(icon) == FXFolderSizeWide && range.columns == 4 && range.rows == 2);
}

// The model range API is private and sometimes not inspectable with
// NSMethodSignature on a particular SpringBoardHome build. Rendering may still
// be correct when SpringBoard itself gave the folder a 2x2-sized icon view.
// Do not reuse this visual fallback to claim real occupancy or authorize model
// mutations: only FXIsGenuineLarge is proof of 2x2 model cells.
BOOL FXShouldRenderLarge(id icon, UIView *host) {
    if (!FXIsFolder(icon) || !host) return NO;
    // Cheap checks first: this path is called repeatedly during SpringBoard
    // layout. Do not enumerate the entire Home Screen on every frame.
    if (MIN(host.bounds.size.width, host.bounds.size.height - 14) < 110) return NO;
    if (FXSize(icon) != FXFolderSizeLarge && FXSize(icon) != FXFolderSizeWide) icon = FXCurrentRootIcon(icon);
    if (FXSize(icon) != FXFolderSizeLarge && FXSize(icon) != FXFolderSizeWide) return NO;
    static NSMutableDictionary<NSString *, NSNumber *> *cache;
    static CFTimeInterval cacheAt = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (!cache || now - cacheAt >= 0.18) {
        cache = [NSMutableDictionary dictionary];
        cacheAt = now;
    }
    NSString *key = [NSString stringWithFormat:@"%p-%lu", icon, (unsigned long)FXSize(icon)];
    NSNumber *cached = cache[key];
    if (cached) return cached.boolValue;
    FXGridRange range = FXGridOf(FXListModel(icon), icon);
    BOOL visible = !(range.columns && range.rows) ||
        (FXSize(icon) == FXFolderSizeLarge && range.columns == 2 && range.rows == 2) ||
        (FXSize(icon) == FXFolderSizeWide && range.columns == 4 && range.rows == 2);
    cache[key] = @(visible);
    return visible; // rendering fallback; never a model occupancy assertion
}

static NSUserDefaults *FXDefaults(void) {
    static NSUserDefaults *defaults = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:FXPreferencesDomain];
    });
    return defaults;
}

NSNumber *FXSavedSize(id icon) {
    NSString *uid = FXIdentifier(icon);
    if (!uid) return nil;
    NSDictionary *map = [FXDefaults() dictionaryForKey:FXSizeMapKey];
    id size = map[uid];
    return [size isKindOfClass:NSNumber.class] ? size : nil;
}

// A per-folder menu toggle. Never affects gridSizeClass or drag/drop.
BOOL FXFolderEntryBlocked(id icon) {
    if (!FXIsFolder(icon)) return NO;
    NSString *uid = FXIdentifier(icon);
    if (!uid.length) return NO;
    id value = [[FXDefaults() dictionaryForKey:FXBlockedOpenMapKey] objectForKey:uid];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}

// SBIconView tap callbacks are not the only path to a folder opening on
// iOS 17. SpringBoardHome can open a folder directly through SBHIconManager.
// Unlike view-only detection, manager-level opening must use the folder model
// identity, and must never write icon grid classes or frames.
BOOL FXShouldBlockFolderOpenIcon(id icon) {
    // Opening and accepting a drop are different actions. An active (or just
    // ended) native drag must not silently bypass the per-folder entry block:
    // FXDrop.xm handles insertion through UIKit's native drop coordinator.
    // In 1.5.14 the stale drag source is retained up to 1.4 s after lift/end,
    // which made a blocked folder open on a subsequent tap. Fail closed for
    // entry regardless of drag state; never modify the drop delegate itself.
    if (!FXIsFolder(icon) || !FXFolderEntryBlocked(icon))
        return NO;
    if (FXIsGenuineLarge(icon)) return YES;
    NSNumber *saved = FXSavedSize(icon);
    return saved && (saved.unsignedIntegerValue == FXFolderSizeLarge ||
                     saved.unsignedIntegerValue == FXFolderSizeWide);
}

void FXSetFolderEntryBlockedByIdentifier(NSString *uid, BOOL blocked) {
    if (!uid.length) return;
    NSUserDefaults *defaults = FXDefaults();
    NSMutableDictionary *map = [[defaults dictionaryForKey:FXBlockedOpenMapKey] mutableCopy];
    if (!map) map = [NSMutableDictionary dictionary];
    if (blocked) map[uid] = @YES;
    else [map removeObjectForKey:uid];
    [defaults setObject:map forKey:FXBlockedOpenMapKey];
}

static void FXSaveSize(id icon, FXFolderSize target) {
    NSString *uid = FXIdentifier(icon);
    if (!uid) return;
    NSUserDefaults *defaults = FXDefaults();
    NSMutableDictionary *map = [[defaults dictionaryForKey:FXSizeMapKey] mutableCopy];
    if (!map) map = [NSMutableDictionary dictionary];
    map[uid] = @(target);
    [defaults setObject:map forKey:FXSizeMapKey];
}

// Read native layout mappings without mutating a folder. Different iOS
// SpringBoardHome builds return their two grid dimensions as 16-byte CGFloat,
// 16-byte NSUInteger, 8-byte uint32, or 4-byte uint16 structs. NSInvocation
// copies the actual ABI size rather than assuming a CGSize return.
static BOOL FXReadNativeGridSize(id object, SEL sel, NSUInteger gridClass,
                                 NSUInteger *columns, NSUInteger *rows) {
    if (!object || ![object respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [object methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments != 3 || sig.methodReturnType[0] != '{' ||
        (sig.methodReturnLength != 4 && sig.methodReturnLength != 8 &&
         sig.methodReturnLength != 16)) return NO;
    uint8_t bytes[16] = {0};
    @try {
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:sig];
        call.target = object;
        call.selector = sel;
        [call setArgument:&gridClass atIndex:2];
        [call invoke];
        [call getReturnValue:bytes];
    } @catch (__unused NSException *ex) { return NO; }
    NSUInteger a = 0, b = 0;
    if (sig.methodReturnLength == 4) {
        uint16_t d[2]; memcpy(d, bytes, sizeof(d));
        a = d[0]; b = d[1];
    } else if (sig.methodReturnLength == 8) {
        uint32_t d[2]; memcpy(d, bytes, sizeof(d));
        a = d[0]; b = d[1];
    } else {
        double floats[2]; memcpy(floats, bytes, sizeof(floats));
        if (isfinite(floats[0]) && isfinite(floats[1]) &&
            floats[0] >= 1 && floats[0] <= 8 && floats[1] >= 1 &&
            floats[1] <= 8 && floor(floats[0]) == floats[0] &&
            floor(floats[1]) == floats[1]) {
            a = (NSUInteger)floats[0]; b = (NSUInteger)floats[1];
        } else {
            uint64_t d[2]; memcpy(d, bytes, sizeof(d));
            a = (NSUInteger)d[0]; b = (NSUInteger)d[1];
        }
    }
    if (a < 1 || a > 8 || b < 1 || b > 8) return NO;
    *columns = a;
    *rows = b;
    return YES;
}

// Never infer that enum 2 is 4x2 solely from the number. A verified mapping
// must agree for *all three* classes (1x1, 2x2, 4x2) on the SAME source.
// Query the live list model as well as the manager: iOS 17 frequently keeps
// its grid-class mapping with SBIconListModel rather than the icon manager.
BOOL FXCanUseWideGrid(void) {
    static BOOL verified = NO;
    if (verified) return YES;
    id controller = FXObject((id)NSClassFromString(@"SBIconController"), @"sharedInstance");
    id manager = FXObject(controller, @"iconManager");
    id model = FXObject(manager, @"iconModel");
    id root = FXObject(manager, @"rootFolder");
    id rootList = nil;
    if ([root respondsToSelector:NSSelectorFromString(@"listAtIndex:")] &&
        FXUnsigned(root, @"listCount") > 0 && FXUnsigned(root, @"listCount") < 80)
        rootList = ((id (*)(id, SEL, NSUInteger))objc_msgSend)
            (root, NSSelectorFromString(@"listAtIndex:"), 0);
    NSArray *sources = @[rootList ?: [NSNull null], root ?: [NSNull null],
                         model ?: [NSNull null], manager ?: [NSNull null]];
    NSArray<NSString *> *selectors = @[@"gridSizeForGridSizeClass:",
                                       @"iconGridSizeForGridSizeClass:"];
    for (id source in sources) {
        if (source == [NSNull null]) continue;
        for (NSString *name in selectors) {
            SEL sel = NSSelectorFromString(name);
            NSUInteger w0=0,h0=0,w1=0,h1=0,w2=0,h2=0;
            if (!FXReadNativeGridSize(source, sel, FXFolderSizeSmall, &w0, &h0) ||
                !FXReadNativeGridSize(source, sel, FXFolderSizeLarge, &w1, &h1) ||
                !FXReadNativeGridSize(source, sel, FXFolderSizeWide, &w2, &h2))
                continue;
            if (w0 == 1 && h0 == 1 && w1 == 2 && h1 == 2 &&
                w2 == 4 && h2 == 2) {
                verified = YES;
                return YES;
            }
        }
    }
    // Do not cache a negative: SpringBoardHome can load more of the model later.
    return NO;
}

// The 1.4.0 root-wide inventory was an unconditional prerequisite: one
// nonstandard icon without uniqueIdentifier disabled *every* resize.
// Compare full identifiers when available, or a complete count as a second
// signal. Neither result is a substitute for the per-page capacity guard.
static NSArray<NSString *> *FXRootInventory(void) {
    id root = FXRootFolder();
    NSUInteger count = FXUnsigned(root, @"listCount");
    SEL getList = NSSelectorFromString(@"listAtIndex:");
    if (!root || count == NSUIntegerMax || count > 80 ||
        ![root respondsToSelector:getList]) return nil;
    id (*get)(id, SEL, NSUInteger) = (id (*)(id, SEL, NSUInteger))objc_msgSend;
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSUInteger page = 0; page < count; ++page) {
        NSArray *icons = FXObject(get(root, getList, page), @"icons");
        if (![icons isKindOfClass:NSArray.class]) return nil;
        for (id item in icons) {
            NSString *key = FXIdentifier(item);
            if (!key.length) key = FXBundleID(item);
            if (!key.length) return nil;
            [result addObject:key];
        }
    }
    [result sortUsingSelector:@selector(compare:)];
    return result;
}

static NSUInteger FXRootItemCount(void) {
    id root = FXRootFolder();
    NSUInteger count = FXUnsigned(root, @"listCount");
    SEL getList = NSSelectorFromString(@"listAtIndex:");
    if (!root || count == NSUIntegerMax || count > 80 ||
        ![root respondsToSelector:getList]) return NSUIntegerMax;
    id (*get)(id, SEL, NSUInteger) = (id (*)(id, SEL, NSUInteger))objc_msgSend;
    NSUInteger total = 0;
    for (NSUInteger page = 0; page < count; ++page) {
        NSArray *icons = FXObject(get(root, getList, page), @"icons");
        if (![icons isKindOfClass:NSArray.class]) return NSUIntegerMax;
        total += icons.count;
    }
    return total;
}

// Prefer the actual layout model's rows/columns. The 1.4.0 magic fallback
// of 20 cells was smaller than a 4-column x 6-row iPhone 15 Pro home page.
static NSUInteger FXPageCellCapacity(id list) {
    SEL sizeSel = NSSelectorFromString(@"gridSize");
    if ([list respondsToSelector:sizeSel]) {
        NSMethodSignature *sig = [list methodSignatureForSelector:sizeSel];
        if (sig && sig.numberOfArguments == 2 &&
            sig.methodReturnLength == sizeof(CGSize) &&
            sig.methodReturnType[0] == '{') {
            CGSize (*readSize)(id, SEL) = (CGSize (*)(id, SEL))objc_msgSend;
            CGSize size = readSize(list, sizeSel);
            // Supports (columns,rows) or (rows,columns); both have 24 cells.
            if (size.width >= 3 && size.width <= 8 &&
                size.height >= 3 && size.height <= 9 &&
                floor(size.width) == size.width && floor(size.height) == size.height)
                return (NSUInteger)(size.width * size.height);
        }
    }
    NSUInteger maximum = FXUnsigned(list, @"maxIconCount");
    if (maximum != NSUIntegerMax && maximum >= 12 && maximum <= 48)
        return maximum;
    // Device-specific fallback only for the stated iPhone 15 Pro display,
    // running the iOS 17 4x6 home grid. Other layouts fail closed.
    CGSize screen = UIScreen.mainScreen.bounds.size;
    CGFloat narrow = MIN(screen.width, screen.height);
    CGFloat tall = MAX(screen.width, screen.height);
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone &&
        narrow >= 390 && narrow <= 395 && tall >= 850 && tall <= 855)
        return 24;
    return 0;
}

static NSUInteger FXCellsForIcon(id list, id item) {
    FXGridRange r = FXGridOf(list, item);
    if (r.columns >= 1 && r.columns <= 4 &&
        r.rows >= 1 && r.rows <= 6) return r.columns * r.rows;
    // Some 17.1.1 models do not expose gridRange for regular 1x1 apps.
    // SBApplicationIcon / SBWebClipIcon themselves occupy one cell; some
    // builds don't expose a gridSizeClass getter on these leaf icon objects.
    // Never infer the occupancy of widgets or arbitrary third-party icons.
    NSString *className = NSStringFromClass([item class]);
    BOOL regular = [className containsString:@"ApplicationIcon"] ||
                   [className containsString:@"WebClipIcon"] ||
                   [className containsString:@"BookmarkIcon"];
    if (regular && ![className containsString:@"Widget"]) return 1;
    // For a normal 1x1 *folder* whose grid range is unavailable we know its
    // current size-class, but cannot assume the same for custom icons.
    if (FXIsFolder(item) && FXSize(item) == FXFolderSizeSmall) return 1;
    return 0;
}

// Fail closed for an actually full page, unknown widget dimensions or an
// unverified layout. Do not require TWO unrelated spare cells or an unrelated
// page's identifiers to be readable just to expand an ordinary folder.
static BOOL FXPreflightExpansion(id icon, id list, FXFolderSize target) {
    NSArray *icons = FXObject(list, @"icons");
    if (![icons isKindOfClass:NSArray.class]) return NO;
    NSUInteger capacity = FXPageCellCapacity(list);
    if (!capacity) return NO;
    NSUInteger occupied = 0;
    for (id item in icons) {
        NSUInteger cells = FXCellsForIcon(list, item);
        if (!cells || occupied > capacity || cells > capacity - occupied)
            return NO;
        occupied += cells;
    }
    NSUInteger current = FXCellsForIcon(list, icon);
    NSUInteger wanted = target == FXFolderSizeWide ? 8 : 4;
    if (!current) return NO;
    if (wanted <= current) return YES;
    return wanted - current <= capacity - occupied;
}

id FXFolderWithIdentifier(NSString *uid) {
    if (!uid.length) return nil;
    id root = FXRootFolder();
    NSUInteger count = FXUnsigned(root, @"listCount");
    SEL getList = NSSelectorFromString(@"listAtIndex:");
    if (!root || count == NSUIntegerMax || count > 80 ||
        ![root respondsToSelector:getList]) return nil;
    id (*get)(id, SEL, NSUInteger) = (id (*)(id, SEL, NSUInteger))objc_msgSend;
    for (NSUInteger page = 0; page < count; ++page) {
        NSArray *icons = FXObject(get(root, getList, page), @"icons");
        if (![icons isKindOfClass:NSArray.class]) continue;
        for (id item in icons)
            if (FXIsFolder(item) && [FXIdentifier(item) isEqualToString:uid])
                return item;
    }
    return nil;
}

// This is the ONLY size-changing path in the new project.
// Setting SBFolderIcon.gridSizeClass directly would change the icon's visual
// state without reliably updating the list model's real occupied cells.
BOOL FXChangeSize(id icon, FXFolderSize target, BOOL persist) {
    icon = FXCurrentRootIcon(icon);
    if (!FXIsFolder(icon) || (target != FXFolderSizeSmall &&
        target != FXFolderSizeLarge && target != FXFolderSizeWide)) return NO;
    if (target == FXFolderSizeWide && !FXCanUseWideGrid()) return NO;
    id list = FXListModel(icon);
    SEL change = NSSelectorFromString(@"changeGridSizeClassOfContainedIcon:toGridSizeClass:gridCellInfoOptions:");
    if (!list || ![list respondsToSelector:change]) return NO;
    NSMethodSignature *signature = [list methodSignatureForSelector:change];
    if (!signature || signature.numberOfArguments != 5) return NO;

    FXGridRange before = FXGridOf(list, icon);
    if (FXSize(icon) == target &&
        ((target == FXFolderSizeLarge && before.columns == 2 && before.rows == 2) ||
         (target == FXFolderSizeWide && before.columns == 4 && before.rows == 2) ||
         (target == FXFolderSizeSmall && before.columns == 1 && before.rows == 1))) {
        if (persist) FXSaveSize(icon, target);
        return YES;
    }

    // Fail closed if same-page icons cannot be accounted for. A previous build
    // resized a completely full page and icons vanished instead of overflowing
    // into a new page; unlike a safe native drag, this method is not a page
    // reflow transaction. Do not mutate an overcrowded page.
    if (target != FXFolderSizeSmall && !FXPreflightExpansion(icon, list, target)) return NO;
    NSArray<NSString *> *beforeInventory = FXRootInventory();
    NSUInteger beforeCount = FXRootItemCount();
    // An identifier-only failure is no longer an unconditional refusal. We
    // still require a complete root item count and spare cells on this page.
    if (beforeCount == NSUIntegerMax) return NO;
    NSUInteger original = FXSize(icon);
    @try {
        // Private API observed for the target version. Do not assume an
        // object return value (the call result is intentionally ignored).
        void (*call)(id, SEL, id, NSUInteger, NSUInteger) =
            (void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend;
        call(list, change, icon, target, 0);
    } @catch (__unused NSException *exception) {
        return NO;
    }

    FXGridRange after = FXGridOf(list, icon);
    BOOL geometryOK = (target == FXFolderSizeLarge && after.columns == 2 && after.rows == 2) ||
        (target == FXFolderSizeWide && after.columns == 4 && after.rows == 2) ||
        (target == FXFolderSizeSmall && after.columns == 1 && after.rows == 1);
    NSArray<NSString *> *afterInventory = FXRootInventory();
    NSUInteger afterCount = FXRootItemCount();
    BOOL inventoryOK = afterCount != NSUIntegerMax && afterCount == beforeCount &&
        (!beforeInventory || (afterInventory &&
                              [afterInventory isEqualToArray:beforeInventory]));
    BOOL good = FXSize(icon) == target && geometryOK && inventoryOK;
    if (!good && original != target) {
        // The contract has failed: do not persist the enlarged size. This is a
        // best-effort immediate rollback; a manual backup remains essential.
        @try {
            ((void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)
                (list, change, icon, original, 0);
        } @catch (__unused NSException *exception) {}
    }
    if (good && persist) FXSaveSize(icon, target);
    return good;
}

void FXRestoreSizeForView(UIView *host) {
    if (FXIsEditing(host) || FXNativeDragIsActive()) return; // no relayout during native drag
    id icon = FXObject(host, @"icon");
    if (!FXIsFolder(icon)) return;
    NSString *uid = FXIdentifier(icon);
    NSNumber *saved = FXSavedSize(icon);
    if (!uid || !saved || (saved.unsignedIntegerValue != FXFolderSizeLarge &&
                          saved.unsignedIntegerValue != FXFolderSizeWide)) return;
    if (FXIsGenuineLarge(icon)) return;

    // Only schedule once per (reused) icon view/identifier; no repeating timers.
    NSString *scheduledUID = objc_getAssociatedObject(host, &kFXRestoreScheduled);
    if ([scheduledUID isEqualToString:uid]) return;
    objc_setAssociatedObject(host, &kFXRestoreScheduled, uid, OBJC_ASSOCIATION_COPY_NONATOMIC);
    __weak UIView *weakHost = host;
    for (NSNumber *delay in @[@(0.6), @(2.0), @(5.0)]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *view = weakHost;
            if (!view || !view.window || FXIsEditing(view) || FXNativeDragIsActive()) return;
            id current = FXObject(view, @"icon");
            if (![FXIdentifier(current) isEqualToString:uid] || FXIsGenuineLarge(current)) return;
            // A user may deliberately shrink the folder after this job was scheduled.
            // Never override a later explicit 1x1 preference with stale recovery work.
            NSUInteger wanted = [FXSavedSize(current) unsignedIntegerValue];
            if (wanted != FXFolderSizeLarge && wanted != FXFolderSizeWide) return;
            (void)FXChangeSize(current, (FXFolderSize)wanted, NO);
            [view setNeedsLayout];
        });
    }
}

// Read each native folder page in display order. On iOS 17 the allIcons
// convenience accessor can report only the current/first page, so treating a
// valid 9-item array as "complete" silently removes icons 10-12 from the
// 4x2 outer / 2x6 inner enlarged preview. Never change the folder model.
static void FXAppendUniqueFolderApps(NSMutableArray *out,
                                     NSMutableSet<NSString *> *seen, id values) {
    if (![values isKindOfClass:NSArray.class] &&
        ![values isKindOfClass:NSSet.class]) return;
    id sequence = [values isKindOfClass:NSSet.class] ? [values allObjects] : values;
    for (id item in sequence) {
        if (![FXBundleID(item) length]) continue;
        NSString *identity = FXIdentifier(item) ?: FXBundleID(item);
        if (!identity.length || [seen containsObject:identity]) continue;
        [seen addObject:identity];
        [out addObject:item];
        if (out.count >= 12) break;
    }
}

NSArray *FXFolderApps(id folderIcon) {
    id folder = FXObject(folderIcon, @"folder");
    if (!folder) return @[];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:12];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:12];

    // Prefer the real ordered page lists: list 0 holds the first nine on many
    // versions, but a large folder can contain 10+ applications on list 1.
    NSUInteger listCount = FXUnsigned(folder, @"listCount");
    SEL listSelector = NSSelectorFromString(@"listAtIndex:");
    if (listCount != NSUIntegerMax && listCount <= 64 &&
        [folder respondsToSelector:listSelector]) {
        id (*listAtIndex)(id, SEL, NSUInteger) =
            (id (*)(id, SEL, NSUInteger))objc_msgSend;
        for (NSUInteger i = 0; i < listCount && result.count < 12; ++i) {
            id list = listAtIndex(folder, listSelector, i);
            FXAppendUniqueFolderApps(result, seen, FXObject(list, @"icons"));
        }
    }
    // Some builds omit listCount/listAtIndex; if the native lists expose only
    // a subset, allIcons can still complete the 12 without duplicating apps.
    if (result.count < 12)
        FXAppendUniqueFolderApps(result, seen, FXObject(folder, @"allIcons"));
    if (result.count < 12)
        FXAppendUniqueFolderApps(result, seen, FXObject(folder, @"icons"));
    return result;
}

NSString *FXBundleID(id leafIcon) {
    id value = FXObject(leafIcon, @"applicationBundleID");
    if ([value isKindOfClass:NSString.class] && [value length]) return value;
    value = FXObject(FXObject(leafIcon, @"application"), @"bundleIdentifier");
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

UIImage *FXAppImage(NSString *bundleID) {
    if (!bundleID.length) return nil;
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 64; });
    UIImage *stored = [cache objectForKey:bundleID];
    if (stored) return stored;
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:selector]) return nil;
    UIImage *(*call)(id, SEL, id, int, CGFloat) =
        (UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend;
    UIImage *image = nil;
    @try { image = call((id)UIImage.class, selector, bundleID, 3, UIScreen.mainScreen.scale); }
    @catch (__unused NSException *exception) { image = nil; }
    if ([image isKindOfClass:UIImage.class]) [cache setObject:image forKey:bundleID];
    return image;
}

// iOS 17.1.1 native taps use a non-nil SBIconLaunchContext containing
// _activationSettings and _iconView. The v19/v20 Frida traces proved that
// calling -launchFromLocation:context: with nil produces empty settings and
// a nil workspace entity even though the method returns normally.
//
// Request the settings from SpringBoard's OWN launch-settings provider for
// the existing on-screen SBIconView. We never fabricate activation settings,
// set model/grid data, or use a NSNumber as an icon location.
static id FXNativeLaunchSettingsForHost(UIView *host) {
    Class iconViewClass = NSClassFromString(@"SBIconView");
    if (!host || !iconViewClass || ![host isKindOfClass:iconViewClass] || !host.window)
        return nil;
    id controller = FXObject((id)NSClassFromString(@"SBIconController"), @"sharedInstance");
    id providers[] = { controller, FXObject(controller, @"iconManager") };
    SEL selector = NSSelectorFromString(@"launchActivationSettingsForIconView:");
    Class settingsClass = NSClassFromString(@"SBActivationSettings");
    if (!settingsClass) return nil;
    for (NSUInteger i = 0; i < sizeof(providers)/sizeof(providers[0]); ++i) {
        id provider = providers[i];
        if (!provider || ![provider respondsToSelector:selector]) continue;
        NSMethodSignature *signature = [provider methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments != 3 ||
            signature.methodReturnType[0] != '@' ||
            [signature getArgumentTypeAtIndex:2][0] != '@') continue;
        @try {
            id (*invoke)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            id settings = invoke(provider, selector, host);
            // Fail closed. An empty settings object was exactly what caused
            // workspace entity=nil in the v19/v20 device traces.
            if ([settings isKindOfClass:settingsClass] &&
                [[settings description] rangeOfString:@"(empty)"].location == NSNotFound)
                return settings;
        } @catch (__unused NSException *exception) { }
    }
    return nil;
}

static id FXMakeNativeLaunchContext(UIView *sourceHost) {
    id settings = FXNativeLaunchSettingsForHost(sourceHost);
    Class cls = NSClassFromString(@"SBIconLaunchContext");
    if (!settings || !cls) return nil;
    Ivar settingsField = class_getInstanceVariable(cls, "_activationSettings");
    Ivar iconViewField = class_getInstanceVariable(cls, "_iconView");
    if (!settingsField || !iconViewField ||
        ivar_getTypeEncoding(settingsField)[0] != '@' ||
        ivar_getTypeEncoding(iconViewField)[0] != '@') return nil;
    id context = nil;
    @try {
        context = [[cls alloc] init];
        if (!context || ![context isKindOfClass:cls]) return nil;
        // These two ivars are independently confirmed on the user's device
        // by v20 (rather than guessed from a header for another iOS build).
        object_setIvar(context, settingsField, settings);
        object_setIvar(context, iconViewField, sourceHost);
        if (object_getIvar(context, settingsField) != settings ||
            object_getIvar(context, iconViewField) != sourceHost) return nil;
    } @catch (__unused NSException *exception) { return nil; }
    return context;
}

// Use LaunchServices only when a valid SpringBoard launch context cannot be
// constructed. Never issue an apparently-successful native call with nil.
static void FXLaunchAppFallback(NSString *bundleID) {
    if (!bundleID.length) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        id workspace = FXObject((id)workspaceClass, @"defaultWorkspace");
        SEL launch = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (![workspace respondsToSelector:launch]) return;
        @try {
            BOOL (*invoke)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
            (void)invoke(workspace, launch, bundleID);
        } @catch (__unused NSException *exception) { }
    });
}

void FXLaunchApp(id leafIcon, UIView *sourceHost) {
    NSString *bundleID = [FXBundleID(leafIcon) copy];
    if (!bundleID.length) return;
    NSString *const location = @"SBIconLocationFolder";
    SEL nativeLaunch = NSSelectorFromString(@"launchFromLocation:context:");
    if ([leafIcon respondsToSelector:nativeLaunch]) {
        NSMethodSignature *sig = [leafIcon methodSignatureForSelector:nativeLaunch];
        if (sig && sig.numberOfArguments == 4 &&
            sig.methodReturnType[0] == 'v' &&
            [sig getArgumentTypeAtIndex:2][0] == '@' &&
            [sig getArgumentTypeAtIndex:3][0] == '@') {
            id context = FXMakeNativeLaunchContext(sourceHost);
            if (context) {
                @try {
                    void (*invoke)(id, SEL, id, id) =
                        (void (*)(id, SEL, id, id))objc_msgSend;
                    invoke(leafIcon, nativeLaunch, location, context);
                    return;
                } @catch (__unused NSException *exception) { }
            }
        }
    }
    // No more nil-context calls that silently produce an empty activation.
    FXLaunchAppFallback(bundleID);
}

void FXRememberEditingForView(UIView *host, BOOL editing) {
    if (!host) return;
    objc_setAssociatedObject(host, &kFXEditingObserved, @(editing), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL FXIsEditing(UIView *iconView) {
    // Some iOS 17 SBIconView variants report isEditing=NO briefly while their
    // setEditing:animated: transition is running. Honor the observed setter.
    NSNumber *observed = iconView ? objc_getAssociatedObject(iconView, &kFXEditingObserved) : nil;
    if (observed.boolValue) return YES;
    if (FXBoolean(iconView, @"isEditing")) return YES;
    Class cls = NSClassFromString(@"SBIconController");
    id controller = FXObject((id)cls, @"sharedInstance");
    if (FXBoolean(controller, @"isEditing")) return YES;
    return FXBoolean(FXObject(controller, @"iconManager"), @"isEditing");
}
