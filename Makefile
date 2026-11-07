# FolderX Fresh 1.4.4 — new minimal project for iPhone 15 Pro / iOS 17.1.1.
# The device previously used a roothide tweak. Change the scheme at build time
# to rootless when the device is actually using a conventional rootless jailbreak.
export TARGET = iphone:clang:latest:17.0
export ARCHS = arm64e
THEOS_PACKAGE_SCHEME ?= roothide
export THEOS_PACKAGE_SCHEME

INSTALL_TARGET_PROCESSES = SpringBoard
FINALPACKAGE ?= 1

TWEAK_NAME = FolderX
FolderX_FILES = Tweak.xm FXCore.mm FXInterface.mm FXDrop.xm FXMenu.xm FXTransition.xm FXListHit.xm FXDiag.mm
FolderX_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DFX_DIAG_DEFAULT_ON=1 -DFX_NATIVE_GRID_ONLY=1 
FolderX_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
