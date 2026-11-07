## 1.5.15 focused tests

1. Back up Home Screen layout and retain your known-good 1.5.14 package.
2. In 3D Touch enable **禁止进入文件夹** on a verified large folder; without any active drag, tap its blank area. It should NOT open; internal App direct launch must still work.
3. Drag an App over the blocked folder and release to test the native drop path; because spring-opening is now suppressed, verify it still accepts the icon. Toggle the option off to confirm ordinary opening returns.
4. Drag a large folder and confirm the 1.5.14 fix remains.
5. If a cross-page drag still reduces a verified 2x2/4x2 to a 60x74 view, run `folderx_layout_caller_probe_v11_light.js` on that exact target page; send FXCALL11 lines. This release purposely does not force frames.
6. Do not use the old v9 continuous scanner for this test; the v11 probe attaches only during the drag.

# FolderX 1.4.7 真机验收（未在本环境执行）

**前置条件：** 先备份旧 1.4.6 的 DEB 和桌面布局；找一个还有空位的测试页，准备普通 App 与测试文件夹。不要在满屏主页上测试扩容。所有操作先测试一次，不要连续高速拖动。

1. **尺寸功能回归**：编辑模式右下角由 1×1 → 2×2 → 4×2，及逆向切换；检查 4×2 显示 2 行 × 6 列，背景、点击 App、长按菜单正常。
2. **拖动时外观**：把一个 App 从远处拖向 2×2 文件夹，中途悬停、移开、再悬停；2×2 文件夹及邻近 4×2 文件夹在整个过程中应保持原大小，允许边缘出现轻微描边，但不应出现 1×1 缩略图。分别对 4×2 再测试一次。
3. **拖入后行为**：松手时观察 App 有没有**先回原位**。目标是原生入夹流程直接接管预览；如还是回原位后才消失，说明 manager 早期交接尚未接入真正原生 drag-preview destination，不能算修复完成。至少应确认 App 最终位于目标文件夹，桌面没有副本。
4. **取消拖动**：拖到文件夹上再移走取消，App 必须保持原位，不得自动入夹，文件夹显示必须恢复正常。
5. **开合转场**：打开一个大文件夹，关闭返回桌面，循环 10~20 次；检查周围大文件夹没有缩小、当前文件夹内部图标不重叠、不变形、没有短暂小图标闪现。分别测试原生点开文件夹空白区、直接点击内部 App、长按菜单预览。
6. **安全与回退**：如果出现 SpringBoard 崩溃、App 重复、图标失踪、文件夹尺寸变成错误占格等任何情况，停止测试，回到已验证可用的 1.4.6，先检查系统图标布局。

**通过标准：** 以上全部通过才可称为稳定。源码静态测试 PASS 不代表这些真机测试通过。
