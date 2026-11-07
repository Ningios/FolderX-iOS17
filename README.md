# FolderX Fresh 1.5.20 — App 启动崩溃紧急修复

本工程以 **1.5.16** 为基线，保留此前已确认正常的普通 App 拖动保护、大文件夹拖动保护和 3D Touch“禁止进入文件夹”。

**不包含 1.5.17 三项没有奏效的实验修改**（跨页任意组合的临时模型扩展、1×1 小文件夹防上移、静态预览开合隐藏）。

本次针对 v19/v20 真机启动对照日志：为 FolderX 迷你网格内部 App 启动构建原生 `SBIconLaunchContext`（含 SpringBoard 生成的 `_activationSettings` 与真实图标宿主）；获取失败则走 LaunchServices 备用路线，绝不再以 nil context 调用 native launch。保留 1.5.18 的字符串 location 防崩溃修复。

- 不改变 2×2、4×2 文件夹的真实模型占格与外框；不强制改 1×1。
- 不增加新的 SpringBoard Hook；不碰桌面重排逻辑。
- 仅修复已由崩溃堆栈确认的非法参数。此前的跨页缩小、图标重叠及可能存在的启动黑闪 **并未宣称全部解决**。
- 必须先备份图标布局，并在有回退方法的环境中测试。此为源码包，未经 Theos 编译或设备测试。

参见 `README_1.5.20_启动崩溃修复.md` 和 `TEST_1.5.20_启动安全回归.md`。


### 1.5.20 (open/close transient preview only)

See `README_1.5.20_开合临时预览保护.md`. App launching, folder model, drag logic and menu remain from the confirmed-working 1.5.19.
