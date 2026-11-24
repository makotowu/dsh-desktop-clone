# DSH 桌面分身 —— 会话内 agent
#
# 被主桌面通过临时计划任务 + RunEx(TASK_RUN_USE_SESSION_ID) 投进子会话后常驻运行。
# 在子会话里它拥有自己的真实桌面、真实指针和键盘，所以这里的 SendInput/SetCursorPos
# 只影响分身，不会碰到用户主桌面。
#
# 协议：TCP 127.0.0.1:<Port>，每行一个 JSON 请求，回一行 JSON。
#   {"id":1,"cmd":"ping"}
#   {"id":2,"cmd":"screenshot","args":{"path":"C:\\...\\shot.png"}}
#   {"id":3,"cmd":"click","args":{"x":100,"y":200,"doubleClick":false}}
#   {"id":4,"cmd":"type","args":{"text":"hello"}}
#   {"id":5,"cmd":"cursor"}
#   {"id":6,"cmd":"shutdown"}
#
# 抓帧策略（按可靠性降级）：
#   1. BitBlt 屏幕 DC —— 会话有活跃 RDP 客户端、正在合成时最准；
#   2. 若 BitBlt 失败或结果整片同色，改用 PrintWindow 逐顶层窗口按 z 序合成。
#      子会话没有客户端连接时桌面不再合成，只有这条路还能拿到画面。
#
# 本文件必须存为 UTF-8 带 BOM（PS 5.1 会按 ANSI 读无 BOM 的 .ps1）。

param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$StateFile
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class CloneAgentNative
{
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleBitmap(IntPtr hDC, int w, int h);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hDC, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int rop);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hDC);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr param);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

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

    // Win32 的 INPUT 在 x64 上是 40 字节：DWORD type 之后，union 按指针对齐从偏移 8 开始。
    // 落成两个显式布局会各自算错 cbSize，SendInput 直接返回 0（于是 type 一个字符都发不出去）。
    // 用一个 Size=40 的显式结构同时覆盖 MOUSEINPUT(8..40) 与 KEYBDINPUT(8..32)。
    [StructLayout(LayoutKind.Explicit, Size = 40)]
    public struct INPUT
    {
        [FieldOffset(0)] public uint type;

        [FieldOffset(8)] public MOUSEINPUT mi;

        [FieldOffset(8)] public ushort wVk;
        [FieldOffset(10)] public ushort wScan;
        [FieldOffset(12)] public uint dwFlags;
        [FieldOffset(16)] public uint time;
        [FieldOffset(24)] public IntPtr dwExtraInfo;
    }

    private const int SRCCOPY = 0x00CC0020;
    private const uint PW_RENDERFULLCONTENT = 0x2;
    public delegate bool EnumProc(IntPtr hWnd, IntPtr param);

    public static string CaptureScreen(string path)
    {
        int width = GetSystemMetrics(0);
        int height = GetSystemMetrics(1);
        IntPtr screen = GetDC(IntPtr.Zero);
        if (screen == IntPtr.Zero) return "GETDC_FAILED";

        IntPtr mem = CreateCompatibleDC(screen);
        IntPtr bmp = CreateCompatibleBitmap(screen, width, height);
        IntPtr old = SelectObject(mem, bmp);
        bool ok = BitBlt(mem, 0, 0, width, height, screen, 0, 0, SRCCOPY);
        SelectObject(mem, old);

        string result;
        try
        {
            using (Image image = Image.FromHbitmap(bmp))
            {
                if (ok && !IsUniform(image))
                {
                    image.Save(path, ImageFormat.Png);
                    return "bitblt";
                }
            }

            // BitBlt 成功但整片同色 = 桌面没有在合成，退到 PrintWindow 合成。
            result = CaptureComposite(path);
        }
        finally
        {
            DeleteObject(bmp);
            DeleteDC(mem);
            ReleaseDC(IntPtr.Zero, screen);
        }

        return result;
    }

    public static string CaptureComposite(string path)
    {
        int width = GetSystemMetrics(0);
        int height = GetSystemMetrics(1);

        var handles = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr param)
        {
            if (IsWindowVisible(hWnd)) handles.Add(hWnd);
            return true;
        }, IntPtr.Zero);

        using (var canvas = new Bitmap(width, height))
        {
            using (var graphics = Graphics.FromImage(canvas))
            {
                graphics.Clear(Color.Black);

                // EnumWindows 是自顶向下，合成要自底向上。
                handles.Reverse();
                int drawn = 0;

                foreach (IntPtr hWnd in handles)
                {
                    RECT rect;
                    if (!GetWindowRect(hWnd, out rect)) continue;
                    int w = rect.Right - rect.Left;
                    int h = rect.Bottom - rect.Top;
                    if (w <= 0 || h <= 0 || w > 16384 || h > 16384) continue;

                    using (var window = new Bitmap(w, h))
                    {
                        bool captured = false;
                        using (var windowGraphics = Graphics.FromImage(window))
                        {
                            IntPtr hdc = windowGraphics.GetHdc();
                            try
                            {
                                captured = PrintWindow(hWnd, hdc, PW_RENDERFULLCONTENT);
                            }
                            finally
                            {
                                windowGraphics.ReleaseHdc(hdc);
                            }
                        }

                        if (!captured) continue;
                        graphics.DrawImage(window, rect.Left, rect.Top);
                        drawn++;
                    }
                }

                canvas.Save(path, ImageFormat.Png);
                return "composite:" + drawn;
            }
        }
    }

    private static bool IsUniform(Image image)
    {
        using (var small = new Bitmap(image, new Size(32, 32)))
        {
            Color first = small.GetPixel(0, 0);
            for (int y = 0; y < 32; y += 3)
            {
                for (int x = 0; x < 32; x += 3)
                {
                    Color c = small.GetPixel(x, y);
                    if (Math.Abs(c.R - first.R) > 6 || Math.Abs(c.G - first.G) > 6 || Math.Abs(c.B - first.B) > 6)
                    {
                        return false;
                    }
                }
            }
        }

        return true;
    }

    public static string Cursor()
    {
        POINT p;
        GetCursorPos(out p);
        return p.X + "," + p.Y;
    }

    public static string Click(int x, int y, bool doubleClick)
    {
        if (!SetCursorPos(x, y)) return "SETCURSORPOS_FAILED";

        int count = doubleClick ? 4 : 2;
        var inputs = new INPUT[count];
        for (int i = 0; i < count; i++)
        {
            inputs[i].type = 0;
            inputs[i].mi.dwFlags = (i % 2 == 0) ? 0x0002u : 0x0004u;
        }

        uint sent = SendInput((uint)count, inputs, Marshal.SizeOf(typeof(INPUT)));
        return sent + "@" + Cursor();
    }

    /// <summary>Unicode 键盘输入：不依赖焦点窗口的代码页，中文也能打。</summary>
    public static uint TypeText(string text)
    {
        uint sent = 0;
        int size = Marshal.SizeOf(typeof(INPUT));

        foreach (char ch in text)
        {
            var pair = new INPUT[2];

            pair[0].type = 1;                    // INPUT_KEYBOARD
            pair[0].wVk = 0;
            pair[0].wScan = ch;
            pair[0].dwFlags = 0x0004;            // KEYEVENTF_UNICODE

            pair[1].type = 1;
            pair[1].wVk = 0;
            pair[1].wScan = ch;
            pair[1].dwFlags = 0x0004 | 0x0002;   // + KEYEVENTF_KEYUP

            sent += SendInput(2, pair, size);
        }

        return sent;
    }
}
'@ -ReferencedAssemblies System.Drawing

