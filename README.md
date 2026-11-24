# dsh-desktop-clone

**让 DeepSeek Harness 在一个独立、可见、可接管的 Windows 桌面里操作程序，而不是抢用户的鼠标。**

> **状态：已打包为可安装的 DSH bundle，工具面全链路实测通过。**
>
> 已验证：`desktop_clone_start` / `status` / `screenshot` / `click` / `cursor` /
> `type_text` / `stop`。桌面 1920×1080，抓帧方式 `bitblt`（无合成时自动回退
> `PrintWindow` 合成）。
>
> **前置条件**：非家庭版 Windows；首次需打开远程桌面
> （`HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\fDenyTSConnections = 0`，
> 需管理员，一次性）。若子会话停在登录界面无法完成登录，通常是
> 「仅允许对此设备上的 Microsoft 帐户使用 Windows Hello 登录」被开启
> （`DevicePasswordLessBuildVersion = 2`）；BetterGI 对此有同样的告警。

---

## 为什么需要它

DSH 现有的桌面操控走 `SetCursorPos` + `SendInput`，操作期间物理鼠标会被挪走。
隐藏桌面（`CreateDesktopW`）能隔离输入，但 DWM 不合成非活动桌面，Chromium / Electron
这类自绘应用抓不到画面。

本项目的做法和 [BetterGI](https://github.com/babalae/better-genshin-impact) 的「桌面分身」一致：
**用本机 RDP 建一个 Windows 子会话**，在那个会话里跑一个 agent。会话内的
`SendInput` / `SetCursorPos` 只作用于该会话自己的输入队列和光标，物理鼠标一格不动。

与 BetterGI 的差别：不依赖 BetterGI，自己宿主 `mstscax`（`MsRdpClient10`）并调用
`IMsRdpExtendedSettings::ConnectToChildSession`；缩放跟随系统 DPI 而不是固定 100%。

---

## 工作原理

```
主桌面 (DSH 进程)                         子会话 (独立 Windows session)
├─ clone-host.ps1                        └─ clone-agent.ps1
│   ├─ AxHost 宿主 MsRdpClient10             ├─ 真实指针/键盘 (SendInput)
│   ├─ ConnectToChildSession = true          ├─ 整屏抓帧 (BitBlt)
│   └─ 一个可看可点的窗口                     └─ TCP 127.0.0.1 控制通道
└─ 临时计划任务 + RunEx(TASK_RUN_USE_SESSION_ID)
    └─ 把 agent 投进子会话
```

关键调用（全部经实测）：

| 步骤 | 做法 |
|---|---|
| 建会话 | `IMsRdpExtendedSettings.set_Property("ConnectToChildSession", true)` 后 `Connect()`。**不需要密码**，走当前交互用户令牌 |
| 读会话号 | `WTSGetChildSessionId()`；`0xFFFFFFFF` 表示没有 |
| 投放进程 | 临时计划任务 `RunLevel=0` + `RunEx(..., 0x4 /*TASK_RUN_USE_SESSION_ID*/, sid, ...)`。**非提权可用** |
| 防压扁 | 16:9 必须锁在 **RDP 控件**上，不是窗体客户区（菜单栏/状态栏会吃掉高度） |
| 跟随 DPI | 进程先 `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`，**再** `GetDpiForSystem()`；否则永远读到 96 |

---

## 已验证的结论

在一台 Windows 11 专业版（build 26300，主显示 125% 缩放）实机验证：

| 能力 | 结果 |
|---|---|
| 自建子会话 | ✅ 约 1 秒连上，无需密码 |
| 窗口可见、可随时接管 | ✅ 普通窗口，能点能打字 |
| 非提权投放进程进会话 | ✅ `RunLevel=0` + `RunEx(0x4)` |
| 会话内真实指针输入 | ✅ 主桌面光标 `700,521` 前后完全一致 |
| 会话内整屏抓帧 | ✅ `1920×1080` PNG，DWM 合成窗口也能抓到 |
| 跨会话传结果 | ✅ 同用户同文件系统，直接落盘 |
| 常驻 agent + TCP 控制面 | ✅ handshake / ping / screenshot / click / shutdown |

未被吞并的验证：单实例应用（如 Tauri/Electron 写的终端）在主桌面已运行时，
即使在副本路径启动也**会立刻退出**并被重定向到已有实例 —— 详见下方限制。

---

## 文件

```
host/
  DshRdpAxHost.cs     MsRdpClient10 的 AxHost 宿主 + IMsRdpExtendedSettings
  clone-host.ps1      宿主运行时（待从 probe/rdp-host-ux.ps1 正式化）
  clone-agent.ps1     会话内 agent：抓帧、指针、TCP 控制通道
probe/
  rdp-host-ux.ps1     带完整体验层的宿主（位置记忆/缩放/置顶/静音/观看模式/状态栏）
  capture-session.ps1 会话内抓帧探针
  input-isolation.ps1 输入隔离探针
  start-hidden.vbs    无控制台启动器（PS 5.1 会弹黑窗）
  DshRdpAxHost.cs     宿主控件源码
```

> 所有 `.ps1` **必须存为 UTF-8 带 BOM**。Windows PowerShell 5.1 会按 ANSI 读无 BOM 的
> `.ps1`，中文会变成乱码。

---

## 快速试一下

```powershell
# 1) 确保远程桌面已开启（一次性，需管理员）：fDenyTSConnections = 0
# 2) 启动宿主
cscript //nologo probe\start-hidden.vbs
# 3) 窗口出现后，用 WTSGetChildSessionId 可拿到会话号
```

---

## 已知限制- **需要非家庭版 Windows**：子会话依赖 `WTSEnableChildSessions` 与本机 RDP。
- **首次需打开远程桌面**（`HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\fDenyTSConnections = 0`，需管理员）。之后保持开启即可。
- **分身存活期间不能正常重启/关机**；崩溃时用「任务管理器 → 用户 → 注销」。
- **单实例软件无法隔离**：Chrome、微信、以及 Tauri/Electron 终端等已在主桌面运行时，
  启动会被吞并到已有实例，窗口仍出现在主桌面。需先关闭该应用。
- **分辨率与缩放只在新建会话时生效**：`ConnectToChildSession` 对已存在的子会话是「附着」，
  改不动尺寸；更换参数必须先 `WTSLogoffSession`。
- **与 rdpwrap / SuperRDP 冲突**：这类工具接管 `termsrv.dll`，本项目要求原生 DLL。
- **DPI 必须全链路一致**：宿主、agent 都要 per-monitor aware，否则坐标会差一个缩放倍数。
- 不支持相对鼠标移动、多显示器、分身内提权。

---

## 待办

- [ ] 把 `probe/rdp-host-ux.ps1` 正式化为 `host/clone-host.ps1`（含断线重连、退出注销）
- [ ] agent 接入 UIA / OCR 引擎（目前只有坐标点击与抓帧）
- [ ] MCP server + `desktop_clone_*` 工具面
- [ ] 打包为可安装的 DSH bundle

---

## 排障记录（全部为实测结论）

搭通过程中踩到的坑，按出现顺序记录，避免重踩：

| 现象 | 根因 | 修法 |
|---|---|---|
| `CLONE_TIMEOUT` | 宿主由 Node `spawn`，落在 DSH 的 job object 里，一创建窗口就被连带回收 | 改为脱离本进程树启动 |
| 尺寸/缩放全不对（1280×720 变 1602×940、DPI 读到 96） | 进程 DPI-unaware，`GetDpiForSystem` 恒返回 96 | 启动时先 `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`，再读 DPI |
| `0x80070002 系统找不到指定的文件` | `WTSGetChildSessionId` 会返回**已注销会话的陈旧 id** | 用「会话内是否还有进程」交叉校验，陈旧即视为无会话 |
| `ArgumentException: 值不在预期的范围内` | `RunEx(sessionId)` 在会话**尚未完成登录**时被拒 | 等会话就绪（有 explorer 或进程数达标）再注入，并对该错误重试 |
| `AGENT_TIMEOUT`（文件明明写了） | PS 5.1 的 `Set-Content -Encoding UTF8` 带 BOM，Node 侧 `JSON.parse` 遇 `\uFEFF` 抛错被吞 | 读时剥 BOM、写时用无 BOM 编码 |
| agent 启动即退出、无握手 | `.ps1` 丢 UTF-8 BOM，PS 5.1 按 ANSI 读中文注释导致**语法错误** | 所有 `.ps1` 强制 UTF-8 with BOM，并用 `Parser::ParseFile` 校验 |
| 宿主 `RDP：未连接`、子会话 0 进程 | 宿主由**计划任务**拉起时 RDP ActiveX 始终连不上 | 改用 `explorer.exe` 打开 `.vbs` 启动器：挂在用户 shell 下，正常交互上下文，实测 9 秒连上 |
| `type` 返回 `sent: 0` | 自写的 `INPUT` 结构体偏移错（union 在 x64 从偏移 8 开始，且 `cbSize` 必须为 40） | 统一为 `[StructLayout(Explicit, Size=40)]`，MOUSEINPUT / KEYBDINPUT 共用 |

抓帧同理：`BitBlt` 只在会话有活跃 RDP 客户端、正在合成时有效；失败或整片同色时自动回退到
`PrintWindow` 逐顶层窗口按 z 序合成。

## 许可

MIT。

桌面分身的实现思路参考了 [BetterGI](https://github.com/babalae/better-genshin-impact)
的桌面分身功能（GPL-3.0）。详见 [THIRD_PARTY.md](THIRD_PARTY.md)。
