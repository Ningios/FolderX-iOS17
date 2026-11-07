#import "FXInterface.h"
#import "FXDiag.h"
#import <math.h>
#import <string.h>

static char kFXOverlayKey;
static char kFXHandleKey;
static char kFXNativeTouchedKey;
static char kFXPageOriginalAlphaKey;
static char kFXNativeImageAssertionKey;
static char kFXNativeAlphaMutationKey;
static char kFXLastHandledTapTimeKey;
static char kFXLastHandledFolderKey;
static char kFXLastHandledAppKey;
static char kFXNativeOpenPendingKey;
static char kFXResizeTouchPendingUntilKey;
static char kFXDragVisualLockKey;
static char kFXDragImageFrameKey;
static char kFXDragImageParentKey;
static char kFXDragLayoutLeaseKey;
// Track existing native icon hosts without creating an extra presentation view.
static NSHashTable<UIView *> *FXKnownFolderHosts = nil;
static BOOL FXNativeFolderIsPresented = NO;

// A single successful icon tap can travel through multiple SpringBoard actions.
// Keep a short, per-SBIconView guard instead of blocking the entire folder.
static BOOL FXRecentlyHandled(UIView *host) {
    NSNumber *time = objc_getAssociatedObject(host, &kFXLastHandledTapTimeKey);
    NSString *uid = objc_getAssociatedObject(host, &kFXLastHandledFolderKey);
    return time && uid && [uid isEqualToString:FXIdentifier(FXObject(host, @"icon"))] &&
           (CACurrentMediaTime() - time.doubleValue) < 0.48;
}
// Native SBIconView may call _handleTap and performTap for one gesture.
// Suppress those duplicate actions without swallowing a subsequent tap on
// a DIFFERENT inner App during the short native callback window.
static BOOL FXRecentlyHandledApp(UIView *host, id app) {
    if (!FXRecentlyHandled(host) || !app) return NO;
    NSString *last = objc_getAssociatedObject(host, &kFXLastHandledAppKey);
    NSString *current = FXIdentifier(app) ?: FXBundleID(app);
    return current.length && [current isEqualToString:last];
}
static void FXMarkHandled(UIView *host, id app) {
    objc_setAssociatedObject(host, &kFXLastHandledTapTimeKey,
                             @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(host, &kFXLastHandledFolderKey,
                             FXIdentifier(FXObject(host, @"icon")), OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(host, &kFXLastHandledAppKey,
                             FXIdentifier(app) ?: FXBundleID(app), OBJC_ASSOCIATION_COPY_NONATOMIC);
}


@class FXMiniGrid;
@interface FXAppCell : UIImageView
@property (nonatomic, weak) FXMiniGrid *grid;
@end

@interface FXMiniGrid : UIView
@property (nonatomic, weak) UIView *host;
@property (nonatomic) BOOL editingAppearance;
@property (nonatomic, copy) NSArray *apps;
@property (nonatomic) NSUInteger gridColumns;
@property (nonatomic, copy) NSArray<NSString *> *displayIDs;
@property (nonatomic, strong) NSMutableArray<FXAppCell *> *cells;
- (void)updateWithApps:(NSArray *)apps;
- (id)appAtPoint:(CGPoint)point;
- (void)bounceAtPoint:(CGPoint)point;
- (void)setEditingAppearance:(BOOL)editing;
- (void)setDropHovered:(BOOL)hovered;
- (void)launchAtPoint:(CGPoint)point;
- (void)flashCommittedResize;
@end

@implementation FXAppCell
- (BOOL)accessibilityActivate {
    if (!self.grid || self.grid.hidden) return NO;
    [self.grid launchAtPoint:self.center]; // center is in grid coordinates
    return YES;
}
@end

@implementation FXMiniGrid
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    // Display only.  SpringBoard's own SBIconView receives taps, long presses,
    // edit/wiggle, and drag gestures. No competing custom tap recognizer.
    self.userInteractionEnabled = NO;
    self.clipsToBounds = NO;
    self.layer.cornerRadius = 23;
    // No FolderX-specific hover ring or colored border.
    self.layer.borderWidth = 0;
    _cells = [NSMutableArray arrayWithCapacity:12];
    _apps = @[];
    _gridColumns = 3; // 3x3 square, 6x2 for a genuine 4x2-wide folder
    _displayIDs = @[];
    return self;
}

- (void)updateWithApps:(NSArray *)apps {
    if (!apps) apps = @[];
    NSUInteger maxIcons = self.gridColumns == 6 ? 12 : 9;
    if (apps.count > maxIcons) apps = [apps subarrayWithRange:NSMakeRange(0, maxIcons)];
    self.apps = [apps copy]; // Refresh live SBIcon identities even when images are unchanged.
    NSMutableArray<NSString *> *identities = [NSMutableArray array];
    for (id app in apps) {
        [identities addObject:FXIdentifier(app) ?: FXBundleID(app) ?: @""];
    }
    if ([self.displayIDs isEqualToArray:identities] && self.cells.count == apps.count) return;
    self.displayIDs = identities;
    for (FXAppCell *cell in self.cells) [cell removeFromSuperview];
    [self.cells removeAllObjects];
    for (id app in apps) {
        UIImage *image = FXAppImage(FXBundleID(app));
        FXAppCell *cell = [[FXAppCell alloc] initWithImage:image];
        cell.grid = self;
        cell.isAccessibilityElement = YES;
        cell.accessibilityTraits = UIAccessibilityTraitButton;
        id name = FXObject(app, @"displayName");
        cell.accessibilityLabel = [name isKindOfClass:NSString.class] ? name : FXBundleID(app);
        cell.contentMode = UIViewContentModeScaleAspectFill;
        cell.layer.cornerRadius = 8;
        cell.layer.masksToBounds = YES;
        cell.userInteractionEnabled = NO;
        if (!image) {
            cell.backgroundColor = [UIColor colorWithWhite:0.77 alpha:0.9];
            // Avoid inserting extra tappable views when private icon loading fails.
            cell.image = [UIImage systemImageNamed:@"app.fill"];
            cell.tintColor = UIColor.whiteColor;
            cell.contentMode = UIViewContentModeScaleAspectFit;
        }
        [self addSubview:cell];
        [self.cells addObject:cell];
    }
    [self setNeedsLayout];
    if (self.editingAppearance) { self.editingAppearance = NO; [self setEditingAppearance:YES]; }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.cells.count == 0) return;
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    if (MIN(width, height) < 10) return;
    // 4x2 refers to HOME SCREEN occupancy.  The content is 2 rows x 6
    // columns (12 icons), NOT the old 2 rows x 4 columns (8 icons).
    BOOL wide = self.gridColumns == 6;
    NSUInteger columns = wide ? 6 : 3;
    NSUInteger rows = wide ? 2 : 3;
    CGFloat marginX = round(width * (wide ? 0.045 : 0.095));
    CGFloat marginY = round(height * (wide ? 0.115 : 0.095));
    CGFloat gapX = round(width * (wide ? 0.033 : 0.076));
    CGFloat gapY = round(height * (wide ? 0.095 : 0.076));
    CGFloat cellSize = floor(MAX(0, MIN((width - 2 * marginX - (columns-1) * gapX) / columns,
                                          (height - 2 * marginY - (rows-1) * gapY) / rows)));
    if (cellSize < 5) return;
    CGFloat startX = (width - (columns * cellSize + (columns-1) * gapX)) * 0.5;
    CGFloat startY = (height - (rows * cellSize + (rows-1) * gapY)) * 0.5;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < self.cells.count; i++) {
        UIImageView *cell = self.cells[i];
        CGRect rect = CGRectMake(round(startX + (i % columns) * (cellSize + gapX)),
                                 round(startY + (i / columns) * (cellSize + gapY)),
                                 round(cellSize), round(cellSize));
        if (!CGRectEqualToRect(cell.frame, rect)) cell.frame = rect;
        cell.layer.cornerRadius = MIN(rect.size.width, rect.size.height) * 0.22;
    }
    [CATransaction commit];
}

- (NSInteger)indexAtPoint:(CGPoint)p {
    for (NSUInteger index = 0; index < self.cells.count; index++) {
        CGRect area = CGRectInset(self.cells[index].frame, -1.0, -1.0);
        if (CGRectContainsPoint(area, p)) return (NSInteger)index;
    }
    return NSNotFound;
}

