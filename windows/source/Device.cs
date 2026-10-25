using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace F75Studio {
public sealed class DeviceStatusSnapshot {
    public string Transport {get;set;}
    public int? BatteryPercent {get;set;}
    public bool Responding {get;set;}
    public DateTime CheckedAt {get;set;}
    public string Detail {get;set;}
    public byte[] Raw {get;set;}
}
public sealed class KeyboardDevice : IDisposable {
    SafeFileHandle handle;
    bool statusOnly;
    IntPtr ioEvent,overlapped;
    public string Path { get; private set; }
    public int InputLength, OutputLength;
    [StructLayout(LayoutKind.Sequential)] struct InterfaceData { public int Size; public Guid ClassGuid; public int Flags; public IntPtr Reserved; }
    [StructLayout(LayoutKind.Sequential)] struct Overlapped { public IntPtr Internal,InternalHigh; public uint Offset,OffsetHigh; public IntPtr Event; }
    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid guid);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h,out IntPtr data);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr data);
    [DllImport("hid.dll")] static extern bool HidD_GetProductString(SafeFileHandle h,IntPtr buffer,int length);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr data,IntPtr caps);
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr SetupDiGetClassDevs(ref Guid guid,IntPtr en,IntPtr parent,uint flags);
    [DllImport("setupapi.dll",SetLastError=true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr set,IntPtr info,ref Guid guid,uint index,ref InterfaceData data);
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set,ref InterfaceData data,IntPtr detail,uint size,out uint needed,IntPtr info);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr sec,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool WriteFile(SafeFileHandle h,IntPtr bytes,uint count,out uint sent,IntPtr overlapped);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadFile(SafeFileHandle h,IntPtr bytes,uint count,out uint sent,IntPtr overlapped);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetOverlappedResult(SafeFileHandle h,IntPtr o,out uint count,bool wait);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool CancelIoEx(SafeFileHandle h,IntPtr o);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h,uint ms);
    [DllImport("kernel32.dll")] static extern IntPtr CreateEvent(IntPtr sec,bool manual,bool initial,string name);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    public static KeyboardDevice Open() { return OpenInternal(false); }
    static KeyboardDevice OpenInternal(bool receiver) {bool present;return OpenInternal(receiver,out present);}
    // Last working interface path; skips a full HID enumeration on every status query and send.
    static string cachedPath;
    public static void ForgetCachedPath(){cachedPath=null;}
    static KeyboardDevice TryOpen(string path,bool receiver) {
        var h=CreateFile(path,0xc0000000,3,IntPtr.Zero,3,0x40000000,IntPtr.Zero);
        if(h.IsInvalid){h.Dispose();return null;}
        IntPtr pp;
        if(!HidD_GetPreparsedData(h,out pp)){h.Dispose();return null;}
        IntPtr caps=Marshal.AllocHGlobal(64);
        try {
            if(HidP_GetCaps(pp,caps)==0x110000 && (ushort)Marshal.ReadInt16(caps)==2 && (ushort)Marshal.ReadInt16(caps,2)==0xff02) {
                int input=(ushort)Marshal.ReadInt16(caps,4),output=(ushort)Marshal.ReadInt16(caps,6);
                if(input==65 && output==65) {
                    var device=new KeyboardDevice {handle=h,Path=path,InputLength=input,OutputLength=output,statusOnly=receiver};
                    device.ioEvent=CreateEvent(IntPtr.Zero,true,false,null);
                    device.overlapped=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Overlapped)));
                    return device;
                }
            }
        } finally {Marshal.FreeHGlobal(caps);HidD_FreePreparsedData(pp);}
        h.Dispose();return null;
    }
    static KeyboardDevice OpenInternal(bool receiver,out bool present) {
        present=false;
        if(!receiver && cachedPath!=null) {
            var cached=TryOpen(cachedPath,false);
            if(cached!=null){present=true;return cached;}
            cachedPath=null;
        }
        Guid guid; HidD_GetHidGuid(out guid);
        IntPtr set=SetupDiGetClassDevs(ref guid,IntPtr.Zero,IntPtr.Zero,0x12);
        if(set==new IntPtr(-1)) throw new Win32Exception();
        try {
            for(uint i=0;;i++) {
                var d=new InterfaceData(); d.Size=Marshal.SizeOf(d);
                if(!SetupDiEnumDeviceInterfaces(set,IntPtr.Zero,ref guid,i,ref d)) break;
                uint size; SetupDiGetDeviceInterfaceDetail(set,ref d,IntPtr.Zero,0,out size,IntPtr.Zero);
                IntPtr detail=Marshal.AllocHGlobal((int)size);
                try {
                    Marshal.WriteInt32(detail,IntPtr.Size==8?8:6);
                    if(!SetupDiGetDeviceInterfaceDetail(set,ref d,detail,size,out size,IntPtr.Zero)) continue;
                    string path=Marshal.PtrToStringUni(IntPtr.Add(detail,4));
                    // This release is qualified only for the wired F75, never the shared 8FFF receiver ID.
                    if(path==null || path.IndexOf(receiver?"vid_1a2c&pid_8fff":"vid_1a2c&pid_a073&mi_00",StringComparison.OrdinalIgnoreCase)<0) continue;
                    present=true;
                    var device=TryOpen(path,receiver);
                    if(device!=null){if(!receiver)cachedPath=path;return device;}
                } finally {Marshal.FreeHGlobal(detail);}
            }
        } finally {SetupDiDestroyDeviceInfoList(set);}
        throw new IOException("F75 USB (1A2C:A073) indisponível / unavailable. Conecte por cabo e feche o driver original / Connect by cable and close the original driver.");
    }
    static bool HasBrandedBluetooth() {
        Guid guid;HidD_GetHidGuid(out guid);
        IntPtr set=SetupDiGetClassDevs(ref guid,IntPtr.Zero,IntPtr.Zero,0x12);
        if(set==new IntPtr(-1))return false;
        try {
            for(uint i=0;;i++) {
                var data=new InterfaceData();data.Size=Marshal.SizeOf(data);
                if(!SetupDiEnumDeviceInterfaces(set,IntPtr.Zero,ref guid,i,ref data))break;
                uint size;SetupDiGetDeviceInterfaceDetail(set,ref data,IntPtr.Zero,0,out size,IntPtr.Zero);
                if(size<8)continue;
                IntPtr detail=Marshal.AllocHGlobal((int)size);
                try {
                    Marshal.WriteInt32(detail,IntPtr.Size==8?8:6);
                    if(!SetupDiGetDeviceInterfaceDetail(set,ref data,detail,size,out size,IntPtr.Zero))continue;
                    string path=Marshal.PtrToStringUni(IntPtr.Add(detail,4));
                    // Do not infer Bluetooth from a generic F75 name on a USB HID.
                    if(path==null || (path.IndexOf("bth",StringComparison.OrdinalIgnoreCase)<0 && path.IndexOf("bluetooth",StringComparison.OrdinalIgnoreCase)<0))continue;
                    using(var h=CreateFile(path,0,3,IntPtr.Zero,3,0,IntPtr.Zero)) {
                        if(h.IsInvalid)continue;
                        IntPtr name=Marshal.AllocHGlobal(512);
                        try {
                            if(!HidD_GetProductString(h,name,512))continue;
                            string product=Marshal.PtrToStringUni(name);
                            if(product==null)continue;
                            product=product.Trim().Replace(" ","").Replace("-","").Replace("_","");
                            if(string.Equals(product,"FREEWOLFF75",StringComparison.OrdinalIgnoreCase) || string.Equals(product,"F75",StringComparison.OrdinalIgnoreCase))return true;
                        } finally {Marshal.FreeHGlobal(name);}
                    }
                } finally {Marshal.FreeHGlobal(detail);}
            }
        } finally {SetupDiDestroyDeviceInfoList(set);}
        return false;
    }
    int Transfer(byte[] bytes,bool write,int timeout) {
        // One event and OVERLAPPED per open device; ReadFile/WriteFile reset the event when the operation starts.
        var pin=GCHandle.Alloc(bytes,GCHandleType.Pinned);
        IntPtr o=overlapped;
        try {
            Marshal.StructureToPtr(new Overlapped {Event=ioEvent},o,false);
            uint count;
            bool ok=write?WriteFile(handle,pin.AddrOfPinnedObject(),(uint)bytes.Length,out count,o):ReadFile(handle,pin.AddrOfPinnedObject(),(uint)bytes.Length,out count,o);
            if(!ok) {
                int err=Marshal.GetLastWin32Error();if(err!=997)throw new Win32Exception(err);
                uint result=WaitForSingleObject(ioEvent,(uint)timeout);
                if(result!=0) {
                    CancelIoEx(handle,o);GetOverlappedResult(handle,o,out count,true);
                    if(!write && result==258)return 0;
                    throw new IOException("USB timeout / tempo limite USB.");
                }
                if(!GetOverlappedResult(handle,o,out count,false))throw new Win32Exception();
            }
            return (int)count;
        } finally {pin.Free();}
    }
    public void Send(byte[] packet) {
        if(packet==null || packet.Length!=65 || packet[0]!=0 || packet[1]!=0xaa || packet[2]!=0x55 || packet[3]!=0xcc || packet[4]!=0x33)throw new ArgumentException("Invalid F75 packet");
        if(statusOnly) {
            if(packet[5]!=0x0e)throw new InvalidOperationException("Receiver permits only status command 0E");
            for(int i=6;i<65;i++)if(packet[i]!=0)throw new InvalidOperationException("Status payload must be empty");
        }
        if(Transfer(packet,true,700)!=65)throw new IOException("Incomplete USB write");
        Thread.Sleep(20);
    }
    public byte[] Status() {
        Send(Protocol.Packet(0x0e));
        for(int i=0;i<8;i++) {
            var data=new byte[65];int n=Transfer(data,false,250);
            int offset=n>0 && data[0]==0?1:0;
            if(n>=offset+7 && data[offset]==0xaa && data[offset+1]==0x55 && data[offset+2]==0xcc && data[offset+3]==0x33 && data[offset+4]==0x0e) {
                var status=new byte[n-offset];Array.Copy(data,offset,status,0,status.Length);return status;
            }
            if(n==0)break;
        }
        throw new IOException("F75 não respondeu à consulta / No F75 status response.");
    }
    public void Dispose() {
        if(handle!=null){handle.Dispose();handle=null;}
        if(overlapped!=IntPtr.Zero){Marshal.FreeHGlobal(overlapped);overlapped=IntPtr.Zero;}
        if(ioEvent!=IntPtr.Zero){CloseHandle(ioEvent);ioEvent=IntPtr.Zero;}
    }
    public static DeviceStatusSnapshot ParseStatus(byte[] raw,string transport) {
        // Status() removes report ID. Byte 6 is not a confirmed transport flag.
        if(raw==null || raw.Length<7 || raw[0]!=0xaa || raw[1]!=0x55 || raw[2]!=0xcc || raw[3]!=0x33 || raw[4]!=0x0e)
            throw new ArgumentException("Invalid F75 status response");
        return new DeviceStatusSnapshot {Transport=transport,BatteryPercent=raw[5]<=100?(int?)raw[5]:null,
            Responding=true,CheckedAt=DateTime.Now,Raw=(byte[])raw.Clone(),Detail="Resposta recebida / Status response received"};
    }
    public static DeviceStatusSnapshot ReadStatusSnapshot() {
        // USB always wins; the shared receiver is never exposed for configuration.
        foreach(bool receiver in new bool[]{false,true}) {
            KeyboardDevice device=null;
            bool present=false;
            try {
                device=OpenInternal(receiver,out present);
                try {return ParseStatus(device.Status(),receiver?"2.4 GHz":"USB");}
                catch(IOException) {} catch(Win32Exception) {}
                return new DeviceStatusSnapshot {Transport=receiver?"Receiver":"USB",Responding=false,CheckedAt=DateTime.Now,
                    Detail=receiver?"Receptor detectado; teclado não respondeu / Receiver detected; keyboard did not respond":"USB detectado; status indisponível / USB detected; status unavailable"};
            } catch(IOException) {} catch(Win32Exception) {} catch(UnauthorizedAccessException) {}
            finally {if(device!=null)device.Dispose();}
            if(present)return new DeviceStatusSnapshot {Transport=receiver?"Receiver":"USB",Responding=false,CheckedAt=DateTime.Now,
                Detail="Dispositivo detectado, mas interface ocupada ou indisponível / Device detected; interface busy or unavailable"};
        }
        if(HasBrandedBluetooth())return new DeviceStatusSnapshot {Transport="Bluetooth",Responding=false,CheckedAt=DateTime.Now,
            Detail="HID Bluetooth F75 detectado; status e bateria indisponíveis / F75 Bluetooth HID detected; status and battery unavailable"};
        return new DeviceStatusSnapshot {Transport="Disconnected",Responding=false,CheckedAt=DateTime.Now,
            Detail="F75 USB/receptor não detectado ou ocupado; Bluetooth não identificado / F75 USB/receiver unavailable or busy; Bluetooth not identified"};
    }
}

