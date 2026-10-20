// SPDX-License-Identifier: GPL-3.0-or-later
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class PDWindowsCapture
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    public sealed class Window
    {
        public IntPtr Handle;
        public string Title;
        public Rect Bounds;
    }
    private delegate bool Callback(IntPtr handle, IntPtr parameter);
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(Callback callback, IntPtr parameter);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint process);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr handle);
    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr handle, out Rect bounds);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr handle, StringBuilder title, int size);
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr handle, IntPtr context, uint flags);

    // Capture only windows belonging to the test process, never the desktop.
    public static Window[] Windows(uint process)
    {
        var windows = new List<Window>();
        EnumWindows((handle, parameter) => {
            uint owner;
            Rect bounds;
            GetWindowThreadProcessId(handle, out owner);
            if (owner == process && IsWindowVisible(handle)
                && GetWindowRect(handle, out bounds)
                && bounds.Right - bounds.Left > 200 && bounds.Bottom - bounds.Top > 100)
            {
                var title = new StringBuilder(256);
                GetWindowText(handle, title, title.Capacity);
                windows.Add(new Window { Handle = handle, Title = title.ToString(), Bounds = bounds });
            }
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }
}
