# 子会话输入隔离探针
#
# 由主桌面通过临时计划任务 + RunEx(TASK_RUN_USE_SESSION_ID) 投进子会话执行。
#
# 证明两件事：
#   1. 进程在子会话里调用 SetCursorPos / SendInput，移动的是「子会话自己的光标」；
#   2. 主桌面的光标位置与前台窗口不受影响。
#
# 结果同时写到 <Out>.json，主桌面读文件即可判断。

param(
    [string]$Out = "$env:TEMP\dsh-clone\input-probe.json"
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DshInputProbe
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT
    {
        [FieldOffset(0)] public uint type;
        [FieldOffset(4)] public MOUSEINPUT mi;
    }

    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);

    public static string CursorAt()
    {
        POINT p;
        GetCursorPos(out p);
        return p.X + "," + p.Y;
    }

    public static string MoveCursor(int x, int y)
    {
        bool ok = SetCursorPos(x, y);
        return ok ? CursorAt() : "SETCURSORPOS_FAILED";
    }

    public static string ClickAt(int x, int y)
    {
        if (!SetCursorPos(x, y)) return "SETCURSORPOS_FAILED";

        var inputs = new INPUT[2];
        inputs[0].type = 0;
        inputs[0].mi.dwFlags = 0x0002; // MOUSEEVENTF_LEFTDOWN
        inputs[1].type = 0;
        inputs[1].mi.dwFlags = 0x0004; // MOUSEEVENTF_LEFTUP

        uint sent = SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
        return sent + "@" + CursorAt();
    }

    public static string ForegroundInfo()
    {
        IntPtr h = GetForegroundWindow();
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return h.ToInt64() + "/" + pid;
    }

    public static string ScreenSize()
    {
        return GetSystemMetrics(0) + "x" + GetSystemMetrics(1);
    }
}
'@ -Language CSharp

$process = Get-Process -Id $PID
$screen = [DshInputProbe]::ScreenSize()

$cursorBefore = [DshInputProbe]::CursorAt()
$foregroundBefore = [DshInputProbe]::ForegroundInfo()

# 挪到右下角附近，避免与 0,0 重合导致"没动"的假象
$targetX = [int]([DshInputProbe]::ScreenSize().Split('x')[0]) - 60
$targetY = [int]([DshInputProbe]::ScreenSize().Split('x')[1]) - 60

$cursorAfterMove = [DshInputProbe]::MoveCursor($targetX, $targetY)
$clickResult = [DshInputProbe]::ClickAt($targetX, $targetY)
$cursorAfterClick = [DshInputProbe]::CursorAt()
$foregroundAfter = [DshInputProbe]::ForegroundInfo()

$directory = Split-Path -Path $Out -Parent
if ($directory -and -not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

[ordered]@{
    sessionId        = $process.SessionId
    processId        = $PID
    screen           = $screen
    target           = "$targetX,$targetY"
    cursorBefore     = $cursorBefore
    cursorAfterMove  = $cursorAfterMove
    clickSendResult  = $clickResult
    cursorAfterClick = $cursorAfterClick
    foregroundBefore = $foregroundBefore
    foregroundAfter  = $foregroundAfter
    timestamp        = (Get-Date).ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath $Out -Encoding UTF8
