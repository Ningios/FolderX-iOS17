# FolderX 1.5.19 — 启动上下文候选修复

## 用户真机证据

- v19/v20：普通桌面与原生文件夹 App 的启动上下文 `SBIconLaunchContext` 非空、`_activationSettings` 有内容，`WORKSPACE_ACTIVATE` 是 `SBDeviceApplicationSceneEntity`。
- v19/v20：FolderX 自定义预览点击的 `context=nil`，得到 `SBActivationSettings (empty)`、`WORKSPACE_ACTIVATE entity=nil`，即使方法正常返回也未实际打开 App。
- 原先 1.5.17 用 `@(1)` 作 location 曾造成 `NSInvalidArgumentException`，不能恢复。

## 本版只修改启动逻辑

1. `FXMiniGrid` 在点击叶子 App 时把真实宿主 `SBIconView` 传入 `FXLaunchApp(app, host)`。
2. 通过原生 `SBIconController`（或 `iconManager`）的 `launchActivationSettingsForIconView:` 获取真正的 `SBActivationSettings`，检查对象类型和非空状态。
3. 仅当设备上的 `SBIconLaunchContext` 确实存在 `_activationSettings` 和 `_iconView` 这两个对象字段时，以经验证的字段构建上下文。
4. 如果任一条件不满足，不执行 `context=nil` 的原生启动，而是走原有的异步 `LSApplicationWorkspace` 备用路径。

### 风险与限制

- **未在用户真机上验证** `launchActivationSettingsForIconView:` 对“文件夹宿主视图”能否返回适用于叶子 App 的设置；即使非空，也不保证第三方启动动画完全一致。
- 如果设置获取失败，备用路径可能仍然有启动速度或动画差异；这是避免无效原生启动的安全降级。
- 本版不修改模型、位置、frame、拖放、3D Touch 菜单、文件夹尺寸和转场隐藏逻辑。
- 从 1.5.18 基线制作，没有重新加入 1.5.17 已经失败的三项实验。

## 建议真机测试

1. 保留 1.5.18 安装包和桌面布局备份；退出 Frida。
2. 点击大文件夹内部 App 一次，确认启动、不黑屏、不进入安全模式。
3. 与原生文件夹 App 点击对比；若失败，保留崩溃日志、终端输出或用 v19 观察是否还有 `(empty)`。
4. 再分别验证普通 App 拖动、大文件夹拖动、禁入开关和右下角改尺寸。
