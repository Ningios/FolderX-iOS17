# FolderX 1.5.20 — 开合临时副本预览保护（候选）

## 真机实验依据

- v22：在文件夹打开和退出的过渡阶段，SpringBoard 会创建第二个 `SBIconView`，它的 `FXMiniGrid` 可能与原生动画内容并存。正常桌面原始宿主一直在真实 `SBIconListView` 中，过渡副本不在。
- v23：临时隐藏**同一 folder model** 的过渡副本网格后，用户反馈“点开可以了”。
- v24：打开和退出各出现一个独立副本；成功将两个网格 alpha 设为 0，副本在关闭完成时已消失。**用户尚未反馈 v24 的视觉结果**。
- v24 的横坐标记录均是 `? / NaN`，因为脚本将 Frida 的 CGRect 数组误当成 `.origin.x` 结构；不能据此修 4×2 偏左。

## 修改范围

唯一行为变更文件 `FXInterface.mm`：`FXRefreshIconView` 在创建/刷新预览网格时调用 `FXGuardTransitionCloneGrid`：

- 原始文件夹模型必须在真实 `SBIconListView` 的大尺寸宿主，且已被 `FXPrepareNativeFolderOpen` 标记为正在打开。
- 匹配 **相同 Objective-C 图标模型对象**、但不在任何 `SBIconListView` 中的第二个 `SBIconView`，才把它的 `FXMiniGrid.alpha` 立即设为 `0`。
- **原始宿主、其他文件夹以及文件夹完整内容页均不改变**。
- 关闭完成不恢复临时副本。复用成真实列表图标或绑定到其他模型时恢复透明度。
- 不修改 `FXTransition.xm`, `FXCore.mm`, `FXDrop.xm`, `FXDragAppFrameGuard.xm`, `Tweak.xm` 或 `FXMenu.xm`。

## 验证与限制

候选源码尚未在 iPhone 上编译/安装。先确保 1.5.19 备份可回退，退出所有 Frida 并 respring，替换此版后对比：
1. 2×2 和 4×2 先打开、再关闭；看打开重叠、退出时小图标闪烁是否消失。
2. 检查 **4×2 打开时图标先偏左再右移**是否仍存在。这里没有修改坐标，不宣称已修复。
3. 确认大文件夹内 App 正常启动，以及右下角 resize、拖动和禁入选项没有回归。
4. 长按/上下页面切换后，再检查预览是否持续显示。若消失、空白、闪烁或安全模式，立即回退 1.5.19。

本版的静态测试不等于 Theos 编译或真机验证。
