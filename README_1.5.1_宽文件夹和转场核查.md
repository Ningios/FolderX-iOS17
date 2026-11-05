# FolderX 1.5.1：内部 12 图标读取与开合叠影排查

## 本版已经修改（静态源码修正）

- `FXCore.mm / FXFolderApps`：先按 SpringBoard 文件夹实际页顺序读取 `listAtIndex:` 的 `icons`，再用 `allIcons` / `icons` 兜底补齐；去重、上限 12。此前只要 `allIcons` 返回一个有效的九图标数组，就不会读取第二页，造成 4×2 外框仍只有九个图标。
- `FXInterface.mm / FXPreviewColumns`：优先使用原生 size class 或真实 4×2 grid range；在范围读取不到时才结合已存尺寸和真实宽视图判定 2 行 6 列。避免切换中错误地变成 3×3。
- 未修改 `FXDrop.xm`、`FXListHit.xm`、`FXTransition.xm`、`Tweak.xm`、尺寸手势。

说明：4×2 是**主屏幕占格**，内部预览按已有设计为**2 行 × 6 列 = 12 个 App**。正常情况下没有 App 的空位不绘制假的 App 图标。如果文件夹已有 12 个以上，预览只展示前 12 个，完整内容仍在系统原生文件夹界面。

## 点击、打开、关闭时仍有叠影——尚未验证解决

此前 1.4.8 / 1.4.9 / 1.5.0 多次修改开合时机均未让用户真机恢复正常。当前 `SBFolderIconImageView` 中同时可能出现系统 `pageGridContainer`、合成 `iconGridImage` 和原生 `crossfadeScalingView` / `crossfadeFolderView`；仅仅保持 `FXMiniGrid` 在一个父视图里并不能阻止其他原生预览参加动画。

本版不再以新的猜测直接修改 SpringBoard 开合动画，避免破坏目前已能工作的拖入、4×2 占格和启动流程。附带 `folderx_transition_probe.js`，能在打开、关闭期间记录系统层级与 alpha，便于确认具体是哪两层重叠。**脚本仅观察**；Frida 注入 SpringBoard 仍有稳定性风险。

## 验收

1. 备份布局，在测试文件夹中放入至少 12 个 App（不方便时先不测）。验证 4×2 外框是否显示 2×6 共 12 个图标，最后 3 个可点击；完整内容以原生打开界面为准。
2. 检查普通 2×2 仍显示最多 3×3。
3. 若开合仍有重叠，请不要反复安装试验性补丁，先取得转场层日志，再据具体重叠层做修改。
4. 如遇 SpringBoard 异常，回退上一版。

**状态**：源码结构和 ZIP 静态检查，不等于 Theos 编译成功或 iOS 17.1.1 真机运行成功。
