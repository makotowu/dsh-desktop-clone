# DSH 桌面分身 —— 带体验层的宿主
#
# 体验项对齐 BetterGI 的 ChildSessionWindow：窗口位置记忆、自适应缩放/1:1、
# 保持宽高比、置顶、静音远程音频、观看模式、状态栏、关闭即注销。
#
# 本文件必须存为「UTF-8 带 BOM」。Windows PowerShell 5.1 会按 ANSI 读无 BOM 的
# .ps1，中文会变成乱码。

param(
    # Exactly BetterGI's model: session desktop fixed at 1920x1080, window
    # 1280x752 (1280x720 client), SmartSizing scales the frame into the window.
    [int]$DesktopWidth = 1920,
    [int]$DesktopHeight = 1080,
    # Same as BetterGI's ChildSessionWindow: Width=1280 Height=752, i.e. a
    # 1280x720 (16:9) client area for the 1920x1080 desktop, with 自适应 scaling.
    [int]$WindowWidth = 1280,
    [int]$WindowHeight = 720,
    [switch]$Topmost,
    [switch]$NoSmartSizing,
    [switch]$NoKeepAspectRatio,
    [switch]$AudioMuted,
    [switch]$SendShortcutsToRemote,
    [switch]$WatchMode,
    [switch]$NoAutoLogoff
)

$ErrorActionPreference = 'Stop'