- (id)appAtPoint:(CGPoint)p {
    NSInteger index = [self indexAtPoint:p];
    if (index == NSNotFound || index < 0 || (NSUInteger)index >= self.apps.count) return nil;
    return self.apps[(NSUInteger)index];
}

// These hit rectangles are queried by the native SBIconView tap callback.
// The grid itself never captures touches, which also preserves long-press
// and drag recognizers installed by SpringBoard on the icon host.
- (void)setEditingAppearance:(BOOL)editing {
    if (_editingAppearance == editing) return;
    _editingAppearance = editing;
    for (FXAppCell *cell in self.cells) {
        [cell.layer removeAnimationForKey:@"fx.edit"];
        if (editing && !UIAccessibilityIsReduceMotionEnabled()) {
            CAKeyframeAnimation *wiggle = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
            wiggle.values = @[@(-0.016), @(0.016), @(-0.016)];
            wiggle.duration = 0.23;
            wiggle.repeatCount = HUGE_VALF;
            wiggle.additive = YES;
            [cell.layer addAnimation:wiggle forKey:@"fx.edit"];
        }
    }
}

- (void)setDropHovered:(BOOL)hovered {
    // 1.5.4: no supplemental blue halo, border, or opacity pulse.
    // The drop proposal and actual insertion still go through SpringBoard.
    (void)hovered;
    [self.layer removeAnimationForKey:@"fx.drop.pulse"];
    if (self.layer.borderWidth != 0.0) self.layer.borderWidth = 0.0;
}

- (void)launchAtPoint:(CGPoint)point {
    UIView *host = self.host;
    if (!host || self.hidden || !self.superview || FXIsEditing(host) ||
        !FXIsFolder(FXObject(host, @"icon"))) return;
    id app = [self appAtPoint:point];
    if (!app || FXRecentlyHandledApp(host, app)) return;
    FXMarkHandled(host, app); // suppress both _handleTap and performTap, if dispatched
    [self bounceAtPoint:point];
    // 0.3.3 used the native SBIcon launch entry immediately after the icon
    // press feedback. Delaying this until another layout pass lets the folder
    // open callback win the tap race on some iOS 17 builds. The host tap hook
    // has already marked this gesture handled, so launch exactly once.
    FXLaunchApp(app);
}

- (void)flashCommittedResize {
    // Size changes must not animate nine app thumbnails independently.
    // The system's icon list is responsible for its own layout transition.
}

- (void)bounceAtPoint:(CGPoint)p {
    NSInteger index = [self indexAtPoint:p];
    if (index == NSNotFound || index < 0 || (NSUInteger)index >= self.cells.count) return;
    if (UIAccessibilityIsReduceMotionEnabled()) return;
    UIImageView *cell = self.cells[(NSUInteger)index];
    [cell.layer removeAnimationForKey:@"fx.tap"];
    CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    animation.values = @[@1.0, @0.88, @1.04, @1.0];
    animation.keyTimes = @[@0.0, @0.3, @0.75, @1.0];
    animation.duration = 0.17;
    [cell.layer addAnimation:animation forKey:@"fx.tap"];
}
@end

@interface FXCornerHandle : UIView
@property (nonatomic, weak) UIView *host;
@property (nonatomic) FXFolderSize startSize;
@property (nonatomic) BOOL resizing;
@property (nonatomic, strong) UIImpactFeedbackGenerator *feedback;
@property (nonatomic, strong) UINotificationFeedbackGenerator *errorFeedback;
@property (nonatomic) BOOL passedThreshold;
@end

@implementation FXCornerHandle
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    // The gesture remains fully invisible: larger hit target, no animation.
    self.backgroundColor = UIColor.clearColor;
    self.layer.cornerRadius = 0;
    self.layer.borderWidth = 0;
    self.layer.masksToBounds = NO; // transparent corner interaction surface
    self.userInteractionEnabled = YES;
    self.feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    self.errorFeedback = [UINotificationFeedbackGenerator new];
    self.accessibilityLabel = @"调整文件夹大小";
    self.accessibilityHint = @"向右下滑动切换到2×2，2×2向右滑动切换横向4×2，向左或向上滑动缩小；也可通过长按菜单切换";
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.isAccessibilityElement = YES;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    pan.maximumNumberOfTouches = 1;
    pan.cancelsTouchesInView = YES;
    [self addGestureRecognizer:pan];
    // Only the directional pan may change size. An invisible single-tap
    // toggle stole ordinary edit-mode touches and was too easy to trigger.
    // The context menu now provides the explicit accessible size action.
    return self;
}

// No visible corner handle; the outer five points remain touch tolerant.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, -5.0, -5.0), point);
}

- (void)commitSize:(FXFolderSize)size {
    UIView *host = self.host;
    if (!host || !FXIsEditing(host)) return;
    if (FXCommitSizeForHost(host, size)) {
        // When a pan already crossed the threshold, it gave one tactile tick;
        // avoid a second one on release. VoiceOver can still activate directly.
        if (!self.passedThreshold) [self.feedback impactOccurred];
    } else {
        [self.errorFeedback notificationOccurred:UINotificationFeedbackTypeError];

    }
}

- (BOOL)accessibilityActivate {
    NSUInteger current = FXSize(FXObject(self.host, @"icon"));
    [self commitSize:(current == FXFolderSizeLarge ? FXFolderSizeSmall : FXFolderSizeLarge)];
    return YES;
}

- (void)onPan:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.resizing = FXIsEditing(self.host) && self.host.window && !FXNativeDragIsActive();
        self.startSize = (FXFolderSize)FXSize(FXObject(self.host, @"icon"));
        self.passedThreshold = NO;
        FXDiagLog(@"pan.begin resizing=%d editing=%d window=%d start=%lu icon=%@",
                  self.resizing, (int)FXIsEditing(self.host), (int)(self.host.window != nil),
                  (unsigned long)self.startSize,
                  NSStringFromClass([FXObject(self.host, @"icon") class]));
        if (self.resizing) [self.feedback prepare];
        return;
    }
    if (!self.resizing) return;
    if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint delta = [pan translationInView:self.host.window ?: self.host];
        // The same gesture also supports a horizontal second stage (2x2->4x2).
        CGFloat travel = MAX(fabs(delta.x), fabs(delta.y));
        if (travel >= 16.0 && !self.passedThreshold) {
            self.passedThreshold = YES;
            [self.feedback impactOccurred]; // one subtle confirmation, no visual effects
        } else if (travel < 8.0) {
            self.passedThreshold = NO;
        }
        return;
    }
    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {
        BOOL ended = (pan.state == UIGestureRecognizerStateEnded);
        CGPoint delta = [pan translationInView:self.host.window ?: self.host];
        self.resizing = NO;
        objc_setAssociatedObject(self.host, &kFXResizeTouchPendingUntilKey,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Three real model sizes, no fake frame scaling or text overlay.
        // 1x1: move outward -> 2x2. 2x2: mostly right -> horizontal 4x2,
        //       inward/up-left -> 1x1. 4x2: inward/left -> 2x2.
        // The wide option remains guarded by a VERIFIED native class mapping;
        // on unsupported builds a horizontal gesture does not mutate the grid.
        CGFloat dx = delta.x, dy = delta.y;
        if (!ended || MAX(fabs(dx), fabs(dy)) < 16.0) {
            self.passedThreshold = NO;
            FXDiagLog(@"pan.ignore ended=%d dx=%.0f dy=%.0f", ended, dx, dy);
            return;
        }
        FXFolderSize target = self.startSize;
        if (self.startSize == FXFolderSizeSmall) {
            if (dx > 16.0 || dy > 16.0) target = FXFolderSizeLarge;
        } else if (self.startSize == FXFolderSizeLarge) {
            if (dx > 24.0 && dx > fabs(dy) * 1.2) {
                if (FXCanUseWideGrid()) target = FXFolderSizeWide;
                else [self.errorFeedback notificationOccurred:UINotificationFeedbackTypeWarning];
            } else if (dx < -16.0 || dy < -16.0) {
                target = FXFolderSizeSmall;
            }
        } else if (self.startSize == FXFolderSizeWide) {
            if (dx < -16.0 || dy < -16.0) target = FXFolderSizeLarge;
        }
        FXDiagLog(@"pan.end start=%lu target=%lu dx=%.0f dy=%.0f wide=%d",
                  (unsigned long)self.startSize, (unsigned long)target, dx, dy,
                  (int)FXCanUseWideGrid());
        if (self.startSize != target) [self commitSize:target];
    }
}

