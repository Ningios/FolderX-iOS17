# FolderX 1.5.15 — 入口拦截修正 / 轻量跨页定位

本版以用户验证“拖动整个大文件夹时正常”的 1.5.14 为基础。**不声称已修复跨页大文件夹缩成 1x1 或开合重叠。**

## 已修复的代码条件（待真机验证）

- 1.5.14 的 `FXShouldBlockFolderOpenIcon()` 在 `FXNativeDragIsActive()` 为真时直接返回 NO。该变量在 UIKit 拖动结束之后仍可能暂留，用户点击被设置 `blockedPref=YES` 的大文件夹依然能够打开。
- 1.5.15 移除**只针对打开动作**的拖动/编辑态放行，保留 `SBIconView` 的 _handleTap、performTap、tapGestureDidChange 与 `SBHIconManager` 原生入口双重防线。3D Touch 开关及右下角 resize 不变；`FXDrop` 原生拖入代码完全不改。
- 语义说明：开启“禁止进入文件夹”后也不允许原生拖动产生的弹开文件夹动画（spring open）；但仍然会执行原生 dropInteraction 的拖入处理。请实测拖入是否照常生效。

## 尚未修复的跨页缩小（不能盲目改 model 或 frame）

v10 日志确认：同一页三个文件夹模型保持 `4x2、4x2、2x2`，外层 `SBIconView` 却被 SpringBoard 排成 `60x74`，三枚横向一排。旧版尺寸保护只捕获可见宽度 >=110 的大文件夹，此时已错过保护时机。不能通过再次修改 modelHasNonDefaultSizedIcons 或固定所有图标 frame 处理，否则可能造成之前的三文件夹叠加回归。

随包提供的 `folderx_layout_caller_probe_v11.js` 针对 `SBIconView setFrame` 的变小事件记录调用者模块，并在目标页面首次进入时少量采样。它只读、无需全屏连续扫描。请单独运行、只跨页拖动一次、发出日志；也可先用它确认 1.5.15 的屏蔽点击是否生效。

## 开合重叠

v9 中大幅缩小的 L6/L7 是**文件夹内部页面**转场，不能当作桌面图标重排。需要确定真实重复图层，故不改 `FXTransition.xm` / FXMiniGrid 的单一预览结构。

## 安全清单

- 保留 1.5.12 App 跳位防护和 1.5.14 大文件夹拖动防护，原样保留 `FXDrop.xm` 与 `FXDragAppFrameGuard.xm`。
- 不新增全局网格 Hook；不把 2x2/4x2 改成 1x1；不修改文件夹 frame、模型索引或源拖动时序。
- 未在真机编译运行；建议备份布局，保留能回退的 1.5.14 安装包。