Add-Type -Path (Join-Path $PSScriptRoot 'DshRdpAxHost.cs') `
    -ReferencedAssemblies System.Windows.Forms, System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshWtsNative {
    [DllImport("wtsapi32.dll", SetLastError = true)]
    public static extern bool WTSGetChildSessionId(out uint sessionId);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    public static extern bool WTSLogoffSession(IntPtr server, uint sessionId, bool wait);

    // GetDpiForSystem/GetDpiForMonitor answer relative to the caller's awareness;
    // a DPI-unaware process always gets 96. This host must be per-monitor aware
    // before any window exists, or every size we ask for gets virtualized.
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
}
'@ -Language CSharp

try {
    # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    [void][DshWtsNative]::SetProcessDpiAwarenessContext([IntPtr](-4))
} catch { }

$stateRoot = Join-Path $env:LOCALAPPDATA 'dsh-desktop-clone'
if (-not (Test-Path -LiteralPath $stateRoot)) {
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
}
$windowStatePath = Join-Path $stateRoot 'window.json'

function Get-ChildSessionId {
    $sid = [uint32]0
    if ([DshWtsNative]::WTSGetChildSessionId([ref]$sid) -and $sid -ne [uint32]::MaxValue) {
        return [uint32]$sid
    }
    return $null
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'DSH 桌面分身'
$form.ClientSize = New-Object System.Drawing.Size($WindowWidth, $WindowHeight)
$form.MinimumSize = New-Object System.Drawing.Size(640, 400)
$form.StartPosition = 'Manual'
$form.TopMost = [bool]$Topmost

# --- 窗口位置记忆 ---------------------------------------------------------
$savedWindow = $null
if (Test-Path -LiteralPath $windowStatePath) {
    try {
        $savedWindow = Get-Content -LiteralPath $windowStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $savedWindow = $null
    }
}
if ($savedWindow -and $savedWindow.width -gt 400) {
    $form.Left = [int]$savedWindow.left
    $form.Top = [int]$savedWindow.top
    $form.ClientSize = New-Object System.Drawing.Size([int]$savedWindow.width, [int]$savedWindow.height)
} else {
    $form.Left = 120
    $form.Top = 60
}

$hostControl = New-Object DshRdpAxHost
$form.Controls.Add($hostControl)

# --- 菜单 -----------------------------------------------------------------
$menu = New-Object System.Windows.Forms.MenuStrip

$viewMenu = New-Object System.Windows.Forms.ToolStripMenuItem('显示')
$itemSmartSizing = New-Object System.Windows.Forms.ToolStripMenuItem('自适应缩放（适合窗口）')
$itemSmartSizing.CheckOnClick = $true
$itemSmartSizing.Checked = -not $NoSmartSizing
$itemKeepRatio = New-Object System.Windows.Forms.ToolStripMenuItem('保持宽高比')
$itemKeepRatio.CheckOnClick = $true
$itemKeepRatio.Checked = -not $NoKeepAspectRatio
$itemTopmost = New-Object System.Windows.Forms.ToolStripMenuItem('窗口置顶')
$itemTopmost.CheckOnClick = $true
$itemTopmost.Checked = [bool]$Topmost
$itemMuted = New-Object System.Windows.Forms.ToolStripMenuItem('静音分身声音')
$itemMuted.CheckOnClick = $true
$itemMuted.Checked = $true
$itemWatch = New-Object System.Windows.Forms.ToolStripMenuItem('观看模式（本机输入不进入分身）')
$itemWatch.CheckOnClick = $true
$itemWatch.Checked = [bool]$WatchMode

foreach ($item in @($itemSmartSizing, $itemKeepRatio, $itemTopmost, $itemMuted, $itemWatch)) {
    [void]$viewMenu.DropDownItems.Add($item)
}

$sessionMenu = New-Object System.Windows.Forms.ToolStripMenuItem('分身')
$itemLogoff = New-Object System.Windows.Forms.ToolStripMenuItem('断开并注销')
[void]$sessionMenu.DropDownItems.Add($itemLogoff)

[void]$menu.Items.Add($viewMenu)
[void]$menu.Items.Add($sessionMenu)
$form.Controls.Add($menu)
$form.MainMenuStrip = $menu

# --- 状态栏 ---------------------------------------------------------------
$status = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel('正在启动…')
$statusLabel.Spring = $true
$statusLabel.TextAlign = 'MiddleLeft'
[void]$status.Items.Add($statusLabel)
$form.Controls.Add($status)

$aspectRatio = $DesktopWidth / $DesktopHeight
$suppressResize = $false

# --- 事件 -----------------------------------------------------------------
$applyAspect = {
    if (-not $itemKeepRatio.Checked -or $suppressResize) { return }
    $suppressResize = $true
    try {
        # Lock the aspect of the RDP control itself, not the form. The menu strip
        # and status bar are carved out of the client area, so locking the form
        # leaves the control at something like 1280x674 and SmartSizing stretches
        # the 16:9 frame into it, which looks vertically squashed.
        $chromeHeight = $menu.Height + $status.Height
        # Use the form's client width: at startup the RDP control has not been laid
        # out yet, so its Width can still be 0 and would collapse the window.
        $targetHostHeight = [int][Math]::Round($form.ClientSize.Width / $aspectRatio)
        $desiredClientHeight = $targetHostHeight + $chromeHeight
        if ($targetHostHeight -gt 200 -and $desiredClientHeight -ne $form.ClientSize.Height) {
            $form.ClientSize = New-Object System.Drawing.Size($form.ClientSize.Width, $desiredClientHeight)
        }
    } finally {
        $suppressResize = $false
    }
}

$form.Add_Resize({ & $applyAspect })
$itemKeepRatio.add_Click({ & $applyAspect })
$itemTopmost.add_Click({ $form.TopMost = $itemTopmost.Checked })

$itemSmartSizing.add_Click({
    try {
        $hostControl.SetSmartSizing($itemSmartSizing.Checked)
        $statusLabel.Text = "自适应缩放：$($itemSmartSizing.Checked)"
    } catch {
        $statusLabel.Text = "切换缩放失败：$($_.Exception.GetBaseException().Message)"
    }
})

$itemMuted.add_Click({
    try {
        $hostControl.SetAudioMuted($itemMuted.Checked)
        $statusLabel.Text = "分身声音：$(if ($itemMuted.Checked) { '已静音' } else { '已开启' })（下次连接生效）"
    } catch {
        $statusLabel.Text = "切换声音失败：$($_.Exception.GetBaseException().Message)"
    }
})

$itemWatch.add_Click({
    $blocked = $hostControl.SetInputBlocked($itemWatch.Checked)
    $statusLabel.Text = if ($blocked) {
        "观看模式：$($itemWatch.Checked)"
    } else {
        '观看模式需要先连上分身'
    }
})

$logoffRequested = $false
$doLogoff = {
    if ($logoffRequested -or $NoAutoLogoff) { return }
    $logoffRequested = $true
    try { $hostControl.InvokeMethod('Disconnect') } catch { }
    $sid = Get-ChildSessionId
    if ($sid) { [void][DshWtsNative]::WTSLogoffSession([IntPtr]::Zero, $sid, $true) }
}

$itemLogoff.add_Click({
    & $doLogoff
    $form.Close()
})

$form.Add_FormClosing({
    try {
        $saved = [ordered]@{
            left   = $form.Left
            top    = $form.Top
            width  = $form.ClientSize.Width
            height = $form.ClientSize.Height
        }
        $saved | ConvertTo-Json | Set-Content -LiteralPath $windowStatePath -Encoding UTF8
    } catch { }
    & $doLogoff
})

$form.Show()
[System.Windows.Forms.Application]::DoEvents()
& $applyAspect

# --- 连接 -----------------------------------------------------------------
$hostControl.SetProperty('Server', 'localhost')
$hostControl.SetProperty('DesktopWidth', $DesktopWidth)
$hostControl.SetProperty('DesktopHeight', $DesktopHeight)
$hostControl.SetProperty('ColorDepth', 32)
$hostControl.SetProperty('ConnectingText', '正在创建 DSH 桌面分身…')
$hostControl.SetProperty('DisconnectedText', 'DSH 桌面分身已断开')

$advanced = $hostControl.GetProperty('AdvancedSettings7')
if ($advanced -ne $null) {
    [DshRdpAxHost]::SetCom($advanced, 'RDPPort', 3389)
    [DshRdpAxHost]::SetCom($advanced, 'EnableCredSspSupport', $true)
    [DshRdpAxHost]::SetCom($advanced, 'EnableWindowsKey', 1)
    [DshRdpAxHost]::SetCom($advanced, 'SmartSizing', [bool]$itemSmartSizing.Checked)
}

try {
    $hostControl.SetExtendedProperty('EnableZoom', $true)

    # The clone should use the same scaling the user picked in Windows, no more.
    # GetDpiForSystem is authoritative now that this process is per-monitor aware.
    # HKCU LogPixels is only a fallback: it can be stale (observed 106 = 110%,
    # a scale Windows does not even offer) because Win11 stores the real value
    # per monitor.
    $systemScale = 0
    try {
        $systemDpi = [DshWtsNative]::GetDpiForSystem()
        if ($systemDpi -gt 0) {
            $systemScale = [int][Math]::Round($systemDpi / 96.0 * 100)
        }
    } catch { }

    if ($systemScale -le 0) {
        try {
            $logPixels = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name LogPixels -ErrorAction SilentlyContinue).LogPixels
            if ($logPixels -gt 0) {
                $systemScale = [int][Math]::Round($logPixels / 96.0 * 100)
            }
        } catch { }
    }

    if ($systemScale -le 0) {
        $systemScale = 100
    }

    try {
        $deviceScale = if ($systemScale -ge 200) { 180 } elseif ($systemScale -ge 150) { 140 } else { 100 }
        $hostControl.SetExtendedProperty('DesktopScaleFactor', [uint32]$systemScale)
        $hostControl.SetExtendedProperty('DeviceScaleFactor', [uint32]$deviceScale)
        Write-Output "scale_percent=$systemScale device_scale=$deviceScale (system)"
    } catch {
        Write-Output "scale_percent=FAILED $($_.Exception.GetBaseException().Message)"
    }

    $hostControl.SetExtendedProperty('ConnectToChildSession', $true)
} catch {
    Write-Output "extended_settings=FAILED $($_.Exception.GetBaseException().Message)"
}

$sec = $null
try {
    $sec = $hostControl.GetProperty('SecuredSettings2')
    # BetterGI's defaults: send system shortcuts to the clone, mute its audio.
    [DshRdpAxHost]::SetCom($sec, 'KeyboardHookMode', [int]1)
    [DshRdpAxHost]::SetCom($sec, 'AudioRedirectionMode', [int]2)
} catch { }

$existing = Get-ChildSessionId
Write-Output "existing_child_session=$existing"

$hostControl.InvokeMethod('Connect')
Write-Output 'connect_called=OK'

# --- 状态轮询 -------------------------------------------------------------
$script:loginSeen = $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    try {
        $state = $hostControl.ConnectedState()
        $sid = Get-ChildSessionId
        $stateText = switch ($state) {
            0 { '未连接' }
            1 { '已连接' }
            2 { '正在连接' }
            default { "状态 $state" }
        }
        $sessionText = if ($sid) { $sid } else { '无' }
        $statusLabel.Text = "RDP：$stateText    分身会话：$sessionText    桌面：${DesktopWidth}×${DesktopHeight}"

        if ($state -eq 1 -and -not $script:loginSeen) {
            $script:loginSeen = $true
            Write-Output "LOGIN_COMPLETE session=$sid"
            if ($itemWatch.Checked) { [void]$hostControl.SetInputBlocked($true) }
        }
    } catch {
        $statusLabel.Text = "状态读取失败：$($_.Exception.GetBaseException().Message)"
    }
})
$timer.Start()

[System.Windows.Forms.Application]::Run($form)
$timer.Stop()
