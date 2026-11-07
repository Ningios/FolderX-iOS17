# SpringBoard 安全模式崩溃原因与修复

## 崩溃证据

- 文件：`SpringBoard-2026-11-06-214334.ips`（未打包入工程）。
- iPhone OS 17.1.1；主线程；`NSInvalidArgumentException` / `SIGABRT`。
- 异常：`-[NSConstantIntegerNumber isEqualToString:]: unrecognized selector`。
- 调用栈：`FXHandleFolderTap` → `FXLaunchApp` → `SBIcon launchFromLocation:context:` → `SBApplication icon:launchFromLocation:context:` → `SBUIController transitionSourceForIcon:iconLocation:`。

## 原因

原先 `FXLaunchApp` 使用 `call(leafIcon, nativeLaunch, @(1), nil);`。虽然 Runtime Signature 表示对象参数 `@`，但不能证明类型为 `NSNumber`；SpringBoard 17.1.1 在后续启动动画中把位置当成字符串对象使用，发消息 `isEqualToString:` 导致崩溃。

## 修改

调用时传入 `@"SBIconLocationFolder"` 而不是数字。它是文件夹内图标使用的位置字符串标识。方法仍通过 Runtime 签名检查，未增加其他 Hook，不修改 App 数据、文件夹占格或主屏布局。

## 修复范围及剩余风险

这能针对崩溃日志中已经确认的非法位置参数根因提供修复；尚未在真机确认启动时是否仍有短暂黑屏。`LSApplicationWorkspace` 后备调用路径仍保留原样，因为安全模式这次发生在原生转场路径，不能用未知的私有调用替代。

1.5.17 三项无效的布局/转场实验被撤回（基线选用 1.5.16）。跨页缩小和开合/跨页重叠仍是待修项目，不能宣称已解决。

## 测试

1. 先关闭 Frida，并保留 1.5.16 的可回退安装包及桌面布局备份。
2. 安装或编译 1.5.18 后，先点击大文件夹的一个普通 App（最好选择可快速启动的 App），确认不会进入安全模式。
3. 反复点击不同 App，并与普通桌面图标启动比较黑屏/启动时间。
4. 最后核验普通 App 拖动、文件夹拖动、禁止进入开关、右下角调整尺寸及 4×2/2×2 占格。
5. 如果仍崩溃，附上**新**的 `.ips` 报告；不同栈的崩溃不能自动归于本次已修复参数。
