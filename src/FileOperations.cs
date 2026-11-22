using System;
using System.IO;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.ComponentModel;
using System.Security.AccessControl;
using System.Text;

namespace SmartClean {
    public sealed class FileStamp {
        public string Path,Identity,SHA256,ContentHash,Security;public long Length,LastWriteTicks,CreationTicks,AccessTicks,TotalBytes;public uint Links,Attributes;
        public int SchemaVersion=2; public StreamStamp[] Streams;
    }
    public sealed class StreamStamp { public string Name,SHA256; public long Length;
    }
    public sealed class FileListing { public string[] Files,Skipped,Errors;public bool Limited; }
    public static partial class FileOperations {
        [StructLayout(LayoutKind.Sequential)] private struct Info {
            public uint Attributes;public System.Runtime.InteropServices.ComTypes.FILETIME Creation,Access,Write;
            public uint Volume,HighSize,LowSize,Links,HighIndex,LowIndex;
        }
        [DllImport("kernel32.dll",SetLastError=true)]private static extern bool GetFileInformationByHandle(SafeFileHandle handle,out Info info);
        public static Action Checkpoint;
        private static long lastCheck;private static int checkSteps;
        private static void Check(string cancelFile) {
            long now=System.Diagnostics.Stopwatch.GetTimestamp();if(++checkSteps<256&&now-lastCheck<System.Diagnostics.Stopwatch.Frequency/10)return;checkSteps=0;lastCheck=now;
            if(!String.IsNullOrEmpty(cancelFile)&&File.Exists(cancelFile))throw new OperationCanceledException();
            if(Checkpoint!=null)Checkpoint();
        }
        [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct StreamData {
            public long Size; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=296)] public string Name;
        }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern IntPtr FindFirstStreamW(string path,int level,out StreamData data,uint flags);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool FindNextStreamW(IntPtr handle,out StreamData data);
        [DllImport("kernel32.dll")] private static extern bool FindClose(IntPtr handle);
        private delegate uint CopyProgress(long total,long transferred,long streamSize,long streamTransferred,uint streamNumber,uint reason,IntPtr source,IntPtr destination,IntPtr state);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool CopyFileExW(string source,string destination,CopyProgress progress,IntPtr state,ref int cancel,uint flags);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]private static extern bool GetDiskFreeSpaceW(string root,out uint sectors,out uint bytes,out uint free,out uint total);
        public static long RequiredCopyBytes(FileStamp stamp,string destination){uint sectors,bytes,free,total;if(!GetDiskFreeSpaceW(System.IO.Path.GetPathRoot(destination),out sectors,out bytes,out free,out total))throw new Win32Exception(Marshal.GetLastWin32Error());long cluster=(long)sectors*bytes;if(cluster<=0)throw new IOException("Неизвестен размер кластера назначения.");long required=0;checked{foreach(var stream in stamp.Streams)required+=((stream.Length+cluster-1)/cluster)*cluster;}return required;}
        public static void AssertSupported(string source,string destination,FileStamp stamp) {
            if(stamp.SchemaVersion!=2 || stamp.Streams==null)throw new IOException("Требуется новый полный отпечаток файла.");
            if((stamp.Attributes & (uint)(FileAttributes.ReadOnly|FileAttributes.Encrypted|FileAttributes.SparseFile|FileAttributes.Compressed))!=0)
                throw new IOException("ReadOnly/Encrypted/Sparse/Compressed: перенос без изменения свойств не поддерживается; источник сохранён.");
            foreach(string path in new[]{source,destination}) {
                if(String.IsNullOrEmpty(path))continue;
                var drive=new DriveInfo(System.IO.Path.GetPathRoot(path));
                if(!drive.IsReady || !String.Equals(drive.DriveFormat,"NTFS",StringComparison.OrdinalIgnoreCase))throw new IOException("Полное сохранение свойств поддерживается только для локальных NTFS-томов.");
            }
        }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]private static extern SafeFileHandle CreateFileW(string name,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
        [DllImport("kernel32.dll",SetLastError=true)]private static extern bool SetFileInformationByHandle(SafeFileHandle handle,int kind,ref int value,uint length);
        private const uint GenericRead=0x80000000, GenericWrite=0x40000000, DeleteAccess=0x00010000;
        private const uint ShareRead=1, ShareDelete=4, OpenExisting=3, OpenReparsePoint=0x00200000;
        private static SafeFileHandle OpenNative(string path,uint access,uint sharing) {
            SafeFileHandle handle=CreateFileW(path,access,sharing,IntPtr.Zero,OpenExisting,OpenReparsePoint,IntPtr.Zero);
            if(handle.IsInvalid){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}
            return handle;
        }
        private static FileStream OpenNamedStream(string path,FileAccess access) {
            SafeFileHandle handle=OpenNative(path,access==FileAccess.Read?GenericRead:GenericWrite,ShareRead|ShareDelete);
            try{return new FileStream(handle,access,1048576,false);}
            catch{handle.Dispose();throw;}
        }
        private static string GetIdentity(Info info) {
            return info.Volume.ToString("x8")+":"+info.HighIndex.ToString("x8")+info.LowIndex.ToString("x8");
        }
        private static void AssertHandleIdentity(SafeFileHandle handle,FileStamp stamp) {
            Info info;
            if(!GetFileInformationByHandle(handle,out info))throw new Win32Exception(Marshal.GetLastWin32Error());
            if(GetIdentity(info)!=stamp.Identity||(info.Attributes & (uint)FileAttributes.ReparsePoint)!=0)
                throw new IOException("Файл по пути был заменён.");
        }
        private sealed class FileReadGuard : IDisposable {
            private readonly List<SafeFileHandle> handles=new List<SafeFileHandle>();
            public FileReadGuard(string path,FileStamp expected,uint sharing) {
                try{
                    var main=OpenNative(path,GenericRead,sharing);
                    handles.Add(main);
                    AssertHandleIdentity(main,expected);
                    foreach(var stream in expected.Streams)
                        if(stream.Name!="::$DATA")handles.Add(OpenNative(path+stream.Name,GenericRead,sharing));
                }catch{Dispose();throw;}
            }
            public void Dispose(){foreach(var handle in handles)handle.Dispose();}
        }
        public static FileStamp FinishPublishedMove(string source,string destination,FileStamp expected,FileStamp published,string cancelFile,Action authorizeDelete) {
            if(authorizeDelete==null)throw new IOException("Требуется исполнитель v2.");
            AssertSupported(source,destination,expected);
            using(var guard=new FileReadGuard(destination,published,ShareRead)){
                var actual=Describe(destination,true,cancelFile);
                if(!SameStamp(actual,published,true)||!SameStamp(actual,expected,false))
                    throw new IOException("Опубликованная копия изменилась; источник сохранён.");
                DeleteVerified(source,expected,cancelFile,authorizeDelete);
                return actual;
            }
        }
        public static void DeleteVerified(string source,FileStamp expected,string cancelFile,Action authorizeDelete) {
            if(authorizeDelete==null)throw new IOException("Требуется исполнитель v2.");
            using(var handle=OpenNative(source,GenericRead|DeleteAccess,ShareRead))
            using(var guard=new FileReadGuard(source,expected,ShareRead|ShareDelete)){
                AssertHandleIdentity(handle,expected);
                if(!SameStamp(Describe(source,true,cancelFile),expected,true))throw new IOException("Источник изменился; удаление отменено.");
                if(!String.IsNullOrEmpty(cancelFile)&&File.Exists(cancelFile))throw new OperationCanceledException();
                authorizeDelete();
                AssertHandleIdentity(handle,expected);
                int delete=1;
                if(!SetFileInformationByHandle(handle,4,ref delete,4))throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
        public static bool SameContent(FileStamp a,FileStamp b) {return a!=null&&b!=null&&a.Streams!=null&&b.Streams!=null&&a.ContentHash==b.ContentHash;}
        public static bool SameStamp(FileStamp a,FileStamp b,bool identity) {
            return SameContent(a,b)&&(!identity||a.Identity==b.Identity)&&a.Length==b.Length&&a.LastWriteTicks==b.LastWriteTicks&&a.CreationTicks==b.CreationTicks&&a.Attributes==b.Attributes&&a.Security==b.Security&&(!identity||a.Links==b.Links);
        }
        [ThreadStatic] private static byte[] hashBuffer;
        private static string Hash(Stream stream,string cancelFile) {
            using(var sha=SHA256.Create()) {
                byte[] buffer=hashBuffer??(hashBuffer=new byte[1048576]);int n;
                while((n=stream.Read(buffer,0,buffer.Length))>0){Check(cancelFile);sha.TransformBlock(buffer,0,n,buffer,0);}
                sha.TransformFinalBlock(new byte[0],0,0);return BitConverter.ToString(sha.Hash).Replace("-","").ToLowerInvariant();
            }
        }
        public static FileStamp Describe(string path,bool hash) {
            return Describe(path,hash,null);
        }
        public static FileStamp Describe(string path,bool hash,string cancelFile) {
            Check(cancelFile);var attributes=File.GetAttributes(path);
            if((attributes&(FileAttributes.Directory|FileAttributes.ReparsePoint))!=0 || ((uint)attributes&0x00441000)!=0)throw new IOException("Not a regular local file / offline placeholder: "+path);
            using(var file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete,1048576,FileOptions.SequentialScan)) {
                Info i;if(!GetFileInformationByHandle(file.SafeFileHandle,out i))throw new Win32Exception(Marshal.GetLastWin32Error());
                var stamp=new FileStamp{Path=System.IO.Path.GetFullPath(path),Identity=GetIdentity(i),Length=file.Length,LastWriteTicks=File.GetLastWriteTimeUtc(path).Ticks,CreationTicks=File.GetCreationTimeUtc(path).Ticks,AccessTicks=File.GetLastAccessTimeUtc(path).Ticks,Links=i.Links,Attributes=(uint)attributes};
                if(!hash)return stamp;
                stamp.Security=File.GetAccessControl(path,AccessControlSections.Access|AccessControlSections.Owner|AccessControlSections.Group).GetSecurityDescriptorSddlForm(AccessControlSections.Access|AccessControlSections.Owner|AccessControlSections.Group);
                var streams=new List<StreamStamp>();
                streams.Add(new StreamStamp{Name="::$DATA",Length=file.Length,SHA256=Hash(file,cancelFile)});
                StreamData data;IntPtr handle=FindFirstStreamW(path,0,out data,0);
                if(handle==new IntPtr(-1)) {int error=Marshal.GetLastWin32Error();if(error!=38)throw new Win32Exception(error,"Нельзя перечислить все потоки файла.");}
                else try {
                    do {
                        Check(cancelFile);
                        if(data.Name=="::$DATA")continue;
                        if(!data.Name.EndsWith(":$DATA",StringComparison.Ordinal))throw new IOException("Неизвестный тип потока файла.");
                        using(var stream=OpenNamedStream(path+data.Name,FileAccess.Read))
                            streams.Add(new StreamStamp{Name=data.Name,Length=stream.Length,SHA256=Hash(stream,cancelFile)});
                    }while(FindNextStreamW(handle,out data));
                    int error=Marshal.GetLastWin32Error();if(error!=38)throw new Win32Exception(error);
                } finally {FindClose(handle);}
                streams.Sort(delegate(StreamStamp x,StreamStamp y){return StringComparer.Ordinal.Compare(x.Name,y.Name);});
                var manifest=new StringBuilder();foreach(var stream in streams){stamp.TotalBytes+=stream.Length;manifest.Append(stream.Name.Length).Append(':').Append(stream.Name).Append(':').Append(stream.Length).Append(':').Append(stream.SHA256).Append(';');}
                using(var sha=SHA256.Create())stamp.ContentHash=BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(manifest.ToString()))).Replace("-","").ToLowerInvariant();
                stamp.SHA256=streams.Find(delegate(StreamStamp v){return v.Name=="::$DATA";}).SHA256;stamp.Streams=streams.ToArray();return stamp;
            }
        }
        public static IEnumerable<string> Enumerate(string[] roots,string[] excludedSegments,string[] excludedRoots,int limit,string cancelFile,Action<string,string,string> diagnostic) {
            var blocked=new HashSet<string>(excludedSegments,StringComparer.OrdinalIgnoreCase);var stack=new Stack<string>();var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);int count=0;
            foreach(string root in roots)stack.Push(System.IO.Path.GetFullPath(root));
            while(stack.Count>0){Check(cancelFile);string path=stack.Pop();if(!seen.Add(path))continue;
                bool excluded=false;foreach(string x in excludedRoots)if(path.Equals(x.TrimEnd('\\'),StringComparison.OrdinalIgnoreCase)||path.StartsWith(x.TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase)){excluded=true;break;}
                FileAttributes attributes=0;Exception error=null;try{attributes=File.GetAttributes(path);}catch(Exception e){error=e;}
                if(error!=null){diagnostic("Error",path,error.Message);continue;}
                if(excluded||(attributes&FileAttributes.ReparsePoint)!=0||((uint)attributes&0x00441000)!=0||blocked.Contains(System.IO.Path.GetFileName(path))){diagnostic("Skipped",path,"Защита, исключение, ссылка или нелокальные данные");continue;}
                if((attributes&FileAttributes.Directory)==0){if(count>=limit){diagnostic("Limit",path,"Достигнут предел обнаружения; остаток неизвестен");yield break;}count++;yield return path;continue;}
                IEnumerator<FileSystemInfo> iterator=null;try{iterator=new DirectoryInfo(path).EnumerateFileSystemInfos().GetEnumerator();}catch(Exception e){error=e;}
                if(error!=null){diagnostic("Error",path,error.Message);continue;}
                using(iterator){while(true){Check(cancelFile);bool more=false;FileSystemInfo entry=null;error=null;try{more=iterator.MoveNext();if(more)entry=iterator.Current;}catch(Exception e){error=e;}
                    if(error!=null){diagnostic("Error",path,error.Message);break;}if(!more)break;
                    FileAttributes a=0;try{a=entry.Attributes;}catch(Exception e){diagnostic("Error",entry.FullName,e.Message);continue;}
                    bool skip=(a&FileAttributes.ReparsePoint)!=0||((uint)a&0x00441000)!=0||blocked.Contains(entry.Name);
                    foreach(string x in excludedRoots)if(entry.FullName.Equals(x.TrimEnd('\\'),StringComparison.OrdinalIgnoreCase)||entry.FullName.StartsWith(x.TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase)){skip=true;break;}
                    if(skip){diagnostic("Skipped",entry.FullName,"Защита, исключение, ссылка или нелокальные данные");continue;}
                    if((a&FileAttributes.Directory)!=0)stack.Push(entry.FullName);
                    else{if(count>=limit){diagnostic("Limit",entry.FullName,"Достигнут предел обнаружения; остаток неизвестен");yield break;}count++;yield return entry.FullName;}
                }}
            }
        }
        public static FileListing List(string[] roots,string[] excludedSegments,string[] excludedRoots,int limit,string cancelFile) {
            var files=new List<string>();var skipped=new List<string>();var errors=new List<string>();
            var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var stack=new Stack<string>();var blocked=new HashSet<string>(excludedSegments,StringComparer.OrdinalIgnoreCase);
            foreach(string root in roots){string full=System.IO.Path.GetFullPath(root);if(File.Exists(full))files.Add(full);else stack.Push(full);}
            bool limited=false;
            while(stack.Count>0 && !limited){
                Check(cancelFile);
                string p=stack.Pop();if(!seen.Add(p))continue;
                bool excluded=false;foreach(string x in excludedRoots)if(p.Equals(x.TrimEnd('\\'),StringComparison.OrdinalIgnoreCase)||p.StartsWith(x.TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase)){excluded=true;break;}
                if(excluded){if(skipped.Count<500)skipped.Add(p);continue;}
                try{
                    foreach(var entry in new DirectoryInfo(p).EnumerateFileSystemInfos()){
                        Check(cancelFile);
                        try{
                            var a=entry.Attributes;
                            if((a&FileAttributes.ReparsePoint)!=0 || ((uint)a&0x00441000)!=0 || blocked.Contains(entry.Name)){if(skipped.Count<500)skipped.Add(entry.FullName);continue;}
                            if((a&FileAttributes.Directory)!=0)stack.Push(entry.FullName);
                            else{files.Add(entry.FullName);if(files.Count>=limit){limited=true;break;}}
                        }catch(OperationCanceledException){throw;}catch(Exception ex){if(errors.Count<500)errors.Add(entry.FullName+": "+ex.Message);}
                    }
                }catch(OperationCanceledException){throw;}catch(Exception ex){if(errors.Count<500)errors.Add(p+": "+ex.Message);}
            }
            return new FileListing{Files=files.ToArray(),Skipped=skipped.ToArray(),Errors=errors.ToArray(),Limited=limited};
        }
        public static FileStamp MoveVerified(string source,string destination,FileStamp expected,string cancelFile) {
            return MoveVerified(source,destination,expected,cancelFile,null,null);
        }
        public static FileStamp MoveVerified(string source,string destination,FileStamp expected,string cancelFile,Action<string,FileStamp,string> phase,Action authorizeDelete) {
            if(phase==null||authorizeDelete==null)throw new IOException("Перенос требует журнала фаз и согласования v2.");
            AssertSupported(source,destination,expected);Check(cancelFile);
            FileStamp before=Describe(source,true,cancelFile);
            if(!SameStamp(before,expected,true))throw new IOException("Source changed since plan: "+source);
            if(File.Exists(destination)||Directory.Exists(destination))throw new IOException("Destination already exists: "+destination);
            string temporary=destination+".smartclean-"+Guid.NewGuid().ToString("N")+".partial";
            bool published=false;
            if(phase!=null)phase("Prepared",before,temporary);
            try {
                Exception callbackError=null;
                CopyProgress callback=delegate(long total,long transferred,long streamSize,long streamTransferred,uint streamNumber,uint reason,IntPtr src,IntPtr dst,IntPtr state){
                    try{Check(cancelFile);return 0;}catch(Exception e){callbackError=e;return 1;}
                };
                FileStamp copy;
                using(var guard=new FileReadGuard(source,expected,ShareRead)) {
                    int cancelled=0;
                    if(!CopyFileExW(source,temporary,callback,IntPtr.Zero,ref cancelled,1)) {if(callbackError!=null)throw callbackError;throw new Win32Exception(Marshal.GetLastWin32Error());}
                    foreach(var stream in expected.Streams){string streamPath=stream.Name=="::$DATA"?temporary:temporary+stream.Name;using(var flush=OpenNamedStream(streamPath,FileAccess.Write)){flush.Flush(true);}}
                    if(phase!=null)phase("CopyWritten",null,temporary);
                    File.SetCreationTimeUtc(temporary,new DateTime(expected.CreationTicks,DateTimeKind.Utc));
                    File.SetLastWriteTimeUtc(temporary,new DateTime(expected.LastWriteTicks,DateTimeKind.Utc));
                    var acl=new FileSecurity();acl.SetSecurityDescriptorSddlForm(expected.Security);File.SetAccessControl(temporary,acl);
                    File.SetAttributes(temporary,(FileAttributes)expected.Attributes);
                    copy=Describe(temporary,true,cancelFile);
                    if(!SameStamp(copy,expected,false))throw new IOException("Полный состав или свойства копии не совпадают; источник сохранён.");
                    File.SetLastAccessTimeUtc(temporary,new DateTime(expected.AccessTicks,DateTimeKind.Utc));
                    if(File.GetLastAccessTimeUtc(temporary).Ticks!=expected.AccessTicks)
                        throw new IOException("Не удалось сохранить время последнего доступа.");
                    if(phase!=null)phase("CopyVerified",copy,temporary);
                    if(!SameStamp(Describe(source,true,cancelFile),expected,true))throw new IOException("Source changed while copying.");
                    if(phase!=null)phase("PublishIntent",copy,temporary);
                    File.Move(temporary,destination);published=true;
                    if(phase!=null)phase("DestinationPublished",copy,temporary);
                }
                var verified=FinishPublishedMove(source,destination,expected,copy,cancelFile,delegate(){
                    authorizeDelete();
                    phase("SourceDeleteAuthorized",copy,temporary);
                });
                phase("SourceRemoved",verified,temporary);
                return verified;
            }catch {
                // Once a phase is durable, recovery owns the artifact; never erase its evidence here.
                if(phase==null&&!published&&File.Exists(temporary)){try{File.Delete(temporary);}catch{}}
                throw;
            }
        }
        public static FileStamp MoveDuplicate(string source,string destination,FileStamp expected,string keeper,FileStamp keeperStamp,string cancelFile) {return MoveDuplicate(source,destination,expected,keeper,keeperStamp,cancelFile,null,null);}
        public static FileStamp MoveDuplicate(string source,string destination,FileStamp expected,string keeper,FileStamp keeperStamp,string cancelFile,Action<string,FileStamp,string> phase,Action authorizeDelete) {
            using(var keeperGuard=new FileReadGuard(keeper,keeperStamp,ShareRead)){
            if(!SameContent(Describe(keeper,true,cancelFile),expected))throw new IOException("Дополнительные потоки сохраняемой копии отличаются.");
            FileStamp currentKeeper=Describe(keeper,false,cancelFile);
            if(currentKeeper.Identity!=keeperStamp.Identity||currentKeeper.LastWriteTicks!=keeperStamp.LastWriteTicks)throw new IOException("Retained copy identity changed");
            using(var reference=new FileStream(keeper,FileMode.Open,FileAccess.Read,FileShare.Read,1048576,FileOptions.SequentialScan)) {
                if(Hash(reference,cancelFile)!=keeperStamp.SHA256 || reference.Length!=keeperStamp.Length)throw new IOException("Retained copy changed");
                reference.Position=0;
                using(var input=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.Read,1048576,FileOptions.SequentialScan)) {
                    byte[] a=new byte[1048576],b=new byte[1048576];int n;
                    while((n=input.Read(a,0,a.Length))>0){
                        if(!String.IsNullOrEmpty(cancelFile)&&File.Exists(cancelFile))throw new OperationCanceledException();
                        int count=0,k;while(count<n && (k=reference.Read(b,count,n-count))>0)count+=k;
                        if(count!=n)throw new IOException("Retained copy size differs");
                        for(int i=0;i<n;i++)if(a[i]!=b[i])throw new IOException("Files differ byte-for-byte");
                    }
                    if(reference.ReadByte()!=-1)throw new IOException("Retained copy has extra data");
                }
                return MoveVerified(source,destination,expected,cancelFile,phase,authorizeDelete);
            }
            }
        }
    }
}
