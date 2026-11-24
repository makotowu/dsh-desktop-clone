// DSH 桌面分身 —— RDP ActiveX 宿主
//
// 由 PowerShell 用 Add-Type 编译（-ReferencedAssemblies System.Windows.Forms,System.Drawing），
// 之后在 STA 线程上放进一个 WinForms 窗口里跑消息循环。
//
// 关键点来自 BetterGI 的 RdpActiveXHost：
//   1. CLSID A0C63C30-F08D-4AB4-907C-34905D770C7D 是 Win10+ 自带的 MsRdpClient10（非脚本化）。
//   2. 普通 RDP 连接会抢占控制台会话，只有先把 IMsRdpExtendedSettings 的
//      "ConnectToChildSession" 置 true，才会以子会话方式连本机，而不是新建/顶替会话。
//   3. AxHost 在不可见时不会创建底层窗口与 ActiveX 实例；读一次 Handle 可以强制创建。
//   4. 这里不做连接点事件订阅：轮询 Connected 属性 + WTSGetChildSessionId 足够判断登录完成，
//      代码量和互操作面都小得多。

using System;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class DshRdpAxHost : AxHost
{
    public const string RdpClientClsid = "A0C63C30-F08D-4AB4-907C-34905D770C7D";

    public DshRdpAxHost() : base(RdpClientClsid)
    {
        Dock = DockStyle.Fill;
    }

    /// <summary>取得底层 ActiveX COM 实例；需要时强制创建句柄。</summary>
    public object Ocx()
    {
        if (!IsHandleCreated)
        {
            // 读取 Handle 会忽略可见性，强制 AxHost 创建窗口和控件实例。
            var ignored = Handle;
            GC.KeepAlive(ignored);
        }

        object ocx = GetOcx();
        if (ocx == null)
        {
            throw new InvalidOperationException("RDP ActiveX 尚未完成初始化。");
        }

        return ocx;
    }

    /// <summary>0=未连接 1=已连接 2=正在连接。</summary>
    public int ConnectedState()
    {
        if (!IsHandleCreated)
        {
            return 0;
        }

        return Convert.ToInt32(GetCom(Ocx(), "Connected"));
    }

    public void SetProperty(string name, object value)
    {
        SetCom(Ocx(), name, value);
    }

    public object GetProperty(string name)
    {
        return GetCom(Ocx(), name);
    }

    public void InvokeMethod(string name, params object[] args)
    {
        Ocx().GetType().InvokeMember(
            name,
            BindingFlags.InvokeMethod,
            null,
            Ocx(),
            args);
    }

    /// <summary>调用返回值的 COM 方法（例如 GetErrorDescription）。</summary>
    public object InvokeMethodWithResult(string name, object[] args)
    {
        return Ocx().GetType().InvokeMember(
            name,
            BindingFlags.InvokeMethod,
            null,
            Ocx(),
            args);
    }

    /// <summary>IMsRdpExtendedSettings.set_Property —— ConnectToChildSession 就走这里。</summary>
    public void SetExtendedProperty(string name, object value)
    {
        var extended = (IMsRdpExtendedSettings)Ocx();
        extended.set_Property(name, ref value);
    }

    /// <summary>实时缩放开关：窗口比桌面小时把整张桌面缩进窗口。</summary>
    public void SetSmartSizing(bool enabled)
    {
        SetCom(GetCom(Ocx(), "AdvancedSettings7"), "SmartSizing", enabled);
    }

    /// <summary>音频重定向：0 = 送到本机，2 = 关闭远程音频。</summary>
    public void SetAudioMuted(bool muted)
    {
        SetCom(GetCom(Ocx(), "SecuredSettings2"), "AudioRedirectionMode", muted ? 2 : 0);
    }

    /// <summary>系统组合键去本机（0）还是去分身（1）。</summary>
    public void SetSendSystemShortcutsToRemote(bool remote)
    {
        SetCom(GetCom(Ocx(), "SecuredSettings2"), "KeyboardHookMode", remote ? 1 : 0);
    }

    /// <summary>观看模式：屏蔽 RDP 的输入窗口，本机鼠标键盘进不去，画面照常。</summary>
    public bool SetInputBlocked(bool blocked)
    {
        IntPtr inputWindow = FindInputCaptureWindow();
        if (inputWindow == IntPtr.Zero)
        {
            return false;
        }

        return EnableWindow(inputWindow, !blocked);
    }

    /// <summary>RDP 客户端内部那个接收真实输入的 "Input Capture Window"。</summary>
    public IntPtr FindInputCaptureWindow()
    {
        if (!IsHandleCreated)
        {
            return IntPtr.Zero;
        }

        IntPtr found = IntPtr.Zero;
        EnumChildWindows(Handle, delegate(IntPtr window, IntPtr parameter)
        {
            var text = new System.Text.StringBuilder(256);
            GetWindowText(window, text, text.Capacity);
            if (text.ToString() == "Input Capture Window")
            {
                found = window;
                return false;
            }

            return true;
        }, IntPtr.Zero);

        return found;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr parameter);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int maximumLength);

    [DllImport("user32.dll")]
    private static extern bool EnableWindow(IntPtr window, bool enable);

    private delegate bool EnumProc(IntPtr window, IntPtr parameter);

    public static object GetCom(object target, string name)
    {
        return target.GetType().InvokeMember(
            name, BindingFlags.GetProperty, null, target, null);
    }

    public static void SetCom(object target, string name, object value)
    {
        target.GetType().InvokeMember(
            name, BindingFlags.SetProperty, null, target, new[] { value });
    }
}

[ComImport]
[Guid("302D8188-0052-4807-806A-362B628F9AC5")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMsRdpExtendedSettings
{
    void set_Property(
        [In, MarshalAs(UnmanagedType.BStr)] string propertyName,
        [In, MarshalAs(UnmanagedType.Struct)] ref object value);

    [return: MarshalAs(UnmanagedType.Struct)]
    object get_Property(
        [In, MarshalAs(UnmanagedType.BStr)] string propertyName);
}
