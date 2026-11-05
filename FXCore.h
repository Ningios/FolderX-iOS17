#ifndef FX_CORE_H
#define FX_CORE_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

// iOS 17.1.1: 0 = native 1x1; 1 = genuine 2x2 model grid class.
// Never set SBIconView.frame or fake an expanded widget-sized hit region.
typedef NS_ENUM(NSUInteger, FXFolderSize) {
    FXFolderSizeSmall = 0,
    FXFolderSizeLarge = 1,
    FXFolderSizeWide = 2 // conditional: only enabled when native 4x2 mapping is verified
};

typedef struct {
    unsigned long long gridCellIndex;
    unsigned short columns;
    unsigned short rows;
} FXGridRange;

id FXObject(id obj, NSString *selectorName);
NSUInteger FXUnsigned(id obj, NSString *selectorName);
BOOL FXBoolean(id obj, NSString *selectorName);
BOOL FXIsFolder(id icon);
NSString *FXIdentifier(id icon);
NSUInteger FXSize(id icon);
id FXListModel(id icon);
id FXFolderWithIdentifier(NSString *uid);
FXGridRange FXGridOf(id model, id icon);
BOOL FXIsGenuineLarge(id icon);
BOOL FXCanUseWideGrid(void);
// Rendering fallback is separate from verified model occupancy.
BOOL FXShouldRenderLarge(id icon, UIView *host);
BOOL FXChangeSize(id icon, FXFolderSize target, BOOL persist);
NSNumber *FXSavedSize(id icon);
void FXRestoreSizeForView(UIView *host);
NSArray *FXFolderApps(id folderIcon);
NSString *FXBundleID(id leafIcon);
UIImage *FXAppImage(NSString *bundleID);
void FXLaunchApp(id leafIcon);
BOOL FXIsEditing(UIView *iconView);
BOOL FXNativeDragIsActive(void);
void FXRememberEditingForView(UIView *host, BOOL editing);

#endif
