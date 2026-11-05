#import "FXDiag.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

// Opt-in diagnostic channel. Everything here is read-only observation: it
// never mutates SpringBoard state, only records which branch the existing
// logic took. Writes happen on a private utility queue, never on the caller.

static NSString *const FXDiagPrefDomain = @"com.huhansibuxin.folderx.fresh";
static NSString *const FXDiagPrefKey = @"DiagnosticsEnabled";
static NSString *const FXDiagDirPath = @"/var/mobile/Library/Logs/FolderX";
static NSString *const FXDiagFilePath = @"/var/mobile/Library/Logs/FolderX/fx-diag.log";

static CFTimeInterval FXDiagT0 = 0;
static NSMutableSet<NSString *> *FXDiagProbed = nil;
static NSMutableDictionary<NSString *, NSString *> *FXDiagLastPayload = nil;

static dispatch_queue_t FXDiagQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.folderx.diag", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

BOOL FXDiagEnabled(void) {
    static BOOL cached = NO;
    static CFTimeInterval cachedAt = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (cachedAt != 0 && now - cachedAt < 2.0) return cached;

    BOOL on = NO;
#ifdef FX_DIAG_DEFAULT_ON
    on = YES; // diagnostic build: on unless the user turns it off
#endif
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:FXDiagPrefDomain];
    if ([defaults objectForKey:FXDiagPrefKey] != nil)
        on = [defaults boolForKey:FXDiagPrefKey];
    if (on && [[NSFileManager defaultManager]
               fileExistsAtPath:[FXDiagDirPath stringByAppendingPathComponent:@"off"]])
        on = NO;
    cached = on;
    cachedAt = now;
    return on;
}

// Only ever touched from FXDiagQueue().
static NSFileHandle *FXDiagHandleLocked(void) {
    static NSFileHandle *handle = nil;
    if (handle) return handle;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:FXDiagDirPath withIntermediateDirectories:YES attributes:nil error:NULL];
    NSDictionary *attrs = [fm attributesOfItemAtPath:FXDiagFilePath error:NULL];
    unsigned long long size = attrs ? [attrs fileSize] : 0;
    if (size > 3ull * 1024 * 1024) {
        NSString *old = [FXDiagFilePath stringByAppendingString:@".old"];
        [fm removeItemAtPath:old error:NULL];
        [fm moveItemAtPath:FXDiagFilePath toPath:old error:NULL];
    }
    if (![fm fileExistsAtPath:FXDiagFilePath])
        [fm createFileAtPath:FXDiagFilePath contents:nil attributes:nil];
    handle = [NSFileHandle fileHandleForWritingAtPath:FXDiagFilePath];
    @try { [handle seekToEndOfFile]; } @catch (__unused NSException *ex) { handle = nil; }
    return handle;
}

static void FXDiagEnqueue(NSString *line) {
    NSString *payload = [line copy];
    if (!payload.length) return;
    dispatch_async(FXDiagQueue(), ^{
        NSFileHandle *handle = FXDiagHandleLocked();
        if (!handle) return;
        NSData *data = [[payload stringByAppendingString:@"\n"]
                        dataUsingEncoding:NSUTF8StringEncoding];
        @try { [handle writeData:data]; } @catch (__unused NSException *ex) { }
    });
}

static NSString *FXDiagStamp(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (FXDiagT0 == 0) FXDiagT0 = now;
    NSString *thread = [NSThread isMainThread] ? @"main" : @"bg";
    return [NSString stringWithFormat:@"%8.3f %@", now - FXDiagT0, thread];
}

void FXDiagLog(NSString *format, ...) {
    if (!FXDiagEnabled()) return;
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    FXDiagEnqueue([NSString stringWithFormat:@"%@ %@", FXDiagStamp(), body]);
}

void FXDiagEvent(NSString *event, NSDictionary *info) {
    if (!FXDiagEnabled() || !event.length) return;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in [info.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id value = info[key];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
    }
    FXDiagLog(@"EVENT %@ %@", event, [parts componentsJoinedByString:@" "]);
}

void FXDiagThrottled(NSString *key, NSTimeInterval interval,
                     NSString *format, ...) {
    if (!FXDiagEnabled() || !key.length) return;
    CFTimeInterval now = CACurrentMediaTime();
    static NSMutableDictionary<NSString *, NSNumber *> *last = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ last = [NSMutableDictionary dictionary]; });
    NSNumber *previous = last[key];
    if (previous && now - previous.doubleValue < interval) return;
    last[key] = @(now);
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    FXDiagEnqueue([NSString stringWithFormat:@"%@ [%@] %@", FXDiagStamp(), key, body]);
}

