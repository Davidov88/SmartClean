using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

namespace SmartClean {
    public static class AtomicJson {
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        private static extern bool MoveFileExW(string source,string destination,uint flags);
        public static void Write(string destination,string text) {
            string temporary=destination+"."+Guid.NewGuid().ToString("N")+".tmp";
            try {
                byte[] bytes=new UTF8Encoding(false).GetBytes(text);
                using(var output=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)){
                    output.Write(bytes,0,bytes.Length);output.Flush(true);
                }
                int error=0;
                for(int i=0;i<40;i++){
                    if(MoveFileExW(temporary,destination,0x1|0x8))return;
                    error=Marshal.GetLastWin32Error();
                    if(error!=5 && error!=32 && error!=33 && error!=183)break;
                    Thread.Sleep(25);
                }
                throw new System.ComponentModel.Win32Exception(error,"Cannot publish JSON: "+destination);
            }finally{if(File.Exists(temporary)){try{File.Delete(temporary);}catch{}}}
        }
    }
}
