# FolderX 1.4.9 范围与验证

## 依据

- 0.3.3 `FEOverlayManager.mm`: 自绘层挂载在 SBIconView，避免 SBFolderIconImageView 在关闭动画中 alpha=0 带走所有子图标；相关注释和函数 `FE_attachOverlayToIconView`。
- 0.3.3 `FEIconHooks.xm`: `tapGestureDidChange:` 只有命中内部 App 时才直接启动，原生 `_handleTap` / `performTap` 在重复处理时被抑制。
- 0.3.3 `FECore.mm`: `launchFromLocation:context:` 参数采用 `@(1)` 对象，不允许传指针等价的裸整数。
- 1.4.8 `FXInterface.mm`: `openingNative` 把自绘层隐藏、释放原生小缩略图，关闭后再次恢复；造成一帧/多帧闪小和双层图标的潜在路径。

## 改动

1. 内部 App 点击：原生识别器成功且命中具体单元后，立即使用 native `SBIcon launchFromLocation:context:`，失败再退回原有的异步 LaunchServices 方式。只给具体 App 播放局部按压反馈；不为整个文件夹增加动画。
2. 文件夹打开：点击空白准备原生打开时，把已有 `FXMiniGrid` 从原生 `SBFolderIconImageView` 移到同一 `SBIconView`，保留精确坐标与当前图标布局。此后文件夹关闭完成前不因原生图片视图缩放/透明变化重新布局这些单元。
3. 文件夹关闭：仍等待原有 `viewDidDisappear:` + manager 的 `opened=NO` 完成判定；结束时才把网格移回原生图片子树供长按预览。保留 per-icon UID 绑定，避免打开一个文件夹影响邻近文件夹。
4. 原生小缩略图：在大网格实际可见时持续抑制，包括原生开合期间；不添加快照或新背景。

## 不改动

- `FXDrop.xm`、`FXListHit.xm`：原生拖入/延迟补救，仍保留 1.4.8 的行为。
- `FXTransition.xm`：既有关闭完成双条件防护不变。
- `FXCore.mm`：除内部图标启动入口外，网格尺寸、持久化和图标分页逻辑不变。
- `FXInterface.mm`：右下角拖动手势、4x2 内部布局计算不变。

## 验证边界

这不是经过 iOS17.1.1 真机验证的 UI 修复结论。未在本环境编译 Theos/运行 SpringBoard。特别测试原生菜单、快速连续开合与被系统重新利用的图标视图。如果发生空白或重复层，应退回 1.4.8，不要自行调整桌面占位模型。
