# 桌面分身 / Desktop clone

在独立的 Windows 子会话里运行并操作程序。会话内的指针与键盘只作用于分身，
用户的物理鼠标不会被占用。

## 能力

- `desktop_clone_start` —— 创建（或附着）子会话，启动可见窗口与常驻 agent
- `desktop_clone_status` —— 连接状态、会话号、桌面尺寸、agent 端口
- `desktop_clone_screenshot` —— 分身整屏 PNG
- `desktop_clone_click` —— 分身内坐标点击（真实指针）
- `desktop_clone_type_text` —— 向分身当前焦点输入文本
- `desktop_clone_cursor` —— 分身内光标位置
- `desktop_clone_stop` —— 断开连接并注销子会话

## 前提

1. 非家庭版 Windows。
2. 首次需要打开远程桌面：`HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\fDenyTSConnections = 0`（需管理员，一次性）。
3. 首次运行会在你桌面出现一个窗口——那是分身画面，可随时用鼠标接管。

## 限制

- **分身存活期间不能正常重启/关机**。崩溃时用「任务管理器 → 用户 → 注销」。
- **单实例软件无法隔离**：Chrome、微信、Tauri/Electron 终端等已在主桌面运行时会被吞并。
- **分辨率与缩放只在新建会话生效**；已存在的会话是「附着」，改不动。
- 与 rdpwrap / SuperRDP 冲突（它们接管 `termsrv.dll`）。
- 不支持相对鼠标移动、多显示器、分身内提权。
