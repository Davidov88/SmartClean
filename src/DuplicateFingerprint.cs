using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace SmartClean {
    public sealed class DuplicateFingerprint {
        public string Hash, Volume, Identity;
        public long Length, Bytes;
        public bool Cached;
    }

    public sealed class DuplicateHashCache : IDisposable {
        private const int ShardLimit=256, Batch=64;
        private readonly string directory;
        private readonly Dictionary<string,Dictionary<string,string>> shards=new Dictionary<string,Dictionary<string,string>>();
        private readonly Dictionary<string,List<string>> pending=new Dictionary<string,List<string>>();
        private int updates;

        public DuplicateHashCache(string directory) {
            this.directory=directory;
            Directory.CreateDirectory(directory);
        }
        private Dictionary<string,string> ReadShard(string shard) {
            Dictionary<string,string> entries;
            if(shards.TryGetValue(shard,out entries))return entries;
            entries=new Dictionary<string,string>(StringComparer.Ordinal);
            string path=Path.Combine(directory,shard+".txt");
            if(IsSafeShard(path)&&File.Exists(path)&&new FileInfo(path).Length<=ShardLimit*264L){
                foreach(string line in File.ReadLines(path,Encoding.ASCII)){
                    if(line.Length==129&&line[64]==' '&&IsHash(line,0)&&IsHash(line,65))
                        Remember(entries,line.Substring(0,64),line.Substring(65));
                }
            }
            shards.Add(shard,entries);
            return entries;
        }
        private static bool IsSafeShard(string path) {
            return !File.Exists(path)||(File.GetAttributes(path)&FileAttributes.ReparsePoint)==0;
        }
        private static bool IsHash(string value,int start) {
            for(int i=start;i<start+64;i++){char c=value[i];if(!(c>='0'&&c<='9')&&!(c>='a'&&c<='f'))return false;}
            return true;
        }
        internal string Find(string key) {
            string value;
            return ReadShard(key.Substring(0,2)).TryGetValue(key,out value)?value:null;
        }
        private static void Remember(Dictionary<string,string> entries,string key,string value) {
            if(!entries.ContainsKey(key)&&entries.Count>=ShardLimit){
                string evict=null;
                foreach(string old in entries.Keys){evict=old;break;}
                if(evict!=null)entries.Remove(evict);
            }
            entries[key]=value;
        }
        internal void Store(string key,string hash) {
            string shard=key.Substring(0,2);
            Remember(ReadShard(shard),key,hash);
            List<string> writes;
            if(!pending.TryGetValue(shard,out writes)){writes=new List<string>();pending.Add(shard,writes);}
            writes.Add(key+" "+hash);
            if(++updates>=Batch)Flush();
        }
        public void Flush() {
            foreach(var batch in pending){
                string target=Path.Combine(directory,batch.Key+".txt");
                if(!IsSafeShard(target))continue;
                var output=new StringBuilder();
                foreach(string line in batch.Value)output.Append(line).Append('\n');
                byte[] records=Encoding.ASCII.GetBytes(output.ToString());
                long current=File.Exists(target)?new FileInfo(target).Length:0;
                if(current+records.Length+1<=ShardLimit*264L){
                    using(var file=new FileStream(target,FileMode.Append,FileAccess.Write,FileShare.Read)){
                        // A separator protects later records if the preceding process stopped mid-record.
                        file.WriteByte((byte)'\n');
                        file.Write(records,0,records.Length);file.Flush(true);
                    }
                    continue;
                }
                output.Clear();
                foreach(var item in shards[batch.Key])output.Append(item.Key).Append(' ').Append(item.Value).Append('\n');
                string temporary=target+"."+Guid.NewGuid().ToString("N")+".tmp";
                try{
                    using(var file=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)){
                        var bytes=Encoding.ASCII.GetBytes(output.ToString());
                        file.Write(bytes,0,bytes.Length);file.Flush(true);
                    }
                    File.Replace(temporary,target,null);
                }finally{if(File.Exists(temporary))File.Delete(temporary);}
            }
            pending.Clear();updates=0;
        }
        public void Dispose(){Flush();}
    }

    public static partial class FileOperations {
        private const int QuickBlock=65536;
        private const uint QueryJournal=0x000900f4, ReadFileUsn=0x000900eb;
        private const uint NamedStreamsFlag=0x00040000;

        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)]
        private static extern bool GetVolumeNameForVolumeMountPointW(string root,StringBuilder name,int length);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)]
        private static extern bool GetVolumeInformationW(string root,IntPtr label,int labelLength,out uint serial,out uint componentLength,out uint flags,StringBuilder fileSystem,int length);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle file,StringBuilder path,uint capacity,uint flags);
        [DllImport("kernel32.dll",SetLastError=true)]
        private static extern bool DeviceIoControl(SafeFileHandle device,uint code,IntPtr input,uint inputSize,byte[] output,uint outputSize,out uint bytes,IntPtr overlapped);
        [DllImport("kernel32.dll",SetLastError=true)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle file,int kind,out FileBasicInfo info,uint size);
        [StructLayout(LayoutKind.Sequential)]
        private struct FileBasicInfo {
            public long Creation,Access,Write,Change;
            public uint Attributes;
        }
        private sealed class OpenStream : IDisposable {
            public string Name;
            public FileStream Stream;
            public void Dispose(){Stream.Dispose();}
        }
        private static string HexDigest(string value) {
            using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(value))).Replace("-","").ToLowerInvariant();
        }
        private static Info ReadHandleInfo(SafeFileHandle handle) {
            Info info;
            if(!GetFileInformationByHandle(handle,out info))throw new Win32Exception(Marshal.GetLastWin32Error());
            return info;
        }
        private static string StableInfo(Info info) {
            return String.Format(CultureInfo.InvariantCulture,"{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}",GetIdentity(info),info.HighSize,info.LowSize,
                info.Creation.dwHighDateTime,info.Creation.dwLowDateTime,info.Write.dwHighDateTime,info.Write.dwLowDateTime,info.Links);
        }
        private static string VolumeFromHandle(SafeFileHandle file) {
            var name=new StringBuilder(512);
            uint length=GetFinalPathNameByHandleW(file,name,(uint)name.Capacity,9);
            if(length>=name.Capacity&&length<=32767){
                name.Capacity=(int)length+1;
                length=GetFinalPathNameByHandleW(file,name,(uint)name.Capacity,9);
            }
            if(length==0||length>=name.Capacity)return null;
            string value=name.ToString();
            int end=value.IndexOf('}',10);
            if(!value.StartsWith(@"\\?\Volume{",StringComparison.OrdinalIgnoreCase)||end<0||end+1>=value.Length||value[end+1]!='\\')return null;
            return value.Substring(0,end+2);
        }
        private static string TryJournalToken(SafeFileHandle file,string volume) {
            if(String.IsNullOrEmpty(volume))return null;
            // A missing or inaccessible journal disables digest reuse for this file.
            using(var handle=CreateFileW(volume.TrimEnd('\\'),0,7,IntPtr.Zero,OpenExisting,0,IntPtr.Zero)){
                if(handle.IsInvalid)return null;
                byte[] journal=new byte[128],record=new byte[1024];uint count;
                if(!DeviceIoControl(handle,QueryJournal,IntPtr.Zero,0,journal,(uint)journal.Length,out count,IntPtr.Zero)||count<40)return null;
                ulong journalId=BitConverter.ToUInt64(journal,0);
                long lower=Math.Max(BitConverter.ToInt64(journal,8),BitConverter.ToInt64(journal,24));
                long next=BitConverter.ToInt64(journal,16);
                if(!DeviceIoControl(file,ReadFileUsn,IntPtr.Zero,0,record,(uint)record.Length,out count,IntPtr.Zero)||count<60||
                    BitConverter.ToUInt16(record,4)!=2||BitConverter.ToUInt32(record,0)<60||BitConverter.ToUInt32(record,0)>count)return null;
                long usn=BitConverter.ToInt64(record,24);
                if(usn<lower||usn>=next)return null;
                FileBasicInfo basic;
                if(!GetFileInformationByHandleEx(file,0,out basic,(uint)Marshal.SizeOf(typeof(FileBasicInfo))))return null;
                return String.Format(CultureInfo.InvariantCulture,"{0:x16}|{1:x16}|{2:x16}",journalId,usn,basic.Change);
            }
        }
        private static List<string> DuplicateStreamNames(string path,bool supportsStreams,string cancelFile) {
            var names=new List<string>{"::$DATA"};
            if(supportsStreams){
                StreamData data;IntPtr find=FindFirstStreamW(path,0,out data,0);
                if(find==new IntPtr(-1)){int error=Marshal.GetLastWin32Error();if(error!=38)throw new Win32Exception(error);}
                else try{
                    do{
                        Check(cancelFile);
                        if(data.Name=="::$DATA")continue;
                        if(names.Count>=4096)throw new IOException("Слишком много потоков для безопасного сравнения.");
                        if(!data.Name.EndsWith(":$DATA",StringComparison.Ordinal))throw new IOException("Неизвестный тип потока.");
                        names.Add(data.Name);
                    }while(FindNextStreamW(find,out data));
                    int last=Marshal.GetLastWin32Error();if(last!=38)throw new Win32Exception(last);
                }finally{FindClose(find);}
            }
            names.Sort(StringComparer.Ordinal);
            return names;
        }
        private static string Sample(Stream file,string cancelFile) {
            using(var sha=SHA256.Create()){
                byte[] part=new byte[QuickBlock];
                long last=Math.Max(0,file.Length-QuickBlock);
                foreach(long offset in new[]{0L,Math.Max(0,(file.Length-QuickBlock)/2),last}){
                    Check(cancelFile);file.Position=offset;
                    int length=0,n;
                    while(length<part.Length&&(n=file.Read(part,length,part.Length-length))>0)length+=n;
                    sha.TransformBlock(part,0,length,part,0);
                }
                sha.TransformFinalBlock(new byte[0],0,0);
                return BitConverter.ToString(sha.Hash).Replace("-","").ToLowerInvariant();
            }
        }
        public static DuplicateFingerprint GetDuplicateFingerprint(string path,long expectedLength,string expectedIdentity,bool sample,DuplicateHashCache cache,string cancelFile) {
            Check(cancelFile);
            string root=Path.GetPathRoot(path);
            uint serial,componentLength,flags;
            var fs=new StringBuilder(32);var volume=new StringBuilder(64);
            if(!GetVolumeInformationW(root,IntPtr.Zero,0,out serial,out componentLength,out flags,fs,fs.Capacity))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            string volumeId=GetVolumeNameForVolumeMountPointW(root,volume,volume.Capacity)?volume.ToString():null;
            bool ntfs=String.Equals(fs.ToString(),"NTFS",StringComparison.OrdinalIgnoreCase);
            bool supportsStreams=(flags&NamedStreamsFlag)!=0;
            using(var handle=OpenNative(path,GenericRead,ShareRead))
            using(var file=new FileStream(handle,FileAccess.Read,65536,false)){
                volumeId=VolumeFromHandle(handle)??volumeId;
                var before=ReadHandleInfo(handle);
                var result=new DuplicateFingerprint{Volume=volumeId,Identity=(volumeId??root.ToUpperInvariant())+"|"+GetIdentity(before),Length=file.Length,Bytes=file.Length};
                if((before.Attributes&0x00441410U)!=0||result.Length!=expectedLength||GetIdentity(before)!=expectedIdentity)
                    throw new IOException("Файл изменился или стал недоступен после обхода.");
                if(sample){
                    result.Hash=Sample(file,cancelFile);
                    if(StableInfo(before)!=StableInfo(ReadHandleInfo(handle)))throw new IOException("Файл изменился во время чтения выборки.");
                    return result;
                }
                var names=DuplicateStreamNames(path,supportsStreams,cancelFile);
                var opened=new List<OpenStream>();
                try{
                    foreach(string name in names){
                        if(name=="::$DATA")continue;
                        var stream=OpenNamedStream(path+name,FileAccess.Read);
                        opened.Add(new OpenStream{Name=name,Stream=stream});
                        result.Bytes+=stream.Length;
                    }
                    string journal=cache!=null&&ntfs?TryJournalToken(handle,volumeId):null;
                    var layout=new StringBuilder();
                    foreach(var stream in opened)layout.Append(stream.Name.Length).Append(':').Append(stream.Name).Append(':').Append(stream.Stream.Length).Append(';');
                    string stable=StableInfo(before);
                    string key=journal==null?null:HexDigest("SC-DUP-1|"+volumeId+"|"+stable+"|"+journal+"|"+layout);
                    result.Hash=key==null?null:cache.Find(key);
                    result.Cached=result.Hash!=null;
                    if(!result.Cached){
                        var manifest=new StringBuilder();
                        foreach(string name in names){
                            Stream stream=file;
                            if(name!="::$DATA")stream=opened.Find(delegate(OpenStream item){return item.Name==name;}).Stream;
                            manifest.Append(name.Length).Append(':').Append(name).Append(':').Append(stream.Length).Append(':').Append(Hash(stream,cancelFile)).Append(';');
                        }
                        result.Hash=HexDigest(manifest.ToString());
                    }
                    var finalNames=DuplicateStreamNames(path,supportsStreams,cancelFile);
                    if(!String.Equals(String.Join("\0",names),String.Join("\0",finalNames),StringComparison.Ordinal)||
                        stable!=StableInfo(ReadHandleInfo(handle)))throw new IOException("Файл или его потоки изменились во время сравнения.");
                    if(key!=null&&journal!=TryJournalToken(handle,volumeId)){
                        if(result.Cached)throw new IOException("Запись журнала изменилась. Повторите сравнение.");
                    }else if(key!=null&&!result.Cached)cache.Store(key,result.Hash);
                    return result;
                }finally{foreach(var stream in opened)stream.Dispose();}
            }
        }
    }
}
