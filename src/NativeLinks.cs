using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace SmartClean {
    public sealed class LinkInfo {
        public string Type, Target, ResolvedTarget;
        public uint Tag;
        public int Error;
    }
    public static class NativeLinks {
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string name,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
        [DllImport("kernel32.dll",SetLastError=true)]
        private static extern bool DeviceIoControl(SafeFileHandle handle,uint code,IntPtr input,int inputLength,byte[] output,int outputLength,out int returned,IntPtr overlapped);
        // Metadata query only. OPEN_REPARSE_POINT prevents following the link.
        public static LinkInfo Read(string path) {
            var result=new LinkInfo();
            using(var h=CreateFileW(path,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
                if(h.IsInvalid){result.Error=Marshal.GetLastWin32Error();return result;}
                byte[] buffer=new byte[16384];int count;
                if(!DeviceIoControl(h,0x000900A8,IntPtr.Zero,0,buffer,buffer.Length,out count,IntPtr.Zero)){
                    result.Error=Marshal.GetLastWin32Error();return result;
                }
                if(count<16){result.Error=13;return result;}
                result.Tag=BitConverter.ToUInt32(buffer,0);
                int start;
                if(result.Tag==0xA0000003){start=16;result.Type="Junction";}
                else if(result.Tag==0xA000000C){start=20;result.Type="SymbolicLink";}
                else{result.Type="OtherReparsePoint";return result;}
                int offset=BitConverter.ToUInt16(buffer,12),length=BitConverter.ToUInt16(buffer,14);
                if(length==0){offset=BitConverter.ToUInt16(buffer,8);length=BitConverter.ToUInt16(buffer,10);}
                if(start+offset+length>count || length%2!=0){result.Error=13;return result;}
                string target=Encoding.Unicode.GetString(buffer,start+offset,length);
                if(target.StartsWith("\\??\\UNC\\",StringComparison.OrdinalIgnoreCase))target="\\\\"+target.Substring(8);
                else if(target.StartsWith("\\??\\Volume{",StringComparison.OrdinalIgnoreCase))target="\\\\?\\"+target.Substring(4);
                else if(target.StartsWith("\\??\\",StringComparison.OrdinalIgnoreCase))target=target.Substring(4);
                result.Target=target;
                if(result.Tag==0xA0000003 && target.StartsWith("\\\\?\\Volume{",StringComparison.OrdinalIgnoreCase))result.Type="VolumeMountPoint";
                try{
                    bool relative=result.Tag==0xA000000C && (BitConverter.ToUInt32(buffer,16)&1)!=0;
                    result.ResolvedTarget=relative?Path.GetFullPath(Path.Combine(Path.GetDirectoryName(path),target)):target;
                }catch{result.ResolvedTarget=target;}
            }
            return result;
        }
    }
}