# DPI 一致性：必须在读取任何尺寸之前设为 per-monitor aware。
# 不设的话，GetSystemMetrics/GetCursorPos 返回的是被系统缩放虚拟化后的值，
# 而 UIA 在 aware 进程里给的是物理像素 —— 两套坐标混用会表现为"点偏了"。
try {
    [void][CloneAgentNative]::SetProcessDpiAwarenessContext([IntPtr](-4))
} catch { }

$process = Get-Process -Id $PID

# 握手文件必须写成「UTF-8 无 BOM」：Set-Content -Encoding UTF8 在 PS 5.1 上会加 BOM，
# 读到那一侧的 JSON.parse 会直接抛错，表现为「文件写了但对方一直说没收到」。
$stateJson = [ordered]@{
    port      = $Port
    token     = $Token
    processId = $PID
    sessionId = $process.SessionId
    screen    = "$([CloneAgentNative]::GetSystemMetrics(0))x$([CloneAgentNative]::GetSystemMetrics(1))"
    startedAt = (Get-Date).ToString('o')
} | ConvertTo-Json
[System.IO.File]::WriteAllText($StateFile, $stateJson, (New-Object System.Text.UTF8Encoding($false)))

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()

$running = $true

while ($running) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $writer = New-Object System.IO.StreamWriter($stream)
        $writer.AutoFlush = $true

        while ($client.Connected) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            $request = $null
            try { $request = $line | ConvertFrom-Json } catch { }
            if ($null -eq $request) {
                $writer.WriteLine((@{ ok = $false; error = 'BAD_JSON' } | ConvertTo-Json -Compress))
                continue
            }

            if ($request.token -ne $Token) {
                $writer.WriteLine((@{ ok = $false; id = $request.id; error = 'BAD_TOKEN' } | ConvertTo-Json -Compress))
                break
            }

            $response = [ordered]@{ ok = $true; id = $request.id; cmd = $request.cmd }

            try {
                switch ($request.cmd) {
                    'ping' {
                        $response.sessionId = (Get-Process -Id $PID).SessionId
                        $response.screen = "$([CloneAgentNative]::GetSystemMetrics(0))x$([CloneAgentNative]::GetSystemMetrics(1))"
                        $response.cursor = [CloneAgentNative]::Cursor()
                    }
                    'screenshot' {
                        $path = $request.args.path
                        $mode = [CloneAgentNative]::CaptureScreen($path)
                        $response.mode = $mode
                        $response.screen = "$([CloneAgentNative]::GetSystemMetrics(0))x$([CloneAgentNative]::GetSystemMetrics(1))"
                        $response.path = $path
                        $response.fileBytes = (Get-Item -LiteralPath $path).Length
                    }
                    'cursor' {
                        $response.cursor = [CloneAgentNative]::Cursor()
                    }
                    'click' {
                        $response.result = [CloneAgentNative]::Click([int]$request.args.x, [int]$request.args.y, [bool]$request.args.doubleClick)
                    }
                    'type' {
                        $response.sent = [CloneAgentNative]::TypeText([string]$request.args.text)
                    }
                    'shutdown' {
                        $response.bye = $true
                        $running = $false
                    }
                    default {
                        $response.ok = $false
                        $response.error = "UNKNOWN_CMD:$($request.cmd)"
                    }
                }
            } catch {
                $response.ok = $false
                $response.error = $_.Exception.GetBaseException().Message
            }

            $writer.WriteLine(($response | ConvertTo-Json -Compress))
        }
    } finally {
        $client.Close()
    }
}

$listener.Stop()
