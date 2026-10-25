using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace F75Studio {
// Tray icon and color picker through Win32 directly, so System.Windows.Forms and System.Drawing are never loaded.
public sealed class TrayIcon : IDisposable {
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct NotifyIconData {
        public int Size; public IntPtr Window; public int Id; public int Flags; public int CallbackMessage; public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string Tip;
        public int State,StateMask;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)] public string Info;
        public int Version;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=64)] public string InfoTitle;
        public int InfoFlags; public Guid Item; public IntPtr BalloonIcon;
    }
    [DllImport("shell32.dll",CharSet=CharSet.Unicode)] static extern bool Shell_NotifyIcon(int message,ref NotifyIconData data);
    [DllImport("shell32.dll",CharSet=CharSet.Unicode)] static extern int ExtractIconEx(string file,int index,IntPtr large,out IntPtr small,int count);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")] static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool AppendMenu(IntPtr menu,int flags,IntPtr id,string text);
    [DllImport("user32.dll")] static extern int TrackPopupMenu(IntPtr menu,int flags,int x,int y,int reserved,IntPtr window,IntPtr rect);
    [DllImport("user32.dll")] static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window,int message,IntPtr w,IntPtr l);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int RegisterWindowMessage(string name);
    [StructLayout(LayoutKind.Sequential)] struct Point { public int X,Y; }
    const int CallbackMessage=0x8000+75, NimAdd=0, NimDelete=2, NifMessage=1, NifIcon=2, NifTip=4;
    static readonly int TaskbarCreated=RegisterWindowMessage("TaskbarCreated");
    readonly HwndSource source; readonly IntPtr icon; bool added;
    public event Action DoubleClick;
    // Built when the menu opens, so labels always follow the current language.
    public Func<IList<KeyValuePair<string,Action>>> MenuItems;
    public TrayIcon(IntPtr window,string tip) {
        source=HwndSource.FromHwnd(window);
        IntPtr small;
        icon=ExtractIconEx(Assembly.GetExecutingAssembly().Location,0,IntPtr.Zero,out small,1)>0?small:IntPtr.Zero;
        Tip=tip;
        source.AddHook(Hook);
        Add();
    }
    public string Tip {get;private set;}
    NotifyIconData Data(){return new NotifyIconData {Size=Marshal.SizeOf(typeof(NotifyIconData)),Window=source.Handle,Id=1,Flags=NifMessage|NifIcon|NifTip,CallbackMessage=CallbackMessage,Icon=icon,Tip=Tip};}
    void Add(){var d=Data();added=Shell_NotifyIcon(NimAdd,ref d);}
    IntPtr Hook(IntPtr hwnd,int msg,IntPtr w,IntPtr l,ref bool handled) {
        if(msg==TaskbarCreated && TaskbarCreated!=0){Add();return IntPtr.Zero;}
        if(msg!=CallbackMessage)return IntPtr.Zero;
        int mouse=(int)((long)l & 0xffff);
        if(mouse==0x203){if(DoubleClick!=null)DoubleClick();handled=true;}
        else if(mouse==0x205){ShowMenu();handled=true;}
        return IntPtr.Zero;
    }
    void ShowMenu() {
        if(MenuItems==null)return;
        var items=MenuItems();
        IntPtr menu=CreatePopupMenu();
        try {
            for(int i=0;i<items.Count;i++){if(items[i].Value==null)AppendMenu(menu,0x800,IntPtr.Zero,null);else AppendMenu(menu,0,new IntPtr(i+1),items[i].Key);}
            Point p;GetCursorPos(out p);
            SetForegroundWindow(source.Handle);
            int chosen=TrackPopupMenu(menu,0x100|0x2,p.X,p.Y,0,source.Handle,IntPtr.Zero);
            PostMessage(source.Handle,0,IntPtr.Zero,IntPtr.Zero);
            if(chosen>0 && chosen<=items.Count && items[chosen-1].Value!=null)items[chosen-1].Value();
        } finally {DestroyMenu(menu);}
    }
    public void Dispose() {
        if(added){var d=Data();Shell_NotifyIcon(NimDelete,ref d);added=false;}
        if(!source.IsDisposed)source.RemoveHook(Hook);
        if(icon!=IntPtr.Zero)DestroyIcon(icon);
    }
}
public static class ColorPicker {
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct ChooseColorData {
        public int Size; public IntPtr Owner; public IntPtr Instance; public int Result; public IntPtr CustomColors; public int Flags; public IntPtr Data; public IntPtr Hook; public IntPtr Template;
    }
    [DllImport("comdlg32.dll",CharSet=CharSet.Unicode)] static extern bool ChooseColor(ref ChooseColorData data);
    static IntPtr custom;
    // Returns 0xRRGGBB, or -1 when cancelled.
    public static int Pick(IntPtr owner,int initial) {
        if(custom==IntPtr.Zero){custom=Marshal.AllocHGlobal(64);for(int i=0;i<16;i++)Marshal.WriteInt32(custom,i*4,0xffffff);}
        int bgr=((initial&255)<<16)|(initial&0xff00)|((initial>>16)&255);
        var d=new ChooseColorData {Size=Marshal.SizeOf(typeof(ChooseColorData)),Owner=owner,Result=bgr,CustomColors=custom,Flags=1|2};
        if(!ChooseColor(ref d))return -1;
        int c=d.Result;
        return ((c&255)<<16)|(c&0xff00)|((c>>16)&255);
    }
}
public static class Memory {
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool SetProcessWorkingSetSize(IntPtr process,IntPtr min,IntPtr max);
    // Called only after the UI tree is dropped; returns freed pages to Windows while the app sits hidden.
    public static void Trim(){GC.Collect();GC.WaitForPendingFinalizers();GC.Collect();SetProcessWorkingSetSize(GetCurrentProcess(),new IntPtr(-1),new IntPtr(-1));}
}
}
