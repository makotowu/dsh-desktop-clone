# DSH desktop clone -- self-built child session host
#
# Creates a Windows child session with our own RDP ActiveX host (no BetterGI).
#
# Sizing model (same as BetterGI):
#   -DesktopWidth/Height  = the child session's own desktop resolution
#   -WindowWidth/Height   = the on-screen window size; SmartSizing scales the
#                           whole desktop down into it, so the window can be
#                           comfortably smaller than the desktop.
#
# UI strings are ASCII on purpose: Windows PowerShell 5.1 reads a BOM-less
# .ps1 as ANSI, so non-ASCII literals become mojibake.

param(
    # Same as BetterGI's DefaultDesktopSize: the child session desktop is fixed at
    # 1920x1080 and SmartSizing scales it into whatever window we give it.
    [int]$DesktopWidth = 1920,
    [int]$DesktopHeight = 1080,
    [int]$WindowWidth = 1120,
    [int]$WindowHeight = 660,
    [int]$ScalePercent = 0,
    [int]$TimeoutSeconds = 120,
    [switch]$KeepOpen
)

$ErrorActionPreference = 'Stop'

Add-Type -Path (Join-Path $PSScriptRoot 'DshRdpAxHost.cs') `
    -ReferencedAssemblies System.Windows.Forms, System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshWts {
    [DllImport("wtsapi32.dll", SetLastError = true)]
    public static extern bool WTSGetChildSessionId(out uint sessionId);

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);

    [DllImport("shcore.dll")]
    public static extern int GetDpiForMonitor(IntPtr hmon, int dpiType, out uint dpiX, out uint dpiY);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    // GetDpiForSystem() returns 96 for a DPI-unaware process, which PowerShell is.
    // GetDpiForMonitor with MDT_EFFECTIVE_DPI reports the real scaling of the display.
    public static int GetPrimaryScalePercent()
    {
        POINT origin = new POINT();
        origin.X = 0;
        origin.Y = 0;
        IntPtr monitor = MonitorFromPoint(origin, 1); // MONITOR_DEFAULTTOPRIMARY
        if (monitor == IntPtr.Zero) return 100;

        uint dpiX;
        uint dpiY;
        const int MDT_EFFECTIVE_DPI = 0;
        if (GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, out dpiX, out dpiY) != 0) return 100;
        if (dpiX == 0) return 100;

        return (int)Math.Round((dpiX / 96.0) * 100.0);
    }
}
'@ -Language CSharp

function Get-ChildSessionId {
    $sid = [uint32]0
    if ([DshWts]::WTSGetChildSessionId([ref]$sid) -and $sid -ne [uint32]::MaxValue) {
        return [uint32]$sid
    }
    return $null
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'DSH Desktop Clone'
$form.ClientSize = New-Object System.Drawing.Size($WindowWidth, $WindowHeight)
$form.MinimumSize = New-Object System.Drawing.Size(640, 400)
$form.StartPosition = 'Manual'
$form.Left = 120
$form.Top = 80

$hostControl = New-Object DshRdpAxHost
$form.Controls.Add($hostControl)
$form.Show()
[System.Windows.Forms.Application]::DoEvents()

Write-Output "host_handle=$($hostControl.Handle)"
Write-Output "desktop=${DesktopWidth}x${DesktopHeight} window=${WindowWidth}x${WindowHeight}"

$hostControl.SetProperty('Server', 'localhost')

# 1:1 by default. A 1920x1080 desktop squeezed into a 1120x660 window is scaled to
# ~58%, which makes every label tiny. Matching the session desktop to the window
# keeps it pixel-exact; SmartSizing still rescales if the user drags the window.
if ($DesktopWidth -le 0) { $DesktopWidth = $hostControl.ClientSize.Width }
if ($DesktopHeight -le 0) { $DesktopHeight = $hostControl.ClientSize.Height }

$hostControl.SetProperty('DesktopWidth', $DesktopWidth)
$hostControl.SetProperty('DesktopHeight', $DesktopHeight)
$hostControl.SetProperty('ColorDepth', 32)
$hostControl.SetProperty('ConnectingText', 'Creating DSH desktop clone...')
$hostControl.SetProperty('DisconnectedText', 'DSH desktop clone is disconnected')

$advanced = $hostControl.GetProperty('AdvancedSettings7')
if ($advanced -ne $null) {
    [DshRdpAxHost]::SetCom($advanced, 'RDPPort', 3389)
    [DshRdpAxHost]::SetCom($advanced, 'EnableCredSspSupport', $true)
    [DshRdpAxHost]::SetCom($advanced, 'EnableWindowsKey', 1)
    # SmartSizing is what lets the window be smaller than the desktop.
    [DshRdpAxHost]::SetCom($advanced, 'SmartSizing', $true)

    # RDP sessions default to 100% scaling no matter what the host display uses.
    # DesktopScaleFactor is what makes the child session follow the host DPI.
    if ($ScalePercent -le 0) {
        $ScalePercent = [DshWts]::GetPrimaryScalePercent()
    }

    # DesktopScaleFactor is exposed on the extended settings bag, not AdvancedSettings7.
    try {
        $hostControl.SetExtendedProperty('DesktopScaleFactor', [uint32]$ScalePercent)
        $hostControl.SetExtendedProperty('DeviceScaleFactor', [uint32]100)
        Write-Output "scale_percent=$ScalePercent (extended)"
    } catch {
        try {
            [DshRdpAxHost]::SetCom($advanced, 'DesktopScaleFactor', [uint32]$ScalePercent)
            Write-Output "scale_percent=$ScalePercent (advanced)"
        } catch {
            Write-Output "scale_percent=FAILED $($_.Exception.GetBaseException().Message)"
        }
    }

    Write-Output 'advanced_settings=OK'
} else {
    Write-Output 'advanced_settings=MISSING'
}

try {
    $hostControl.SetExtendedProperty('EnableZoom', $true)
    Write-Output 'ext_enable_zoom=OK'
} catch {
    Write-Output "ext_enable_zoom=SKIPPED $($_.Exception.GetBaseException().Message)"
}

# The decisive call: without it, Connect() would replace or create a normal session.
$hostControl.SetExtendedProperty('ConnectToChildSession', $true)
Write-Output 'ext_connect_to_child_session=OK'

$hostControl.InvokeMethod('Connect')
Write-Output 'connect_called=OK'

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$found = $null
$lastState = -1
while ((Get-Date) -lt $deadline) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 300

    $state = $hostControl.ConnectedState()
    if ($state -ne $lastState) {
        Write-Output "connectedState=$state"
        $lastState = $state
    }

    $sid = Get-ChildSessionId
    if ($sid) {
        $found = $sid
        Write-Output "CHILD_SESSION_FOUND=$sid connectedState=$state"
        break
    }
}

if ($found) {
    Write-Output "RESULT=SUCCESS childSessionId=$found"
} else {
    Write-Output "RESULT=NO_CHILD_SESSION connectedState=$($hostControl.ConnectedState())"
}

if ($KeepOpen) {
    Write-Output 'KEEP_OPEN=1'
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        try { $sender.Tag = $true } catch { }
    })
    [System.Windows.Forms.Application]::Run($form)
    Write-Output "TEARDOWN connectedState=$($hostControl.ConnectedState())"
} else {
    $form.Close()
    $form.Dispose()
}
