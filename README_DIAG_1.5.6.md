# FolderX 1.5.6~diag1 — 诊断构建说明

**这一版不改任何行为逻辑。** 只做两件事：让它第一次真正编译通过，以及在既有分支上加可观测点。

## 编译修复（此前从未编译过）

| 位置 | 错误 | 修法 |
|---|---|---|
| `FXDrop.xm` `dragInteraction:itemsForBeginningSession:` | Logos hook 里 `SBIconView` 只是前置声明，`self.window` 报 property not found | 改走 `((UIView *)self).window` |
| `FXTransition.xm` | 新增的 `static char kFXDiagKey` 未使用，`-Werror` 直接失败 | 删除 |

产物为 **arm64e (PAC00)** 的可安装包。

## 诊断通道

- 路径：`/var/mobile/Library/Logs/FolderX/fx-diag.log`
- 上限 3 MB，超出时滚动为 `fx-diag.log.old`（只保留一代）
- 写盘在独立的 utility 串行队列，不占主线程
- **本版默认开启**；关闭方式二选一：
  - 建空文件 `/var/mobile/Library/Logs/FolderX/off`
  - `defaults write com.huhansibuxin.folderx.fresh DiagnosticsEnabled -bool NO`

### 记录内容（只有类名、几何、分支判定，不含 App / 文件夹标识）

| 前缀 | 何时 | 关键字段 |
|---|---|---|
| `PROBE` | 首次见到原生图标视图 | 实际类名、视图链、`setIconGridImageAlpha:` / `iconGridImageAlpha` / `disableImageUpdatesForReason:` / `invalidateImageUpdatesAssertion:` / `pageGridContainer` 是否存在及签名 |
| `host/<ptr>` | 状态变化时（非每帧） | sizeClass、宿主宽高、原生 image 类与 bounds、`match` `settled` `overlay` `pinned` `suppress` `drag` `open`、格子数、网格父视图类 |
| `thumb/<cls>` | 压制入口状态变化 | hide、touched、锁选择器/透明度 setter 是否存在 |
| `alpha/<cls>` / `alphaMissing` | 透明度压制判定 | needs / compat / getter / 观测值 / 期望值 / 是否重入 / 参数类型 |
| `page/<cls>` | 原生九宫格页容器 | found、hide、当前 opacity |
| `open.prepare` | 点击空白开合前 | size、格子数、网格父视图 |
| `presentation` | 原生呈现状态切换 | active / was / 已知宿主数 |
| `ctrl.*` / `mgr.*` | 文件夹控制器与管理器回调 | 开合顺序、closePending / closeFinished |
| `tap.app` / `tap.passthrough` | 点击命中 / 穿透 | host、命中索引、手势状态 |

## 建议的采集步骤

1. 装本版，**完全重启 SpringBoard**（`killall -9 SpringBoard` 或 respring）。
2. 打开一个大文件夹（2×2 或 4×2），关闭；重复 5 次，其中至少 1 次"打开后立刻关"。
3. 拖一个普通 App 到大文件夹附近，悬停 2 秒再移开；然后再拖一次并真正松手。
4. 取日志：
   ```
   cat /var/mobile/Library/Logs/FolderX/fx-diag.log
   ```
   或 Filza 打开同一路径。

预期看什么：如果叠影时 `alpha/*` 显示 `compat=0` 或整段是 `alphaMissing`，说明真机上根本没有可用的透明度压制选择器 —— 那 1.5.0→1.5.5 一直换策略是找错了着力点，要换到截图快照层。如果 `alpha` 显示 `compat=1 needs=1` 却仍叠影，则是压制时机被 SpringBoard 的后续重绘覆盖，需要改重述时机而不是选择器。

## 未改动（保持 1.5.5 现状）

- 整页拖动策略 Hook 仍然不安装
- 无蓝色光圈
- 4×2 命中、模型尺寸、2×6 显示未动
- 开合转场本身未动