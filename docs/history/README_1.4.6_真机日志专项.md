# FolderX 1.4.6 · 拖放目标/来源联合修订（未真机验收）

本候选版本以 1.4.5 为基础；**不保证 App 已经能拖入大文件夹，也未修复开合转场旧 bug**。保留已经正常的右下角横向 4×2 尺寸手势，没有引入快照、额外 UIDropInteraction、写入式 Frida 日志或直接改 SBFolder 图标数据库。

## 来自 iOS 17.1.1 真机 Frida 的事实
- 通过 `iconAtPoint:index:` 在拖动期间多次检测到 `SBFolderIcon`，也出现 `SBCustomPlaceholderIcon` 和 nil。
- Native destination 的 `dropInteraction:sessionDidUpdate:` 给出 operation=2 (Copy)；`dropInteraction:performDrop:` 确实执行，但其 destination `SBIconListModel` 属于 `SBRootFolder`。
- 未检测到 `SBHIconManager addIcons:intoFolderIcon:openFolderOnFinish:completion:` 和 `SBFolder addIcon/insertIcon` 调用。
- 本次监控的 `changeGridSizeClassOfContainedIcon:...` 没有出现；这不能排除其他尺寸变更机制。

## 本版有针对性的源码更改
1. `FXDrop.xm` 拖动源仅依靠 Bundle ID 的前置门槛改成 Bundle ID 或稳定 UID；仍只接收 `SBLeafIcon`，避免用拖拽占位对象冒充源 App。
2. 拖动开始前，缓存 **真实占格** 验证过的文件夹原生矩形。4×2 模式不再将其裁成中央正方形。
3. `iconAtPoint:index:` 经过系统原生命中调用后，如果命中占位图标，优先使用同一列表、同一 UID、同一坐标的前置缓存文件夹，避免仅因 drag 过程中的临时小缩略图就拒绝。
4. 悬停反馈接受系统实际报告的 `UIDropOperationCopy`，不再要求只有 Move 才显示反馈。
5. Native drop 结束后的受保护兜底，按 UID 重新找到真实根列表中的文件夹和来源 App；只在本次已验证区域发生放入操作、且文件夹尚未包含 App 时调用 iOS 17.1.1 已证实存在的原生 manager 接口。

## 已知未解决与风险
- 旧版打开/退出文件夹时缩略图短暂缩小/叠影：本版未更改 `FXInterface.mm` / `FXTransition.xm`，以免把拖放修复与不相干的显示补丁混在一起。这个问题还需单独处理。
- 原生 drop 回调的成功执行 **不代表** 原生 folder add 被执行。本版本的补救仍可能因模型/坐标/设备私有方法语义被拒绝。
- 即使 `SBHIconManager` 方法名称存在，也不等于在所有 SpringBoard 编辑状态都可以安全直接调用；当前调用会导致桌面列表重排，应在有空格的测试页测试，必须保留旧安装包和布局备份。
- 无 iOS 真机及 Theos 编译环境。仅运行了静态结构验证，**不可称为稳定版**。

## 测试顺序
- 先确认原本 4×2 调整功能仍可用；
- 在空白测试页尝试 2×2 和 4×2 文件夹各拖入一个普通 App，观察是否真的在文件夹内部出现；
- 打开/关闭文件夹，单独记录转场 bug 是否仍然出现；
- 如果 SpringBoard 重启、App 位置异常，立即恢复原版，停止继续测试。