public static class Protocol {
    public static byte[] Packet(int command,params byte[] payload) {
        if(payload.Length>59)throw new ArgumentException("Payload too long");
        var b=new byte[65];b[1]=0xaa;b[2]=0x55;b[3]=0xcc;b[4]=0x33;b[5]=(byte)command;Array.Copy(payload,0,b,6,payload.Length);return b;
    }
    public static byte[] ResponseTime(int tier){if(tier<1 || tier>3)throw new ArgumentOutOfRangeException();return Packet(0x0d,(byte)tier);}
    public static byte[] Sleep(int tier){if(tier<1 || tier>4)throw new ArgumentOutOfRangeException();return Packet(0x0c,(byte)tier);}
    public static byte[] Effect(int mode,int brightness,int speed,int direction,int palette) {
        if((mode<1 || mode>20) && mode!=22 && mode!=23 && mode!=24)throw new ArgumentOutOfRangeException("mode");
        if(brightness<1 || brightness>5 || speed<1 || speed>5 || direction<0 || direction>3 || palette<0 || palette>8)throw new ArgumentOutOfRangeException();
        return Packet(7,(byte)(mode-1),(byte)(brightness-1),(byte)(speed-1),(byte)direction,(byte)palette);
    }
    public static List<byte[]> Custom(int[] colors,int brightness) {
        if(colors.Length!=108 || brightness<0 || brightness>100)throw new ArgumentException();
        var rgb=new byte[324];
        for(int i=0;i<108;i++){rgb[i*3]=(byte)(((colors[i]>>16)&255)*brightness/100);rgb[i*3+1]=(byte)(((colors[i]>>8)&255)*brightness/100);rgb[i*3+2]=(byte)((colors[i]&255)*brightness/100);}
        var result=new List<byte[]> {Effect(24,5,4,0,0),Packet(0x0b)};
        for(int i=0;i<6;i++){var chunk=new byte[54];Array.Copy(rgb,i*54,chunk,0,54);result.Add(Packet(0xf6+i,chunk));}
        return result;
    }
    // 0x4232F0 in vendor 1.0.4.4: bit 7 release; bits 5..6 scale; low 5 bits delay.
    public static byte EventTiming(bool release,int ms) {
        if(ms<0 || ms>31000)throw new ArgumentOutOfRangeException("ms");
        int unit=ms<=310?10:ms<=1550?50:ms<=3100?100:1000;
        int scale=unit==10?0:unit==50?1:unit==100?2:3;
        return (byte)((release?128:0)|(scale<<5)|Math.Max(1,ms/unit));
    }
    public static List<byte[]> Macro(int trigger,IList<MacroEvent> events) {
        if(trigger<0 || trigger>107 || events.Count<2 || events.Count>60)throw new ArgumentException("Macro length / tamanho: 2–60");
        var held=new HashSet<int>();
        foreach(var e in events){if(e.Code<4 || e.Code>231)throw new ArgumentException("Invalid key");if(e.Release){if(!held.Remove(e.Code))throw new ArgumentException("Key-up without key-down");}else if(!held.Add(e.Code))throw new ArgumentException("Repeated key-down");}
        if(held.Count!=0)throw new ArgumentException("Macro leaves keys pressed");
        var data=new byte[162];data[0]=1;data[1]=(byte)trigger;data[2]=1;data[3]=(byte)events.Count;
        for(int i=0;i<events.Count;i++){data[4+i*2]=(byte)events[i].Code;data[5+i*2]=EventTiming(events[i].Release,events[i].Delay);}
        var packets=new List<byte[]>();for(int i=0;i<3;i++){var b=new byte[54];Array.Copy(data,i*54,b,0,54);packets.Add(Packet(i,b));}return packets;
    }
}
public sealed class MacroEvent { public int Code {get;set;} public bool Release {get;set;} public int Delay {get;set;} }
}