@end

// Pending identifies exactly which host owns a native opening or closing
// viewWillAppear. Closing is controlled by the controller lifecycle, never
// by a duration guess: that guess caused the tiny 1x1 grid on return.
static BOOL FXIsYieldingToNativeOpen(UIView *host) {
    // SBIconView objects are recycled while pages rearrange. Tie the yield to
    // the exact folder identity, never a boolean that can hide the next icon.
    NSString *pendingUID = objc_getAssociatedObject(host, &kFXNativeOpenPendingKey);
    return [pendingUID isKindOfClass:NSString.class] &&
           [pendingUID isEqualToString:FXIdentifier(FXObject(host, @"icon"))];
}

static UIView *FXHostForNativeImage(UIView *imageView) {
    UIView *p = imageView;
    Class cls = NSClassFromString(@"SBIconView");
    for (NSUInteger i = 0; i < 9 && p; ++i, p = p.superview)
        if (cls && [p isKindOfClass:cls]) return p;
    return nil;
}

static id FXPageGridContainer(UIView *root, NSUInteger depth) {
    if (!root || depth > 6) return nil;
    id value = FXObject(root, @"pageGridContainer");
    if ([value isKindOfClass:UIView.class]) return value;
    for (UIView *child in root.subviews) {
        id nested = FXPageGridContainer(child, depth + 1);
        if (nested) return nested;
    }
    return nil;
}

