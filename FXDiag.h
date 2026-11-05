#ifndef FX_DIAG_H
#define FX_DIAG_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// Gated diagnostic channel. Never logs bundle identifiers or user text:
// only class names, selected selectors, geometry and branch decisions.
//
// Enabled when: DiagnosticsEnabled == YES in the tweak preference domain,
//   or (compile-time default FX_DIAG_DEFAULT_ON) and the preference key is absent.
// Disabled when: the key is NO, or /var/mobile/Library/Logs/FolderX/off exists.
// The log lives at /var/mobile/Library/Logs/FolderX/fx-diag.log and is capped.
BOOL FXDiagEnabled(void);

// Dumps method names of a class (and its superclasses) that match any keyword.
void FXDiagClassMethods(NSString *className, NSArray<NSString *> *keywords);

// Dumps the view subtree (class / frame / alpha / hidden), only when it changes.
void FXDiagViewTree(UIView *root, NSString *key);

// Class method list matching grid/image keywords, once per class.
void FXDiagDumpGridMethods(NSString *className);

// Compile-time read-only mode: report only, never touch the view tree,
// private rendering setters, or the icon model.
BOOL FXObserveOnly(void);

void FXDiagInstall(void);                     // writes the header line once
void FXDiagLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void FXDiagEvent(NSString *event, NSDictionary *info);

// Logs at most once per key per interval. Use for per-layout-pass values.
void FXDiagThrottled(NSString *key, NSTimeInterval interval,
                     NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);

// Logs only when the rendered payload differs from the previous one for key.
void FXDiagChanged(NSString *key, NSString *payload);

// One-time capability report for a native folder image view.
void FXDiagProbeImageView(UIView *imageView);

#ifdef __cplusplus
}
#endif

#endif