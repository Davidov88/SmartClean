using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;

namespace SmartClean {
    public sealed class Node {
        public long Id, ParentId, LogicalBytes, AllocatedBytes, UniqueAllocatedBytes, Files, Folders;
        public string Path, Attributes, Identity;
        public byte Kind; // 1 directory, 2 file, 3 excluded link
    }
    public sealed class ImportResult {
        public long Nodes, Files, Directories, Links, HardlinkDuplicates, UnknownIdentities;
        public long LogicalBytes, AllocatedBytes, UniqueAllocatedBytes;
    }
    public sealed class RuleHit { public int RuleIndex; public Node Node; }
    public sealed class Inspection {
        public Node[] TopFiles, Links;
        public RuleHit[] Candidates;
        public long Examined, LinkCount, CandidateCount;
    }
    internal sealed class DirectoryEntry {
        public long Id, Parent, Logical, Allocated, Unique, Files, Folders;
        public int ChildCount;
    }
    internal sealed class ImportDirectories : IDisposable {
        private readonly FileStream rows;
        private readonly BinaryReader rowReader;
        private readonly BinaryWriter rowWriter;
        private readonly string directory;
        private readonly Action checkpoint;
        private FileStream lookup;
        private BinaryReader lookupReader;
        private BinaryWriter lookupWriter;
        private int capacity=1024;
        private const int RowSize=60;
        public int Count {get;private set;}
        public ImportDirectories(string directory,Action checkpoint) {
            this.directory=directory;this.checkpoint=checkpoint;
            rows=File.Create(Path.Combine(directory,"directory-rows.bin"));
            rowReader=new BinaryReader(rows,Encoding.UTF8);rowWriter=new BinaryWriter(rows,Encoding.UTF8);
            OpenLookup("directory-lookup-a.bin");
        }
        private void OpenLookup(string name){
            lookup=File.Create(Path.Combine(directory,name));
            lookup.SetLength(capacity*16L);
            lookupReader=new BinaryReader(lookup,Encoding.UTF8);
            lookupWriter=new BinaryWriter(lookup,Encoding.UTF8);
        }
        public DirectoryEntry Read(long row) {
            rows.Position=row*RowSize;
            return new DirectoryEntry{Id=rowReader.ReadInt64(),Parent=rowReader.ReadInt64(),Logical=rowReader.ReadInt64(),Allocated=rowReader.ReadInt64(),Unique=rowReader.ReadInt64(),Files=rowReader.ReadInt64(),Folders=rowReader.ReadInt64(),ChildCount=rowReader.ReadInt32()};
        }
        public void Write(long row,DirectoryEntry entry){
            rows.Position=row*RowSize;
            rowWriter.Write(entry.Id);rowWriter.Write(entry.Parent);rowWriter.Write(entry.Logical);rowWriter.Write(entry.Allocated);rowWriter.Write(entry.Unique);rowWriter.Write(entry.Files);rowWriter.Write(entry.Folders);rowWriter.Write(entry.ChildCount);
        }
        private int FindSlot(ulong hash,Func<long,bool> matches,out long row){
            int slot=(int)(hash&(uint)(capacity-1));int inspected=0;
            while(inspected++<capacity){
                checkpoint();
                lookup.Position=slot*16L;
                ulong stored=lookupReader.ReadUInt64();long value=lookupReader.ReadInt64();
                if(value==0){row=-1;return slot;}
                if(stored==hash&&matches!=null&&matches(value-1)){row=value-1;return slot;}
                slot=(slot+1)&(capacity-1);
            }
            throw new InvalidDataException("Directory lookup is full");
        }
        private void SetSlot(int slot,ulong hash,long row){
            lookup.Position=slot*16L;lookupWriter.Write(hash);lookupWriter.Write(row+1);
        }
        public long Find(string path,Func<long,string> readPath){
            long row;
            FindSlot(Hash(path),delegate(long candidate){return String.Equals(path,readPath(Read(candidate).Id),StringComparison.OrdinalIgnoreCase);},out row);
            return row;
        }
        public void Add(string path,DirectoryEntry entry,Func<long,string> readPath){
            if(Count>=10000000)throw new InvalidDataException("Directory count exceeds index format limit");
            if(Count*2>=capacity)Grow();
            long existing;
            ulong hash=Hash(path);
            int slot=FindSlot(hash,delegate(long candidate){return String.Equals(path,readPath(Read(candidate).Id),StringComparison.OrdinalIgnoreCase);},out existing);
            if(existing>=0)throw new InvalidDataException("Duplicate directory: "+path);
            Write(Count,entry);SetSlot(slot,hash,Count);Count++;
        }
        private static ulong Hash(string path){
            unchecked{
                ulong hash=14695981039346656037UL;
                foreach(char ch in path){hash^=Char.ToUpperInvariant(ch);hash*=1099511628211UL;}
                return hash;
            }
        }
        private void Grow(){
            var old=lookup;var oldReader=lookupReader;var oldWriter=lookupWriter;
            string oldPath=old.Name;
            string next=oldPath.EndsWith("-a.bin",StringComparison.Ordinal)?"directory-lookup-b.bin":"directory-lookup-a.bin";
            capacity*=2;
            try{
                OpenLookup(next);old.Position=0;
                while(old.Position<old.Length){
                    checkpoint();ulong hash=oldReader.ReadUInt64();long value=oldReader.ReadInt64();
                    if(value==0)continue;
                    long unused;SetSlot(FindSlot(hash,null,out unused),hash,value-1);
                }
            }finally{oldWriter.Dispose();oldReader.Dispose();old.Dispose();}
            File.Delete(oldPath);
        }
        public void Dispose(){
            rowWriter.Dispose();rowReader.Dispose();rows.Dispose();
            lookupWriter.Dispose();lookupReader.Dispose();lookup.Dispose();
        }
    }
    // v3 stores fixed-width directory ranges and child offsets on disk.
    public sealed class SnapshotIndex : IDisposable {
        private readonly FileStream data;
        private readonly BinaryReader reader;
        private sealed class Range { public long Start;public int Count; }
        private readonly Dictionary<long,Range> children=new Dictionary<long,Range>();
        private readonly FileStream indexStream;private readonly BinaryReader indexReader;
        private readonly long rangeTable;
        private readonly int directoryCount;
        public static Action Checkpoint;
        private static long lastCheck;private static int checkSteps;
        private static void Check(){long now=System.Diagnostics.Stopwatch.GetTimestamp();if(++checkSteps<256&&now-lastCheck<System.Diagnostics.Stopwatch.Frequency/10)return;checkSteps=0;lastCheck=now;if(Checkpoint!=null)Checkpoint();}
        public long RootId { get { return 0; } }
        public SnapshotIndex(string directory) {
            data = new FileStream(System.IO.Path.Combine(directory, "nodes.bin"), FileMode.Open, FileAccess.Read, FileShare.Read);
            reader = new BinaryReader(data, Encoding.UTF8);
            indexStream=new FileStream(System.IO.Path.Combine(directory,"index.bin"),FileMode.Open,FileAccess.Read,FileShare.Read);indexReader=new BinaryReader(indexStream,Encoding.UTF8);
            try{
                string version=indexReader.ReadString();
                if(version!="SMARTCLEAN-INDEX-1"&&version!="SMARTCLEAN-INDEX-2"&&version!="SMARTCLEAN-INDEX-3")
                    throw new InvalidDataException("Unsupported index schema");
                directoryCount=indexReader.ReadInt32();
                if(directoryCount<1||directoryCount>10000000)throw new InvalidDataException("Invalid directory count");
                if(version=="SMARTCLEAN-INDEX-3"){
                    rangeTable=indexStream.Position;
                    if(rangeTable+directoryCount*20L>indexStream.Length)throw new InvalidDataException("Incomplete range table");
                }else{
                    for(int i=0;i<directoryCount;i++){
                        Check();long id=indexReader.ReadInt64();int count=indexReader.ReadInt32();
                        ValidateRange(indexStream.Position,count,0);
                        children.Add(id,new Range{Start=indexStream.Position,Count=count});
                        indexStream.Seek(count*8L,SeekOrigin.Current);
                    }
                }
            }catch{Dispose();throw;}
        }
        private void ValidateRange(long start,int count,long minimum) {
            if(count<0||count>100000000||start<minimum||start>indexStream.Length-count*8L)
                throw new InvalidDataException("Invalid child range");
        }
        private Range GetRange(long id) {
            if(rangeTable==0){Range range;return children.TryGetValue(id,out range)?range:null;}
            int low=0,high=directoryCount-1;
            while(low<=high){
                int mid=low+(high-low)/2;indexStream.Position=rangeTable+mid*20L;
                long found=indexReader.ReadInt64();
                if(found<id){low=mid+1;continue;}if(found>id){high=mid-1;continue;}
                long start=indexReader.ReadInt64();int count=indexReader.ReadInt32();
                ValidateRange(start,count,rangeTable+directoryCount*20L);
                return new Range{Start=start,Count=count};
            }
            return null;
        }
        private IEnumerable<long> DirectoryIds() {
            if(rangeTable==0){foreach(long id in children.Keys){Check();yield return id;}}
            else{for(int i=0;i<directoryCount;i++){Check();indexStream.Position=rangeTable+i*20L;yield return indexReader.ReadInt64();}}
        }
        public Node Get(long offset) {
            if (offset < 0 || offset >= data.Length) throw new InvalidDataException("Invalid node offset");
            if(data.Position != offset) data.Position = offset;
            return new Node { Id=offset, ParentId=reader.ReadInt64(), Kind=reader.ReadByte(),
                LogicalBytes=reader.ReadInt64(), AllocatedBytes=reader.ReadInt64(), UniqueAllocatedBytes=reader.ReadInt64(),
                Files=reader.ReadInt64(), Folders=reader.ReadInt64(), Path=reader.ReadString(), Attributes=reader.ReadString(), Identity=reader.ReadString() };
        }
        public Node[] Children(long id,int limit,string metric) {return ChildrenPage(id,0,limit,metric);}
        public Node[] ChildrenPage(long id,int page,int limit,string metric) {
            if(page<0||limit<1||limit>10000)throw new ArgumentOutOfRangeException();
            Range range=GetRange(id);if(range==null)return new Node[0];
            // Keep only one page; repeated passes trade I/O for bounded memory.
            var top=new List<Node>();var comparer=new NodeComparer(metric);Node boundary=null;
            for(int pass=0;pass<=page;pass++){
                top.Clear();indexStream.Position=range.Start;
                for(int i=0;i<range.Count;i++){Check();Node n=Get(indexReader.ReadInt64());if(boundary!=null&&comparer.Compare(n,boundary)<=0)continue;
                    int pos=top.BinarySearch(n,comparer);if(pos<0)pos=~pos;if(pos<limit){top.Insert(pos,n);if(top.Count>limit)top.RemoveAt(top.Count-1);}}
                if(pass<page){if(top.Count<limit)return new Node[0];boundary=top[top.Count-1];}
            }return top.ToArray();
        }
        public int ChildCount(long id){Range r=GetRange(id);return r==null?0:r.Count;}
        public IEnumerable<Node> EnumerateDirectories(){foreach(long id in DirectoryIds()){yield return Get(id);}}
        public Node FindDirectory(string path) {
            string canonical=Canonical(path);
            foreach(long id in DirectoryIds()) {var n=Get(id);if(String.Equals(n.Path,canonical,StringComparison.OrdinalIgnoreCase))return n;}
            return null;
        }
        public Node[] Directories() {
            var result = new List<Node>(); foreach(long id in DirectoryIds()){result.Add(Get(id));} return result.ToArray();
        }
        public Inspection Inspect(int topCount, string[] rulePatterns) {
            var patterns=new List<Regex>();
            foreach(string pattern in rulePatterns) patterns.Add(new Regex(pattern,RegexOptions.IgnoreCase|RegexOptions.CultureInvariant));
            var files=new List<Node>();var links=new List<Node>();var candidates=new List<RuleHit>();
            var result=new Inspection();long next=0;
            var candidateNames=new HashSet<string>(new[]{"Cache","Code Cache","GPUCache","CacheStorage","npm-cache","CachedExtensionVSIXs","Temp","CrashDumps","Data"},StringComparer.OrdinalIgnoreCase);
            while(next<data.Length) {
                Check();Node n=Get(next);next=data.Position;result.Examined++;
                if(n.Kind==3) {result.LinkCount++;if(links.Count<5000)links.Add(n);}
                else if(n.Kind==2) {
                    int pos=files.BinarySearch(n,new NodeComparer("allocated"));if(pos<0)pos=~pos;
                    if(pos<topCount){files.Insert(pos,n);if(files.Count>topCount)files.RemoveAt(files.Count-1);}
                } else if(n.Kind==1 && candidateNames.Contains(System.IO.Path.GetFileName(n.Path))) {
                    for(int i=0;i<patterns.Count;i++) if(patterns[i].IsMatch(n.Path)) {
                        result.CandidateCount++;if(candidates.Count<2000)candidates.Add(new RuleHit{RuleIndex=i,Node=n});break;
                    }
                }
            }
            result.TopFiles=files.ToArray();result.Links=links.ToArray();result.Candidates=candidates.ToArray();return result;
        }
        public void Dispose() { reader.Dispose(); data.Dispose();indexReader.Dispose();indexStream.Dispose(); }
        private sealed class NodeComparer : IComparer<Node> {
            private readonly string metric; public NodeComparer(string m) { metric=m; }
            public int Compare(Node a, Node b) {
                long av=metric=="logical"?a.LogicalBytes:a.AllocatedBytes, bv=metric=="logical"?b.LogicalBytes:b.AllocatedBytes;
                int c=bv.CompareTo(av); return c!=0?c:StringComparer.OrdinalIgnoreCase.Compare(a.Path,b.Path);
            }
        }
        private static string Canonical(string p) { return p.TrimEnd('\\').Replace('/','\\'); }
        private static long Number(string s) { long n; if(!Int64.TryParse(s,NumberStyles.Integer,CultureInfo.InvariantCulture,out n) || n < 0) throw new InvalidDataException("Invalid byte/count field: "+s); return n; }
        public static ImportResult ImportWinDirStat(string csv, string output, string root) {
            return ImportWinDirStat(csv,output,root,null,null);
        }
        public static ImportResult ImportWinDirStat(string csv, string output, string root, Action<long> progress, Func<bool> cancel) {
            int steps=0;long last=0;
            Action checkpoint=delegate{
                long now=System.Diagnostics.Stopwatch.GetTimestamp();
                if(++steps<256&&now-last<System.Diagnostics.Stopwatch.Frequency/10)return;
                steps=0;last=now;
                if(Checkpoint!=null)Checkpoint();
                if(cancel!=null&&cancel())throw new OperationCanceledException();
            };
            string edgeFile=System.IO.Path.Combine(output,"edges.txt"),identityFile=System.IO.Path.Combine(output,"identities.txt");
            string edgeSorted=System.IO.Path.Combine(output,"edges-sorted.txt"),identitySorted=System.IO.Path.Combine(output,"identities-sorted.txt");
            var result = new ImportResult();
            using(var folders=new ImportDirectories(output,checkpoint)) {
            using(var edges=new StreamWriter(edgeFile,false,new UTF8Encoding(false)))
            using(var identities=new StreamWriter(identityFile,false,new UTF8Encoding(false)))
            using(var source=new CsvReader(csv))
            using(var stream=new FileStream(System.IO.Path.Combine(output,"nodes.bin"),FileMode.CreateNew,FileAccess.ReadWrite,FileShare.None))
            using(var w=new BinaryWriter(stream,Encoding.UTF8)) {
                var nodeReader=new BinaryReader(stream,Encoding.UTF8);
                Func<long,string> readPath=delegate(long offset){
                    long position=stream.Position;
                    try{stream.Position=offset+49;return nodeReader.ReadString();}
                    finally{stream.Position=position;}
                };
                string[] header=source.Read(); if(header==null) throw new InvalidDataException("Empty export");
                var cols=new Dictionary<string,int>(StringComparer.OrdinalIgnoreCase);
                for(int i=0;i<header.Length;i++) cols[header[i].TrimStart('\ufeff')]=i;
                foreach(string required in new[]{"Name","Logical Size","Physical Size","Attributes","WinDirStat Attributes","Index"})
                    if(!cols.ContainsKey(required)) throw new InvalidDataException("Export must use English columns; missing "+required);
                string[] row; while((row=source.Read())!=null) {
                    if(result.Nodes % 256 == 0) {
                        Check();if(cancel!=null && cancel()) throw new OperationCanceledException("Index import cancelled");
                        if(progress!=null) progress(result.Nodes);
                    }
                    if(row.Length==1 && row[0]=="") continue;
                    if(row.Length!=header.Length) throw new InvalidDataException("CSV column count mismatch");
                    string path=Canonical(row[cols["Name"]]);
                    uint flags=UInt32.Parse(row[cols["WinDirStat Attributes"]].Replace("0x",""),NumberStyles.HexNumber,CultureInfo.InvariantCulture);
                    bool isRoot=result.Nodes==0, isDir=(flags & 6)!=0, isFile=(flags & 8)!=0, isLink=(flags & 0x700000)!=0;
                    if(!isDir && !isFile) continue; // free/unknown/synthetic records are not files
                    if(isRoot && !String.Equals(path,Canonical(root),StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Unexpected export root");
                    if(!isRoot && !path.StartsWith(Canonical(root)+"\\",StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Export escaped requested scope");
                    long id=stream.Position, parent=-1, parentRow=-1;
                    if(!isRoot) {
                        int cut=path.LastIndexOf('\\');
                        if(cut>=0)parentRow=folders.Find(path.Substring(0,cut),readPath);
                        if(parentRow<0)throw new InvalidDataException("Missing parent: "+path);
                        parent=folders.Read(parentRow).Id;
                    }
                    long logical=Number(row[cols["Logical Size"]]), allocated=Number(row[cols["Physical Size"]]), unique=allocated;
                    string identity=row[cols["Index"]], attributes=row[cols["Attributes"]];
                    if(isLink) { logical=allocated=unique=0; result.Links++; }
                    else if(isFile) {
                        result.Files++;
                        if(identity.Replace("0x","").Trim('0').Length==0) { unique=-1; result.UnknownIdentities++; }
                        else identities.WriteLine(identity+"\t"+id.ToString("d20")+"\t"+parentRow.ToString("d20")+"\t"+allocated.ToString("d20"));
                    }
                    byte kind=(byte)(isLink?3:isDir?1:2);
                    w.Write(parent);w.Write(kind);w.Write(logical);w.Write(allocated);w.Write(unique);
                    w.Write(isDir?0L:1L);w.Write(0L);w.Write(path);w.Write(attributes);w.Write(identity);
                    if(parentRow>=0){
                        var parentEntry=folders.Read(parentRow);
                        parentEntry.ChildCount++;
                        edges.WriteLine(parent.ToString("d20")+"\t"+id.ToString("d20"));
                        if(isFile&&!isLink){
                            parentEntry.Logical+=logical;parentEntry.Allocated+=allocated;parentEntry.Files++;
                            parentEntry.Unique=unique<0||parentEntry.Unique<0?-1:parentEntry.Unique+unique;
                        }
                        folders.Write(parentRow,parentEntry);
                    }
                    if(isDir&&!isLink){
                        folders.Add(path,new DirectoryEntry{Id=id,Parent=parentRow},readPath);
                        result.Directories++;
                    }
                    result.Nodes++;
                }
                if(result.Nodes==0 || folders.Count==0||folders.Read(0).Id!=0) throw new InvalidDataException("No root directory in export");
                identities.Flush();edges.Flush();identities.Dispose();edges.Dispose();
                DiskData.Sort(identityFile,identitySorted,System.IO.Path.Combine(output,"sort-identities"));string previousIdentity=null;
                foreach(string entry in File.ReadLines(identitySorted)){
                    Check();if(cancel!=null&&cancel())throw new OperationCanceledException();var parts=entry.Split('\t');
                    if(parts[0]==previousIdentity){long node=Int64.Parse(parts[1],CultureInfo.InvariantCulture),parentId=Int64.Parse(parts[2],CultureInfo.InvariantCulture),bytes=Int64.Parse(parts[3],CultureInfo.InvariantCulture);stream.Position=node+25;w.Write(0L);var directoryEntry=folders.Read(parentId);if(directoryEntry.Unique>=0){directoryEntry.Unique-=bytes;folders.Write(parentId,directoryEntry);}result.HardlinkDuplicates++;}previousIdentity=parts[0];
                }
                // Parent-first export means child directory rows always follow their parents.
                for(long rowNumber=folders.Count-1;rowNumber>=0;rowNumber--){
                    checkpoint();if(progress!=null&&rowNumber%256==0)progress(result.Nodes);
                    var entry=folders.Read(rowNumber);
                    stream.Position=entry.Id+9;w.Write(entry.Logical);w.Write(entry.Allocated);w.Write(entry.Unique);w.Write(entry.Files);w.Write(entry.Folders);
                    if(entry.Parent>=0){
                        var parentEntry=folders.Read(entry.Parent);
                        parentEntry.Logical+=entry.Logical;parentEntry.Allocated+=entry.Allocated;parentEntry.Files+=entry.Files;parentEntry.Folders+=entry.Folders+1;
                        parentEntry.Unique=parentEntry.Unique<0||entry.Unique<0?-1:parentEntry.Unique+entry.Unique;
                        folders.Write(entry.Parent,parentEntry);
                    }
                }
                var totals=folders.Read(0);
                result.LogicalBytes=totals.Logical;result.AllocatedBytes=totals.Allocated;result.UniqueAllocatedBytes=totals.Unique;
                w.Flush();stream.Flush(true);
            }
            Check();if(cancel!=null&&cancel())throw new OperationCanceledException();
            DiskData.Sort(edgeFile,edgeSorted,System.IO.Path.Combine(output,"sort-edges"));
            using(var r=new StreamReader(edgeSorted,Encoding.UTF8))
            using(var stream=new FileStream(System.IO.Path.Combine(output,"index.bin"),FileMode.CreateNew,FileAccess.Write,FileShare.None))
            using(var w=new BinaryWriter(stream,Encoding.UTF8)){
                w.Write("SMARTCLEAN-INDEX-3");w.Write(folders.Count);
                long next=stream.Position+folders.Count*20L;
                for(long row=0;row<folders.Count;row++){
                    checkpoint();var entry=folders.Read(row);
                    w.Write(entry.Id);w.Write(next);w.Write(entry.ChildCount);next+=entry.ChildCount*8L;
                }
                for(long row=0;row<folders.Count;row++){
                    checkpoint();var entry=folders.Read(row);if(progress!=null&&row%256==0)progress(result.Nodes);
                    for(int i=0;i<entry.ChildCount;i++){
                        checkpoint();string line=r.ReadLine();if(line==null)throw new InvalidDataException("Missing child edge");
                        var parts=line.Split('\t');
                        if(Int64.Parse(parts[0],CultureInfo.InvariantCulture)!=entry.Id)throw new InvalidDataException("Invalid child parent");
                        w.Write(Int64.Parse(parts[1],CultureInfo.InvariantCulture));
                    }
                }
                if(r.ReadLine()!=null)throw new InvalidDataException("Extra child edge");
                w.Flush();stream.Flush(true);
            }
            }
            foreach(string temporary in new[]{edgeFile,edgeSorted,identityFile,identitySorted,Path.Combine(output,"directory-rows.bin"),Path.Combine(output,"directory-lookup-a.bin"),Path.Combine(output,"directory-lookup-b.bin")})if(File.Exists(temporary))File.Delete(temporary);
            return result;
        }
    }
    internal sealed class CsvReader : IDisposable {
        private readonly StreamReader input;
        public CsvReader(string path) { input=new StreamReader(path,Encoding.UTF8,true,65536); }
        public string[] Read() {
            if(input.Peek()<0) return null;
            var fields=new List<string>();var s=new StringBuilder();bool quoted=false,atStart=true;
            while(true) {
                int v=input.Read();if(v<0) { if(quoted)throw new InvalidDataException("Truncated CSV quote"); fields.Add(s.ToString());return fields.ToArray(); }
                char c=(char)v;
                if(quoted) {
                    if(c=='"') { if(input.Peek()=='"') {input.Read();s.Append('"');}else quoted=false; }
                    else s.Append(c);
                } else if(c=='"' && atStart) {quoted=true;atStart=false;}
                else if(c==',') {fields.Add(s.ToString());s.Length=0;atStart=true;}
                else if(c=='\n' || c=='\r') {if(c=='\r' && input.Peek()=='\n')input.Read();fields.Add(s.ToString());return fields.ToArray();}
                else {s.Append(c);atStart=false;}
            }
        }
        public void Dispose(){input.Dispose();}
    }
}