// The system regenerates pageGridContainer and the composite icon image
// during folder close and grid-size relayout.  A one-time hide flag is NOT
// sufficient: it permits exactly the native mini-grid + our large grid ghost
// visible in the user's screenshot.  Every native image layout reasserts the
// current ownership.  No snapshots, no added background view.
static BOOL FXReadNativeGridAlpha(id owner, CGFloat *alpha) {
    SEL sel = NSSelectorFromString(@"iconGridImageAlpha");
    if (!owner || ![owner respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [owner methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments != 2) return NO;
    if (sig.methodReturnType[0] == 'd') {
        double (*get)(id, SEL) = (double (*)(id, SEL))objc_msgSend;
        @try { *alpha = (CGFloat)get(owner, sel); return isfinite(*alpha); }
        @catch (__unused NSException *ex) { return NO; }
    }
    if (sig.methodReturnType[0] == 'f') {
        float (*get)(id, SEL) = (float (*)(id, SEL))objc_msgSend;
        @try { *alpha = (CGFloat)get(owner, sel); return isfinite(*alpha); }
        @catch (__unused NSException *ex) { return NO; }
    }
    return NO;
}

// SpringBoard rebuilds the native mini grid inside _SBIconGridWrapperView and
// rewrites its alpha during open/close transitions. Alpha therefore leaves a
// window where the native grid and our FXMiniGrid are both drawn. Hidden is not
// animated by that path, so use it as the authoritative switch.
static NSUInteger FXSetNativeGridWrappersHidden(UIView *root, BOOL hide, NSUInteger depth) {
    if (!root || depth > 3) return 0;
    NSUInteger changed = 0;
    for (UIView *child in root.subviews) {
        if ([NSStringFromClass(child.class) isEqualToString:@"_SBIconGridWrapperView"]) {
            if (child.hidden != hide) {
                child.hidden = hide;
                changed++;
            }
            continue; // do not descend into a wrapper we just controlled
        }
        changed += FXSetNativeGridWrappersHidden(child, hide, depth + 1);
    }
    return changed;
}

static void FXSetNativeThumbnailVisibility(UIView *imageView, BOOL hide) {
    if (!imageView) return;
    BOOL touched = [objc_getAssociatedObject(imageView, &kFXNativeTouchedKey) boolValue];
    if (!hide) {
        // Sticky ownership: while this icon view hosts our own grid, the native
        // mini grid must never be revealed again. Yielding during a transition
        // is exactly what let both grids be drawn at the same time.
        UIView *owner = FXHostForNativeImage(imageView);
        FXMiniGrid *owned = owner ? objc_getAssociatedObject(owner, &kFXOverlayKey) : nil;
        if (owned && owned.superview) {
            FXDiagThrottled([NSString stringWithFormat:@"sticky/%p", imageView], 0.3,
                            @"grid.sticky refuse-yield %@", NSStringFromClass(imageView.class));
            hide = YES;
            touched = YES;
        }
    }
    if (!hide && !touched) return;
    FXDiagChanged([NSString stringWithFormat:@"thumb/%@", NSStringFromClass(imageView.class)],
                  [NSString stringWithFormat:@"enter hide=%d touched=%d lock="
                   @"%d alphaSetter=%d", hide, touched,
                   (int)[imageView respondsToSelector:NSSelectorFromString(@"disableImageUpdatesForReason:")],
                   (int)[imageView respondsToSelector:NSSelectorFromString(@"setIconGridImageAlpha:")]]);
    if (FXObserveOnly()) return; // never touch native rendering in observe mode
    // Set state before private setters because they may re-enter layout.
    objc_setAssociatedObject(imageView, &kFXNativeTouchedKey,
                             hide ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    id assertion = objc_getAssociatedObject(imageView, &kFXNativeImageAssertionKey);
    if (hide && !assertion) {
        SEL lock = NSSelectorFromString(@"disableImageUpdatesForReason:");
        if ([imageView respondsToSelector:lock]) {
            id (*acquire)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            assertion = acquire(imageView, lock, @"FolderX-large-grid");
            if (assertion) objc_setAssociatedObject(imageView, &kFXNativeImageAssertionKey,
                                                   assertion, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if (!hide && assertion) {
        SEL unlock = NSSelectorFromString(@"invalidateImageUpdatesAssertion:");
        if ([imageView respondsToSelector:unlock]) {
            void (*release)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
            release(imageView, unlock, assertion);
        }
        objc_setAssociatedObject(imageView, &kFXNativeImageAssertionKey,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Suppress a composite thumbnail only when the native implementation
    // exposes the exact setter.  Do not guess a layer's role or hide the
    // folder's glass background.  If the native getter shows that SpringBoard
    // reset alpha to 1 during a redraw, request suppression again.
    SEL setGridAlpha = NSSelectorFromString(@"setIconGridImageAlpha:");
    UIView *alphaOwner = [imageView respondsToSelector:setGridAlpha] ?
                          imageView : FXHostForNativeImage(imageView);
    if (!alphaOwner || ![alphaOwner respondsToSelector:setGridAlpha])
        FXDiagChanged([NSString stringWithFormat:@"alphaMissing/%@", NSStringFromClass(imageView.class)],
                      [NSString stringWithFormat:@"image=%@ owner=%@", NSStringFromClass(imageView.class),
                       alphaOwner ? NSStringFromClass(alphaOwner.class) : @"nil"]);
    if (alphaOwner && [alphaOwner respondsToSelector:setGridAlpha]) {
        CGFloat observed = 0;
        BOOL hasGetter = FXReadNativeGridAlpha(alphaOwner, &observed);
        BOOL needsUpdate = (hide != touched) ||
                           (hasGetter && fabs(observed - (hide ? 0.0 : 1.0)) > 0.001);
        NSMethodSignature *signature = [alphaOwner methodSignatureForSelector:setGridAlpha];
        BOOL compatible = signature && signature.numberOfArguments == 3 &&
                          strcmp([signature getArgumentTypeAtIndex:2], @encode(CGFloat)) == 0;
        FXDiagChanged([NSString stringWithFormat:@"alpha/%@", NSStringFromClass(alphaOwner.class)],
                      [NSString stringWithFormat:@"needs=%d compat=%d getter=%d obs=%.2f "
                       @"want=%.1f reentrant=%d arg=%s", needsUpdate, compatible, hasGetter,
                       observed, hide ? 0.0 : 1.0,
                       (int)[objc_getAssociatedObject(alphaOwner, &kFXNativeAlphaMutationKey) boolValue],
                       signature && signature.numberOfArguments > 2 ?
                           [signature getArgumentTypeAtIndex:2] : "?"]);
        if (needsUpdate && compatible &&
            ![objc_getAssociatedObject(alphaOwner, &kFXNativeAlphaMutationKey) boolValue]) {
            // The native setter may synchronously trigger layout; a recursive
            // refresh must not start another setter call before it returns.
            objc_setAssociatedObject(alphaOwner, &kFXNativeAlphaMutationKey,
                                     @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @try {
                void (*set)(id, SEL, CGFloat) = (void (*)(id, SEL, CGFloat))objc_msgSend;
                set(alphaOwner, setGridAlpha, hide ? 0.0 : 1.0);
            } @catch (__unused NSException *ex) {
                // An unsupported private method must not crash SpringBoard.
            } @finally {
                objc_setAssociatedObject(alphaOwner, &kFXNativeAlphaMutationKey,
                                         nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }

    NSUInteger hiddenWrappers = FXSetNativeGridWrappersHidden(imageView, hide, 0);
    FXDiagChanged([NSString stringWithFormat:@"wrappers/%@", NSStringFromClass(imageView.class)],
                  [NSString stringWithFormat:@"hide=%d changed=%lu",
                   hide, (unsigned long)hiddenWrappers]);

    // The 1.5.11 view-tree dump identified the leftover native mini grid as
    // _SBIconGridWrapperView inside SBFolderIconImageView. Alpha alone leaves a
    // window when SpringBoard repopulates it; keep the page-grid flag in the
    // same state so a repaint cannot reveal it.
    SEL pageHiddenSel = NSSelectorFromString(@"setPageGridHidden:");
    if ([imageView respondsToSelector:pageHiddenSel]) {
        NSMethodSignature *pageSig = [imageView methodSignatureForSelector:pageHiddenSel];
        if (pageSig && pageSig.numberOfArguments == 3 &&
            strcmp([pageSig getArgumentTypeAtIndex:2], @encode(BOOL)) == 0) {
            FXDiagChanged([NSString stringWithFormat:@"pageHidden/%@",
                           NSStringFromClass(imageView.class)],
                          [NSString stringWithFormat:@"hide=%d", hide]);
            @try {
                void (*setPage)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
                setPage(imageView, pageHiddenSel, hide);
            } @catch (__unused NSException *ex) { }
        }
    }

    id value = FXPageGridContainer(imageView, 0);
    UIView *page = [value isKindOfClass:UIView.class] ? (UIView *)value : nil;
    FXDiagChanged([NSString stringWithFormat:@"page/%@", NSStringFromClass(imageView.class)],
                  [NSString stringWithFormat:@"found=%d hide=%d opacity=%.2f",
                   page != nil, hide, page ? page.layer.opacity : -1.0]);
    if (page) {
        // Record the original opacity on the ACTUAL native page.  SpringBoard
        // can replace the page while keeping the SBFolderIconImageView alive.
        if (hide && !objc_getAssociatedObject(page, &kFXPageOriginalAlphaKey)) {
            objc_setAssociatedObject(page, &kFXPageOriginalAlphaKey,
                                     @(page.layer.opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CGFloat alpha = 0;
        if (!hide) {
            NSNumber *saved = objc_getAssociatedObject(page, &kFXPageOriginalAlphaKey);
            alpha = saved ? saved.floatValue : 1.0;
        }
        if (fabs(page.layer.opacity - alpha) > 0.001) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            page.layer.opacity = alpha;
            [CATransaction commit];
        }
        if (!hide) objc_setAssociatedObject(page, &kFXPageOriginalAlphaKey,
                                           nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// The SBIconView iconImageView selector can return a wrapper on some 17.x
// builds. The grid suppression selectors live on SBFolderIconImageView, not
// necessarily on the wrapper; find the actual native grid view before probing.
static UIView *FXGridImageDescendant(UIView *root, NSUInteger depth) {
    if (!root || depth > 7) return nil;
    // UIKit's context-menu preview snapshots the native folder image view,
    // not unrelated siblings under SBIconView. Prefer the concrete native view.
    if ([NSStringFromClass(root.class) isEqualToString:@"SBFolderIconImageView"]) return root;
    for (UIView *child in root.subviews) {
        UIView *match = FXGridImageDescendant(child, depth + 1);
        if (match) return match;
    }
    return nil;
}
static UIView *FXNativeImageView(UIView *host) {
    id value = FXObject(host, @"iconImageView");
    if (![value isKindOfClass:UIView.class]) {
        @try { value = [host valueForKey:@"iconImageView"]; }
        @catch (__unused NSException *exception) { value = nil; }
    }
    UIView *root = [value isKindOfClass:UIView.class] ? (UIView *)value : nil;
    if (!root) return nil;
    return FXGridImageDescendant(root, 0) ?: root;
}

// The live grid must stay inside SBFolderIconImageView, including while
// SpringBoard captures the OPEN/CLOSE transition image. Moving it to SBIconView
// before the capture leaves a native 1x1 grid in the zoom snapshot while our
// enlarged grid remains visible separately on the desktop (double images).
// Keep one rendering source instead of moving the view between parent trees.

// SBIconListView (observed on iOS 17.1.1) exposes a native, per-icon
// layout pause assertion. Unlike forcing SBIconView.frame in a setter, this
// asks SpringBoard to leave a verified expanded folder view where its own
// layout placed it before the drag placeholder update. The grid model and
// neighboring icon views are never modified by FolderX.
@interface FXDragLayoutLease : NSObject
@property (nonatomic, weak) UIView *listView;
@property (nonatomic, strong) id assertion;
@end
@implementation FXDragLayoutLease
@end

static UIView *FXRootListForHost(UIView *host) {
    Class cls = NSClassFromString(@"SBIconListView");
    for (UIView *v = host.superview; v; v = v.superview) {
        if (cls && [v isKindOfClass:cls]) return v;
    }
    return nil;
}

static BOOL FXObjectMethodABI(id target, SEL selector, BOOL returnsObject,
                              NSUInteger arguments) {
    if (!target || ![target respondsToSelector:selector]) return NO;
    NSMethodSignature *sig = [target methodSignatureForSelector:selector];
    if (!sig || sig.numberOfArguments != arguments) return NO;
    const char *ret = sig.methodReturnType;
    if (!ret || ret[0] != (returnsObject ? '@' : 'v')) return NO;
    for (NSUInteger i = 2; i < arguments; ++i) {
        const char *arg = [sig getArgumentTypeAtIndex:i];
        if (!arg || arg[0] != '@') return NO;
    }
    return YES;
}

// Only icons verified by SpringBoard's real 2x2 / 4x2 list-model range may
// acquire a native pause. Saved preferences / oversized visual bounds alone
// are not permission to block layout.
static void FXAcquireDragLayoutPause(UIView *host, id icon) {
    if (FXObserveOnly()) return;
    if (objc_getAssociatedObject(host, &kFXDragLayoutLeaseKey) ||
        !host.window || !FXIsGenuineLarge(icon)) return;
    UIView *list = FXRootListForHost(host);
    if (!list || !list.window || list.window != host.window) return;
    SEL pause = NSSelectorFromString(@"pauseLayoutForIconView:forReason:");
    if (!FXObjectMethodABI(list, pause, YES, 4)) return;
    // The reason is an Objective-C string (the second private API argument is
    // object-typed); the returned assertion is retained until drag end.
    id assertion = nil;
    @try {
        id (*call)(id, SEL, id, id) = (id (*)(id, SEL, id, id))objc_msgSend;
        assertion = call(list, pause, host, @"FolderX-verified-large-folder-drag");
    } @catch (__unused NSException *exception) { return; }
    if (!assertion) return;
    FXDragLayoutLease *lease = [FXDragLayoutLease new];
    lease.listView = list; // weak: do not retain list <-> icon-view hierarchy
    lease.assertion = assertion;
    objc_setAssociatedObject(host, &kFXDragLayoutLeaseKey, lease,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void FXReleaseDragLayoutPauseForHost(UIView *host) {
    if (!host) return;
    FXDragLayoutLease *lease = objc_getAssociatedObject(host, &kFXDragLayoutLeaseKey);
    if (!lease) return;
    // Clear first: the private unpause can synchronously trigger a fresh pass.
    objc_setAssociatedObject(host, &kFXDragLayoutLeaseKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *list = lease.listView;
    SEL unpause = NSSelectorFromString(@"removePauseLayoutAssertion:");
    if (list && lease.assertion && FXObjectMethodABI(list, unpause, NO, 3)) {
        @try {
            void (*call)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
            call(list, unpause, lease.assertion);
        } @catch (__unused NSException *exception) { }
    }
}

// SpringBoard may relayout its native folder image to a 1x1 thumbnail when
// drag placeholders appear, even though the list-model grid still occupies
// 2x2/4x2. Preserve ONLY the current visual image geometry. Never change the
// SBIconView's frame, its grid class, or the layout model during a drag.
// Called after source capture, when the image frame is still known-good.
void FXSetDragVisualLockForHost(UIView *host, BOOL locked) {
    if (!host || ![host isKindOfClass:UIView.class]) return;
    if (FXObserveOnly()) return;
    id icon = FXObject(host, @"icon");
    if (locked) {
        NSNumber *saved = FXSavedSize(icon);
        BOOL intendedLarge = saved && (saved.unsignedIntegerValue == FXFolderSizeLarge ||
                                       saved.unsignedIntegerValue == FXFolderSizeWide);
        // This is a visual-only guard. Unlike a drop target, it may safely
        // accept a saved large folder whose *visible* 2x2 frame is genuine even
        // when the private gridRange selector is not readable on this build.
        BOOL genuineLarge = FXIsGenuineLarge(icon);
        BOOL visualLarge = genuineLarge ||
            (intendedLarge && FXShouldRenderLarge(icon, host));
        if (!visualLarge || host.bounds.size.width < 100.0) return;
        // The native list-view pause governs the *outer SBIconView*.  It must
        // NOT depend on discovering an inner SBFolderIconImageView: on wide
        // (4x2) icons that subview can be absent/replaced during drag lift.
        // FXAcquireDragLayoutPause independently rejects non-genuine folders.
        if (genuineLarge) FXAcquireDragLayoutPause(host, icon);
        // The image lock below is separate, best-effort visual protection.
        UIView *image = FXNativeImageView(host);
        if (!image || !image.superview || !image.window) return;
        if (objc_getAssociatedObject(host, &kFXDragVisualLockKey)) return;
        objc_setAssociatedObject(host, &kFXDragVisualLockKey, FXIdentifier(icon),
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(host, &kFXDragImageFrameKey,
                                 [NSValue valueWithCGRect:image.frame],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Compare object identity without retaining the superview: retaining an
        // ancestor from a host association would make a view-hierarchy cycle.
        objc_setAssociatedObject(host, &kFXDragImageParentKey,
                                 [NSValue valueWithNonretainedObject:image.superview],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        // Also release a partial/old lease when the visual host was recycled.
        FXReleaseDragLayoutPauseForHost(host);
        if (!objc_getAssociatedObject(host, &kFXDragVisualLockKey)) return;
        objc_setAssociatedObject(host, &kFXDragVisualLockKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(host, &kFXDragImageFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(host, &kFXDragImageParentKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Give SpringBoard its visual layout back without forcing a nested
        // layout on its own drag/drop stack.
        [FXNativeImageView(host).superview setNeedsLayout];
        [host setNeedsLayout];
    }
    FXRefreshIconView(host);
}

static BOOL FXDragVisualLocked(UIView *host) {
    NSString *uid = objc_getAssociatedObject(host, &kFXDragVisualLockKey);
    if (![uid isKindOfClass:NSString.class] || !host.window) return NO;
    id icon = FXObject(host, @"icon");
    // This identity was validated as genuinely 2x2/4x2 before the lift.
    // Do not re-read a transient gridSizeClass here: it is exactly the value
    // that may briefly report 1x1 while SpringBoard rearranges placeholders.
    return [uid isEqualToString:FXIdentifier(icon)] && FXIsFolder(icon);
}

static void FXStabilizeNativeImageDuringDrag(UIView *host, UIView *image) {
    if (FXObserveOnly()) return;
    if (!FXDragVisualLocked(host) || !image) return;
    NSValue *parent = objc_getAssociatedObject(host, &kFXDragImageParentKey);
    NSValue *original = objc_getAssociatedObject(host, &kFXDragImageFrameKey);
    if (!original || !parent || image.superview != [parent nonretainedObjectValue]) return;
    CGRect frame = original.CGRectValue;
    // Only prevent a transient *shrink*. Do not fight legitimate expansion,
    // rotation, or model resize while the session is active.
    if (frame.size.width < 95 || frame.size.height < 95 ||
        image.bounds.size.width >= frame.size.width - 3.0) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    image.frame = frame;
    [CATransaction commit];
}

static void FXRemoveOverlay(UIView *host) {
    FXMiniGrid *overlay = objc_getAssociatedObject(host, &kFXOverlayKey);
    if (overlay) {
        [overlay setEditingAppearance:NO];
        [overlay setDropHovered:NO];
        [overlay removeFromSuperview];
        objc_setAssociatedObject(host, &kFXOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// The outer 4x2 folder is a 2-row / 6-column preview (12 apps). Prefer
// the live grid class, then the real list-model range; only use the saved size
// if the host actually has wide geometry. Do not mistake an ordinary 2x2
// folder for wide when a previous user preference is stale.
static NSUInteger FXPreviewColumns(id icon, UIView *host) {
    NSUInteger cls = FXSize(icon);
    if (cls == FXFolderSizeWide) return 6;
    BOOL wideFrame = host && host.bounds.size.width >= 220 &&
        host.bounds.size.width > host.bounds.size.height * 1.6;
    // Fast path: ordinary 2x2 folders never need a full root-list scan.
    if (cls == FXFolderSizeLarge && !wideFrame) return 3;
    NSNumber *stored = FXSavedSize(icon);
    if (wideFrame && stored && stored.unsignedIntegerValue == FXFolderSizeWide)
        return 6;
    // Rare inconsistent state: trust the real grid range over a stale class.
    if (wideFrame) {
        FXGridRange range = FXGridOf(FXListModel(icon), icon);
        if (range.columns == 4 && range.rows == 2) return 6;
    }
    return 3;
}

// ---- Plan A: let SpringBoard draw the large folder itself -------------------
// The interior grid never followed the icon's new size class because the resize
// path only changes the model. Re-running the grid setup makes SpringBoard lay
// out its own grid across the whole 170x170 frame, so there is exactly one grid.
#ifdef FX_NATIVE_GRID_ONLY
static void FXActivateNativeGrid(UIView *host, UIView *imageView, NSUInteger sizeClass) {
    if (!imageView) return;
    if (sizeClass != FXFolderSizeLarge && sizeClass != FXFolderSizeWide) return;
    FXSetNativeGridWrappersHidden(imageView, NO, 0);
    SEL alphaSel = NSSelectorFromString(@"setIconGridImageAlpha:");
    if ([imageView respondsToSelector:alphaSel]) {
        void (*setAlpha)(id, SEL, CGFloat) = (void (*)(id, SEL, CGFloat))objc_msgSend;
        @try { setAlpha(imageView, alphaSel, 1.0); } @catch (__unused NSException *ex) { }
    }
    SEL pageSel = NSSelectorFromString(@"setPageGridHidden:");
    if ([imageView respondsToSelector:pageSel]) {
        void (*setPage)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
        @try { setPage(imageView, pageSel, NO); } @catch (__unused NSException *ex) { }
    }
    static NSMutableSet<NSString *> *configured = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ configured = [NSMutableSet set]; });
    NSString *uid = FXIdentifier(FXObject(host, @"icon")) ?: @"?";
    NSString *key = [NSString stringWithFormat:@"%@-%lu", uid, (unsigned long)sizeClass];
    if ([configured containsObject:key]) return;
    [configured addObject:key];
    SEL setup = NSSelectorFromString(@"_setupGridViewsInDefaultConfiguration");
    if ([imageView respondsToSelector:setup]) {
        void (*call)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
        @try { call(imageView, setup); } @catch (__unused NSException *ex) { }
    }
    for (NSString *name in @[@"_showLeftMinigrid", @"_showRightMinigrid"]) {
        SEL sel = NSSelectorFromString(name);
        if (![imageView respondsToSelector:sel]) continue;
        void (*call)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
        @try { call(imageView, sel); } @catch (__unused NSException *ex) { }
    }
    [imageView setNeedsLayout];
    [host setNeedsLayout];
    FXDiagLog(@"nativegrid.setup size=%lu", (unsigned long)sizeClass);
}
#endif

void FXRefreshIconView(UIView *host) {
    if (!host || ![host isKindOfClass:UIView.class]) return;
    id icon = FXObject(host, @"icon");
    FXCornerHandle *handle = objc_getAssociatedObject(host, &kFXHandleKey);
    if (!FXIsFolder(icon)) {
        FXSetNativeThumbnailVisibility(FXNativeImageView(host), NO);
        FXRemoveOverlay(host);
        if (handle) {
            [handle removeFromSuperview];
            objc_setAssociatedObject(host, &kFXHandleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    if (!FXKnownFolderHosts) FXKnownFolderHosts = [NSHashTable weakObjectsHashTable];
    [FXKnownFolderHosts addObject:host];
    UIView *nativeImage = FXNativeImageView(host);
    FXDiagProbeImageView(nativeImage);
    if (nativeImage) FXDiagDumpGridMethods(NSStringFromClass(nativeImage.class));
    CGFloat width = host.bounds.size.width;
    CGFloat height = host.bounds.size.height;
    CGFloat side = floor(MIN(width, height > 14 ? height - 14 : height));
    BOOL hasUsableFrame = (side >= 100);
    NSUInteger sizeClass = FXSize(icon);
    BOOL wantsExpanded = sizeClass == FXFolderSizeLarge ||
                         sizeClass == FXFolderSizeWide;
    // During a native grid resize, SBIconView and its image child may receive
    // their new frames on DIFFERENT passes. Do not show a 1x1 thumbnail inside
    // a still-large host (or an oversized grid inside the outgoing 1x1 frame).
    BOOL nativeMatchesHost = nativeImage &&
        fabs(nativeImage.bounds.size.width - width) <= 5.0 &&
        fabs(nativeImage.bounds.size.height - (height > 14 ? height - 14 : height)) <= 7.0;
    BOOL geometrySettled = nativeMatchesHost &&
        (wantsExpanded ? hasUsableFrame : width <= 88.0);
    // Presentation ownership is PER ICON, not global. Opening one folder must
    // not hide the large previews of its neighbors. The previous global check
    // made every other large folder temporarily fall back to a tiny 1x1 grid.
    // Keep the enlarged preview for the native opening snapshot. Only yield
    // after the folder controller actually enters presentation, not in the
    // preceding tap callback (which used to flash the 1x1 thumbnail).
    // The 0.3.3 open/close behavior deliberately kept its grid on SBIconView
    // while the native image was being faded/rebuilt. A real open is now a
    // presentation *lifecycle*, not a reason to switch to a tiny native grid.
    BOOL transitionOwner = FXIsYieldingToNativeOpen(host);
    FXMiniGrid *transitionGrid = objc_getAssociatedObject(host, &kFXOverlayKey);
    // SpringBoard may temporarily report 1x1 during the open/close zoom.
    // A pending host is known to have originated from a real large grid,
    // so trust its saved size ONLY until this particular transition ends.
    NSNumber *storedForTransition = FXSavedSize(icon);
    BOOL savedLarge = storedForTransition &&
        (storedForTransition.unsignedIntegerValue == FXFolderSizeLarge ||
         storedForTransition.unsignedIntegerValue == FXFolderSizeWide);
    BOOL pinnedTransitionGrid = transitionOwner && transitionGrid &&
        transitionGrid.superview && transitionGrid.cells.count > 0 &&
        (wantsExpanded || savedLarge);
    BOOL dragVisualLock = FXDragVisualLocked(host);

    // Previous 1.2.0 demanded setIconGridImageAlpha: on the *first*
    // iconImageView wrapper, so the 3x3 grid was never installed on some
    // devices. Resolve the native image view first; render when the 2x2 host
    // is real, and let the native thumb hiding helper use available selectors.
    // The image view is the system's actual context-menu / folder transition
    // preview source. Rendering a sibling grid under SBIconView makes two
    // separate preview trees (the double icons visible in 1.3.0 screenshots).
    BOOL nativeReady = nativeImage && MIN(nativeImage.bounds.size.width,
                                        nativeImage.bounds.size.height) >= 108;
    // Rendering follows the native size CLASS and the actually laid-out host.
    // The model's gridRange can trail behind the size setter for one pass;
    // using the cached range here caused a late 1x1 thumbnail flash.
    // A drag-lift can temporarily shrink SBFolderIconImageView while the
    // SBIconView still owns a large real cell. Latch that verified visual state
    // until the drag ends, then let native layout resume.
    if (dragVisualLock) FXStabilizeNativeImageDuringDrag(host, nativeImage);
    BOOL showOverlay = pinnedTransitionGrid ||
        ((wantsExpanded || dragVisualLock) &&
         ((geometrySettled && nativeReady) || (dragVisualLock && hasUsableFrame)));
    // The native mini-grid must remain suppressed while the controller opens
    // AND closes. Yielding it on viewWillAppear was the reason a tiny native
    // thumbnail showed during the zoom and then overlapped our large cells.
    BOOL suppressNative = showOverlay ||
        (wantsExpanded && !geometrySettled) || dragVisualLock;
    FXDiagChanged([NSString stringWithFormat:@"host/%p", host],
                  [NSString stringWithFormat:@"size=%lu w=%.0f h=%.0f native=%@ nb=%.0fx%.0f "
                   @"match=%d settled=%d overlay=%d pinned=%d suppress=%d drag=%d open=%d "
                   @"cells=%lu sup=%@ fn=%@", (unsigned long)sizeClass, width, height,
                   nativeImage ? NSStringFromClass(nativeImage.class) : @"nil",
                   nativeImage ? nativeImage.bounds.size.width : 0.0,
                   nativeImage ? nativeImage.bounds.size.height : 0.0,
                   nativeMatchesHost, geometrySettled, showOverlay, pinnedTransitionGrid,
                   suppressNative, dragVisualLock, transitionOwner,
                   (unsigned long)transitionGrid.cells.count,
                   transitionGrid.superview ? NSStringFromClass(transitionGrid.superview.class) : @"nil",
                   NSStringFromClass(FXObject(host, @"icon") ?
                                     [FXObject(host, @"icon") class] : [NSObject class])]);
    if (FXObserveOnly()) return; // observe mode installs and moves nothing
#ifdef FX_NATIVE_GRID_ONLY
    {
        FXMiniGrid *mine = objc_getAssociatedObject(host, &kFXOverlayKey);
        if (mine) mine.hidden = YES;
        FXActivateNativeGrid(host, nativeImage, sizeClass);
        BOOL editingNow = FXIsEditing(host);
        if (editingNow && side > 30 && host.window) {
            if (!handle) {
                handle = [[FXCornerHandle alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
                handle.host = host;
                [host addSubview:handle];
                objc_setAssociatedObject(host, &kFXHandleKey, handle,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            CGFloat hotSide = side < 90 ? 34.0 : 48.0;
            CGRect frame = CGRectMake(round(MAX(0, width - hotSide)),
                                      round(MAX(0, side - hotSide)), hotSide, hotSide);
            if (!CGRectEqualToRect(handle.frame, frame)) handle.frame = frame;
            handle.hidden = NO;
        } else if (handle) {
            handle.hidden = YES;
        }
        return;
    }
#endif
    // Atomic visual hand-off: hide the custom grid BEFORE revealing the
    // native thumbnail; on the opposite path hide native first, reveal ours
    // after the cell layout. This eliminates the one-frame double image.
    if (!showOverlay) {
        FXMiniGrid *existing = objc_getAssociatedObject(host, &kFXOverlayKey);
        existing.hidden = YES;
    }
    FXSetNativeThumbnailVisibility(nativeImage, suppressNative);
    if (showOverlay) {
        FXMiniGrid *overlay = objc_getAssociatedObject(host, &kFXOverlayKey);
        if (!overlay) {
            overlay = [[FXMiniGrid alloc] initWithFrame:CGRectZero];
            overlay.hidden = YES; // avoid an empty/old thumbnail frame
            overlay.host = host;
            objc_setAssociatedObject(host, &kFXOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        // Single ownership: this exact subtree supplies SpringBoard's native
        // folder preview. NEVER move the grid out during an open/close.
        // While the transition is active keep its last settled size, letting
        // SpringBoard animate the image parent rather than relaying out cells.
        // A transient nil native view during SpringBoard image replacement is
        // NOT a reason to detach our last valid grid. Wait for its successor.
        if (nativeImage && overlay.superview != nativeImage) {
            [overlay removeFromSuperview];
            [nativeImage addSubview:overlay];
        }
        if (nativeImage && !pinnedTransitionGrid) {
            CGRect desired = nativeImage.bounds;
            if (!CGRectEqualToRect(overlay.frame, desired)) overlay.frame = desired;
        }
        overlay.host = host;
        BOOL editingNow = FXIsEditing(host);
        overlay.userInteractionEnabled = NO; // native gestures own ALL touches
        overlay.accessibilityElementsHidden = editingNow;
        [overlay setEditingAppearance:editingNow];
        // Never rebuild cells or change their frames while native zoom is in
        // flight. 0.3.3's core lesson is to keep the already-painted source
        // visible and stable until the native close completion callback.
        if (!pinnedTransitionGrid) {
            NSUInteger columns = FXPreviewColumns(icon, host);
            if (overlay.gridColumns != columns) {
                overlay.gridColumns = columns;
                overlay.displayIDs = @[];
            }
            [overlay updateWithApps:FXFolderApps(icon)];
            [overlay setNeedsLayout];
            [overlay layoutIfNeeded];
        }
        overlay.hidden = NO;
        FXDiagViewTree(nativeImage, [NSString stringWithFormat:@"tree/%p", nativeImage]);
        // Do not make the native tap recognizer depend on an overlay tap.
        // That dependency intercepted long presses and sometimes opened the
        // folder underneath a direct launch.
    } else {
        // Reuse the same display-only grid across sizes; the native tap and
        // long-press recognizers are never replaced or retained by us.
        FXMiniGrid *oldOverlay = objc_getAssociatedObject(host, &kFXOverlayKey);
        [oldOverlay setEditingAppearance:NO];
        [oldOverlay setDropHovered:NO];
        oldOverlay.hidden = YES;
        oldOverlay.userInteractionEnabled = NO;
    }

    // The handle belongs to the icon, not to its thumbnail image or menu view.
    // This keeps finger movement attached to the same stable coordinate system.
    BOOL editing = FXIsEditing(host);
    if (editing && side > 30 && host.window) {
        if (!handle) {
            handle = [[FXCornerHandle alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
            handle.host = host;
            [host addSubview:handle];
            objc_setAssociatedObject(host, &kFXHandleKey, handle, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        // A compact small-folder handle must not swallow most of a 1x1 icon.
        // On 2x2 it is 48pt for easier acquisition. Both remain invisible.
        CGFloat hotSide = side < 90 ? 34.0 : 48.0;
        CGRect frame = CGRectMake(round(MAX(0, width - hotSide)),
                                  round(MAX(0, side - hotSide)), hotSide, hotSide);
        if (!CGRectEqualToRect(handle.frame, frame)) handle.frame = frame;
        handle.hidden = NO;
    } else if (handle) {
        handle.hidden = YES;
    }

    // Resize hot area belongs to SBIconView. The grid stays inside native
    // image at rest; only a native open/close temporarily parks it on host.
    if (handle && !handle.hidden && host.subviews.lastObject != handle && !handle.resizing)
        [host bringSubviewToFront:handle];

    NSNumber *wanted = FXSavedSize(icon);
    if (host.window && !wantsExpanded && geometrySettled &&
        !transitionOwner && !FXNativeFolderIsPresented && !FXNativeDragIsActive() && wanted &&
        (wanted.unsignedIntegerValue == FXFolderSizeLarge ||
         wanted.unsignedIntegerValue == FXFolderSizeWide)) {
        FXRestoreSizeForView(host);
    }
}

// A single checked resize transaction is shared by the invisible corner
// gesture and the system context-menu action. No fabricated view geometry.
BOOL FXCommitSizeForHost(UIView *host, FXFolderSize size) {
    if (!host || !FXIsFolder(FXObject(host, @"icon"))) { FXDiagLog(@"commit.host reject"); return NO; }
    if (!host.window || FXNativeDragIsActive() || FXNativeFolderIsPresented) {
        FXDiagLog(@"commit.host blocked window=%d drag=%d presented=%d",
                  (int)(host.window != nil), (int)FXNativeDragIsActive(),
                  (int)FXNativeFolderIsPresented);
        return NO;
    }
    if (!FXChangeSize(FXObject(host, @"icon"), size, YES)) return NO;
    [host setNeedsLayout];
    Class listClass = NSClassFromString(@"SBIconListView");
    for (UIView *ancestor = host; ancestor; ancestor = ancestor.superview) {
        if (listClass && [ancestor isKindOfClass:listClass]) {
            [ancestor setNeedsLayout];
            break;
        }
    }
    // SpringBoard will perform the actual resize layout.  Repeating forced
    // refreshes at 0.18/0.5s resurrected the obsolete native icon image after
    // a folder size transaction, causing a temporary visual displacement.
    return YES;
}

// Context menu previews can replace the SBIconView while dismissing. Resolve
// the current live folder by stable UID; do not depend on the stale weak view.
BOOL FXCommitSizeForIdentifier(NSString *uid, FXFolderSize size) {
    if (!uid.length || FXNativeDragIsActive() || FXNativeFolderIsPresented) {
        FXDiagLog(@"commit.uid blocked uid=%d drag=%d presented=%d", (int)(uid.length > 0),
                  (int)FXNativeDragIsActive(), (int)FXNativeFolderIsPresented);
        return NO;
    }
    id folder = FXFolderWithIdentifier(uid);
    if (!folder) { FXDiagLog(@"commit.uid folder-not-found"); return NO; }
    if (!FXChangeSize(folder, size, YES)) return NO;
    for (UIView *host in FXKnownFolderHosts.allObjects) {
        if (!host.window || ![FXIdentifier(FXObject(host, @"icon")) isEqualToString:uid])
            continue;
        [host setNeedsLayout];
        Class listClass = NSClassFromString(@"SBIconListView");
        for (UIView *ancestor = host.superview; ancestor; ancestor = ancestor.superview) {
            if (listClass && [ancestor isKindOfClass:listClass]) {
                [ancestor setNeedsLayout];
                break;
            }
        }
        // Do not run a nested layout while the list model is committing.
        // The normal SBIconView.layoutSubviews hook is the single paint point.
    }
    return YES;
}

// The native SBFolderController and SBHIconManager decide when transitions
// finish. Keep our existing live thumbnail on the stable host until both
// lifecycle callbacks agree that the native close is complete.
void FXSetNativeFolderPresentationActive(BOOL active) {
    // This global flag is only used to prohibit size mutations while a native
    // controller is onscreen. It must NOT own visibility of every home-screen
    // folder. Only a host marked by FXPrepareNativeFolderOpen yielded its grid.
    BOOL wasPresented = FXNativeFolderIsPresented;
    FXNativeFolderIsPresented = active;
    FXDiagEvent(@"presentation", @{@"active": @(active), @"was": @(wasPresented),
                                   @"hosts": @(FXKnownFolderHosts.allObjects.count)});
    // The grid stays inside the native folder image for both animation and
    // context-menu previews. Here we only release the per-folder transition
    // freeze once SpringBoard has completed the close.
    if (active) return;
    if (!wasPresented) return;
    // Native manager close-completion has finished. Restore only the
    // folder(s) we actually opened, leaving neighboring 2x2 icons untouched.
    for (UIView *host in FXKnownFolderHosts.allObjects) {
        if (!objc_getAssociatedObject(host, &kFXNativeOpenPendingKey)) continue;
        BOOL wasYielding = FXIsYieldingToNativeOpen(host);
        objc_setAssociatedObject(host, &kFXNativeOpenPendingKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (wasYielding && host.window) {
            FXRefreshIconView(host);
            [host setNeedsLayout];
        }
    }
}

// Logos hooks -fulfillGridImageForPageElement: and forwards here. That method is
// the point where SpringBoard installs a page's mini grid; re-asserting inside
// the same call removes the frame where the native grid and ours are both alive.
void FXNeutralizeNativeGridAfterUpdate(UIView *imageView) {
#ifdef FX_NATIVE_GRID_ONLY
    return; // plan A renders the native grid on purpose
#endif
    if (FXObserveOnly() || !imageView) return;
    UIView *host = FXHostForNativeImage(imageView);
    FXMiniGrid *overlay = objc_getAssociatedObject(host, &kFXOverlayKey);
    if (!overlay || overlay.hidden || !overlay.superview) return; // not our folder
    static char kFXNeutralizeDepth;
    NSNumber *depth = objc_getAssociatedObject(imageView, &kFXNeutralizeDepth);
    if (depth.integerValue > 1) return; // never recurse into our own suppression
    objc_setAssociatedObject(imageView, &kFXNeutralizeDepth, @(depth.integerValue + 1),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    FXDiagThrottled([NSString stringWithFormat:@"neut/%p", imageView], 0.2,
                    @"grid.neutralize %@", NSStringFromClass(imageView.class));
    FXSetNativeThumbnailVisibility(imageView, YES);
    objc_setAssociatedObject(imageView, &kFXNeutralizeDepth, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void FXRefreshNativeImageView(UIView *imageView) {
#ifdef FX_NATIVE_GRID_ONLY
    return; // plan A renders the native grid on purpose
#endif
    if (!imageView) return;
    UIView *view = imageView.superview;
    Class iconViewClass = NSClassFromString(@"SBIconView");
    for (NSUInteger i = 0; i < 5 && view; i++, view = view.superview) {
        if (iconViewClass && [view isKindOfClass:iconViewClass]) {
            FXMiniGrid *visible = objc_getAssociatedObject(view, &kFXOverlayKey);
            id icon = FXObject(view, @"icon");
            UIView *actualImage = FXNativeImageView(view) ?: imageView;
            // 1.5.6 logged hide=1 on the App Library indicator's image view:
            // SB*IconImageView subclasses share these selectors. Only a real
            // folder icon may have its native grid suppressed.
            if (!FXIsFolder(icon)) {
                FXSetNativeThumbnailVisibility(actualImage, NO);
                return;
            }
            FXStabilizeNativeImageDuringDrag(view, actualImage);
            CGFloat height = view.bounds.size.height;
            BOOL frameMatches = fabs(actualImage.bounds.size.width - view.bounds.size.width) <= 5.0 &&
                fabs(actualImage.bounds.size.height - (height > 14 ? height - 14 : height)) <= 7.0;
            NSUInteger cls = FXSize(icon);
            BOOL changingSize = !frameMatches ||
                ((cls == FXFolderSizeSmall) && view.bounds.size.width > 88.0);
            BOOL hide = (visible && visible.superview && !visible.hidden) ||
                (changingSize && FXSize(icon) != FXFolderSizeSmall) ||
                FXDragVisualLocked(view);
            // The pending open/close already owns the large host-mounted grid;
            // do not reveal native 1x1 cells when its image layer is rebuilt.
            if (FXIsYieldingToNativeOpen(view) && visible && visible.superview)
                hide = YES;
            FXSetNativeThumbnailVisibility(actualImage, hide);
            return;
        }
    }
    FXSetNativeThumbnailVisibility(imageView, NO);
}

// Handle the native SBIconView tap ONLY after its recognizer succeeds.
// Never swallow began/changed: SpringBoard must still own long-press/edit.
BOOL FXHandleFolderTap(UIView *host, id gesture) {
    if (!host || ![gesture isKindOfClass:UITapGestureRecognizer.class]) return NO;
    UITapGestureRecognizer *tap = (UITapGestureRecognizer *)gesture;
    if (tap.state != UIGestureRecognizerStateEnded) return NO;
    if (FXIsEditing(host)) return NO;
    FXMiniGrid *overlay = objc_getAssociatedObject(host, &kFXOverlayKey);
    if (!overlay || !overlay.superview || overlay.hidden) return NO;
    CGPoint local = [overlay convertPoint:[tap locationInView:host] fromView:host];
    id app = [overlay appAtPoint:local];
    if (!app) {
        FXDiagThrottled([NSString stringWithFormat:@"tapmiss/%p", host], 0.5,
                        @"tap.passthrough host=%p state=%ld cells=%lu",
                        host, (long)tap.state, (unsigned long)overlay.cells.count);
        return NO;
    }
    FXDiagLog(@"tap.app host=%p index=%ld", host, (long)[overlay indexAtPoint:local]);
    // Returning YES here prevents a repeated native open for the SAME tap;
    // a fast second tap on another cell remains independently actionable.
    if (FXRecentlyHandledApp(host, app)) return YES;
    [overlay launchAtPoint:local];
    return YES;
}

BOOL FXSuppressNativeFolderAction(UIView *host) {
    if (!host) return NO;
    if (FXRecentlyHandled(host)) return YES;
    return FXHandleFolderTap(host, FXObject(host, @"tapGestureRecognizer"));
}

void FXSetDropHoverForHost(UIView *host, BOOL hovered) {
    if (!host) return;
    FXMiniGrid *overlay = objc_getAssociatedObject(host, &kFXOverlayKey);
    if (overlay) [overlay setDropHovered:hovered];
}

// Opening from empty space: keep the same enlarged grid IN the native folder
// image that SpringBoard uses as its transition source. Moving it to a sibling
// icon host before the snapshot was the 1.4.9 double-image regression.
void FXPrepareNativeFolderOpen(UIView *host) {
    if (!host || FXIsEditing(host)) return;
    FXMiniGrid *overlay = objc_getAssociatedObject(host, &kFXOverlayKey);
    if (!overlay || overlay.hidden || !overlay.superview) return;
    if (FXIsYieldingToNativeOpen(host) || FXNativeFolderIsPresented) return;
    // Pin the live grid identity for the complete native open/close. Do not
    // replace it with a miniature or move it outside the snapshot tree.
    NSString *openedUID = [FXIdentifier(FXObject(host, @"icon")) copy];
    if (!openedUID.length) return;  // do not mutate a recycled/unknown host
    objc_setAssociatedObject(host, &kFXNativeOpenPendingKey, openedUID,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    FXDiagEvent(@"open.prepare", @{@"size": @(FXSize(FXObject(host, @"icon"))),
                                   @"cells": @(overlay.cells.count),
                                   @"overlayParent": overlay.superview ?
                                       NSStringFromClass(overlay.superview.class) : @"nil"});
    // The native SBFolderIconImageView retains its large drawn content while
    // SpringBoard captures / animates it. Its own alpha transition applies to
    // the same grid; there is no second live grid left behind on SBIconView.
    [overlay setEditingAppearance:NO];
    [overlay setDropHovered:NO];
    // This fallback only handles an aborted open (e.g. a gesture intercepted
    // by SpringBoard), not the close path. It cannot delay closing restoration.
    __weak UIView *weakHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *live = weakHost;
        if (!live || FXNativeFolderIsPresented || !FXIsYieldingToNativeOpen(live)) return;
        objc_setAssociatedObject(live, &kFXNativeOpenPendingKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        FXRefreshIconView(live);
    });
}

// Called only when normal SBIconView hit-testing would reject a touch. A small
// edit-only corner extension (11pt) improves resize initiation without adding
// a visible button or creating a separate UIDragInteraction.
UIView *FXResizeHitView(UIView *host, CGPoint point, UIEvent *event) {
    if (!host || !host.window || !FXIsEditing(host) ||
        !FXIsFolder(FXObject(host, @"icon"))) return nil;
    FXCornerHandle *handle = objc_getAssociatedObject(host, &kFXHandleKey);
    if (!handle || handle.hidden || handle.superview != host) return nil;
    // Keep the touch inside SBIconView bounds. Extending past the native frame
    // could steal gestures from adjacent desktop icons.
    if (!CGRectContainsPoint(host.bounds, point)) return nil;
    CGPoint local = [handle convertPoint:point fromView:host];
    if (![handle pointInside:local withEvent:event]) return nil;
    // UIKit can ask for a drag source before our pan recognizer transitions to
    // Began. Reserve only this small corner long enough for pan to take over.
    if (event && event.type == UIEventTypeTouches)
        objc_setAssociatedObject(host, &kFXResizeTouchPendingUntilKey,
                                 @(CACurrentMediaTime() + 1.05),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    FXDiagThrottled([NSString stringWithFormat:@"hit/%p", host], 0.3,
                    @"resize.hit host=%p bounds=%.0fx%.0f local=%.0f,%.0f",
                    host, host.bounds.size.width, host.bounds.size.height, local.x, local.y);
    return handle;
}

BOOL FXResizeGestureActiveForHost(UIView *host) {
    FXCornerHandle *handle = host ? objc_getAssociatedObject(host, &kFXHandleKey) : nil;
    NSNumber *until = host ? objc_getAssociatedObject(host, &kFXResizeTouchPendingUntilKey) : nil;
    return handle && !handle.hidden &&
           (handle.resizing || (until && CACurrentMediaTime() < until.doubleValue));
}
