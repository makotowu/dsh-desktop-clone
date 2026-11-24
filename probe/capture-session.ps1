# 子会话截图探针
#
# 由主桌面上的 DSH 插件通过临时计划任务 + RunEx(TASK_RUN_USE_SESSION_ID) 投进子会话执行。
# 作用：证明「在被投进的那个会话里，能拿到该会话真实桌面的整屏画面」。
#
# 关键前提：BitBlt 抓的是调用线程所在桌面的屏幕 DC。进程跑在子会话里，
# GetDC(NULL) 返回的就是子会话的显示表面，而不是主桌面的。
#
# 输出：<Out> 为 PNG，<Out>.json 为执行元数据。两个会话共享同一文件系统，所以结果直接落盘即可。

param(
    [string]$Out = "$env:TEMP\dsh-clone-shot.png"
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class DshSessionCapture
{
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleBitmap(IntPtr hDC, int w, int h);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hDC, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int rop);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hDC);

    private const int SRCCOPY = 0x00CC0020;

    public static string Capture(string path, out int width, out int height)
    {
        width = GetSystemMetrics(0);
        height = GetSystemMetrics(1);

        IntPtr screen = GetDC(IntPtr.Zero);
        if (screen == IntPtr.Zero) return "GETDC_FAILED";

        IntPtr mem = CreateCompatibleDC(screen);
        IntPtr bmp = CreateCompatibleBitmap(screen, width, height);
        IntPtr old = SelectObject(mem, bmp);

        bool ok = BitBlt(mem, 0, 0, width, height, screen, 0, 0, SRCCOPY);
        SelectObject(mem, old);

        try
        {
            using (Image image = Image.FromHbitmap(bmp))
            {
                image.Save(path, ImageFormat.Png);
            }
        }
        finally
        {
            DeleteObject(bmp);
            DeleteDC(mem);
            ReleaseDC(IntPtr.Zero, screen);
        }

        return ok ? "OK" : "BITBLT_FAILED";
    }
}
'@ -ReferencedAssemblies System.Drawing

$directory = Split-Path -Path $Out -Parent
if ($directory -and -not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$width = 0
$height = 0
$status = [DshSessionCapture]::Capture($Out, [ref]$width, [ref]$height)

$fileBytes = 0
if (Test-Path -LiteralPath $Out) {
    $fileBytes = (Get-Item -LiteralPath $Out).Length
}

[ordered]@{
    ok         = ($status -eq 'OK')
    status     = $status
    sessionId  = (Get-Process -Id $PID).SessionId
    processId  = $PID
    screen     = "$width x $height"
    out        = $Out
    fileBytes  = $fileBytes
    user       = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    timestamp  = (Get-Date).ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath "$Out.json" -Encoding UTF8