void FXDiagChanged(NSString *key, NSString *payload) {
    if (!FXDiagEnabled() || !key.length) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ FXDiagLastPayload = [NSMutableDictionary dictionary]; });
    if (payload && [FXDiagLastPayload[key] isEqualToString:payload]) return;
    FXDiagLastPayload[key] = payload ?: @"";
    FXDiagEnqueue([NSString stringWithFormat:@"%@ [%@] %@", FXDiagStamp(), key, payload ?: @"(nil)"]);
}

static NSString *FXDiagSelectorReport(id object, NSString *name) {
    if (!object) return @"-";
    SEL sel = NSSelectorFromString(name);
    if (![object respondsToSelector:sel]) return @"absent";
    NSMethodSignature *sig = [object methodSignatureForSelector:sel];
    if (!sig) return @"no-sig";
    NSMutableString *types = [NSMutableString string];
    [types appendFormat:@"ret=%s args=%lu", sig.methodReturnType,
                       (unsigned long)sig.numberOfArguments];
    for (NSUInteger i = 2; i < sig.numberOfArguments; ++i)
        [types appendFormat:@" a%lu=%s", (unsigned long)i, [sig getArgumentTypeAtIndex:i]];
    return types;
}

void FXDiagProbeImageView(UIView *imageView) {
    if (!FXDiagEnabled() || !imageView) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ FXDiagProbed = [NSMutableSet set]; });
    NSString *cls = NSStringFromClass(imageView.class);
    if (!cls.length || [FXDiagProbed containsObject:cls]) return;
    [FXDiagProbed addObject:cls];

    NSMutableString *chain = [NSMutableString string];
    NSUInteger step = 0;
    for (UIView *v = imageView; v && step < 7; v = v.superview, ++step) {
        if (step) [chain appendString:@" < "];
        [chain appendString:NSStringFromClass(v.class)];
    }
    FXDiagLog(@"PROBE class=%@ chain=%@", cls, chain);
    FXDiagLog(@"PROBE %@ setIconGridImageAlpha: -> %@", cls,
              FXDiagSelectorReport(imageView, @"setIconGridImageAlpha:"));
    FXDiagLog(@"PROBE %@ iconGridImageAlpha -> %@", cls,
              FXDiagSelectorReport(imageView, @"iconGridImageAlpha"));
    FXDiagLog(@"PROBE %@ disableImageUpdatesForReason: -> %@", cls,
              FXDiagSelectorReport(imageView, @"disableImageUpdatesForReason:"));
    FXDiagLog(@"PROBE %@ invalidateImageUpdatesAssertion: -> %@", cls,
              FXDiagSelectorReport(imageView, @"invalidateImageUpdatesAssertion:"));
    FXDiagLog(@"PROBE %@ pageGridContainer -> %@", cls,
              FXDiagSelectorReport(imageView, @"pageGridContainer"));
    FXDiagLog(@"PROBE %@ iconGridImageAlpha(get) -> %@", cls,
              FXDiagSelectorReport(imageView, @"iconGridImageAlpha"));
    Class iconViewClass = NSClassFromString(@"SBIconView");
    for (UIView *v = imageView; v; v = v.superview) {
        if (iconViewClass && [v isKindOfClass:iconViewClass]) {
            FXDiagLog(@"PROBE host=%@ iconImageView -> %@", NSStringFromClass(v.class),
                      FXDiagSelectorReport(v, @"iconImageView"));
            break;
        }
    }
}

void FXDiagInstall(void) {
    if (!FXDiagEnabled()) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:FXDiagDirPath withIntermediateDirectories:YES attributes:nil error:NULL];
    dispatch_async(FXDiagQueue(), ^{
        NSFileHandle *handle = FXDiagHandleLocked();
        if (!handle) return;
        UIDevice *device = UIDevice.currentDevice;
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSString *line = [NSString stringWithFormat:
            @"==== FolderX diag start %@ | iOS %@ (%@) | %@ %@ | main=%@ ====",
            [NSDate date], device.systemVersion, [info objectForKey:@"CFBundleVersion"],
            device.model, device.systemName, NSBundle.mainBundle.bundleIdentifier];
        @try { [handle writeData:[[line stringByAppendingString:@"\n"]
                                 dataUsingEncoding:NSUTF8StringEncoding]]; }
        @catch (__unused NSException *ex) { }
    });
}