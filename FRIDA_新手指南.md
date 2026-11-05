# 用 Frida 帮助核对 FolderX 的 iOS 17.1.1 系统接口（新手版）

这份说明适用于你**自己的、已越狱的 iPhone**，以及安装了 Frida CLI 的 Windows / macOS / Linux 电脑。你不需要把电脑远程控制权或手机密码交给任何人。

**重要：ChatGPT 不能直接连接你本地的 Frida。** 你在电脑上运行脚本后，把文字输出发回聊天即可。首次只做**只读方法列表检查**：不拦截 SpringBoard 方法，不修改图标模型，不打印应用列表，也不把数据上传到第三方。

## 第一步：先确认手机与电脑能通信

1. 用**支持数据传输的 USB 线**连接手机和电脑；解锁手机，出现“信任此电脑”就选择信任。
2. 打开电脑终端（Windows 用 PowerShell，macOS 用“终端”）。输入：

   ```sh
   frida --version
   frida-ps -U
   ```

3. 如果命令出现进程列表，并且能找到 `SpringBoard`，说明已连接上。`frida-ps -U` 失败时，先不要运行后续命令：检查数据线、信任提示、越狱环境里 `frida-server` 服务是否正在运行，以及电脑端与手机端的 Frida 主版本是否兼容。只安装 Frida 客户端不等于手机端服务已经启动。

## 第二步：打印系统私有接口信息

将本压缩包内的 `folderx_probe.js` 放到你在终端当前所在的文件夹里（或直接在解压后的工程目录执行命令）。

**Windows PowerShell**，在工程目录中运行：

```powershell
frida -U -n SpringBoard -l .\folderx_probe.js
```

**macOS / Linux**：

```sh
frida -U -n SpringBoard -l ./folderx_probe.js
```

输出中应有 `[CLASS] SBIconView`、`[CLASS] SBIconListModel` 等条目，最后显示 `=== Probe complete ===`。按 `Ctrl+C` 退出。

建议把终端输出复制到一个 `folderx_probe_output.txt` 文件里，发到同一个 ChatGPT 聊天。**请发完整的命令错误或接口输出；不需要截图应用列表，不要分享设备口令和 SSH 密钥。**

如果无法附加 SpringBoard（`permission denied` / `process not found` 等），也把错误文本发来；不要自行关闭系统安全设置、开放 Frida 服务的公网端口或强制重启 SpringBoard。

## 第三步：这份数据能确认什么？

- `SBIconListModel` 在实际系统里究竟有没有占格变更接口，以及它的参数编码。
- 哪些类暴露 4×2 尺寸映射接口，可以为下一步**安全确认**真实的网格类型做准备。
- 文件夹转场、命中和拖放接收相关方法是否存在，避免继续依据猜测编写 Hook。

**这次脚本只列接口，不会猜测任何私有枚举值，也不会尝试 4×2 变更。** 拿到结果后，可以进一步设计有针对性的只读观察脚本；只有实机验证过的尺寸类型才应写入桌面占格数据库。

## 风险提醒

即便脚本本身只读，注入 SpringBoard 仍可能在不兼容的越狱/Frida 版本上触发重启或安全保护。请先备份桌面布局和可回退的旧 DEB。连接失败时停止，不要反复强制附加。
