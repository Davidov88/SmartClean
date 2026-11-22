using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
namespace SmartClean {
    // Bounded sorted runs, with a maximum of 32 readers per merge.
    public static class DiskData {
        public static Action Checkpoint;
        private static long lastCheck;private static int checkSteps;
        private static void Check(){long now=System.Diagnostics.Stopwatch.GetTimestamp();if(++checkSteps<256&&now-lastCheck<System.Diagnostics.Stopwatch.Frequency/10)return;checkSteps=0;lastCheck=now;if(Checkpoint!=null)Checkpoint();}
        public static void Sort(string input,string output,string workspace) {
            Directory.CreateDirectory(workspace);
            var runs=new List<string>();var lines=new List<string>();long bytes=0;int number=0;
            using(var reader=new StreamReader(input,Encoding.UTF8)) {
                string line;while((line=reader.ReadLine())!=null){Check();lines.Add(line);bytes+=line.Length*2L+64;
                    if(bytes>=48L*1024*1024){runs.Add(WriteRun(lines,workspace,number++));lines.Clear();bytes=0;}}
            }
            if(lines.Count>0||runs.Count==0)runs.Add(WriteRun(lines,workspace,number++));
            while(runs.Count>1){var next=new List<string>();for(int i=0;i<runs.Count;i+=32){Check();var group=runs.GetRange(i,Math.Min(32,runs.Count-i));string path=Path.Combine(workspace,"merge-"+(number++)+".txt");Merge(group,path);next.Add(path);foreach(var old in group)File.Delete(old);}runs=next;}
            if(File.Exists(output))throw new IOException("Result already exists");File.Move(runs[0],output);
        }
        private sealed class CheckedComparer:IComparer<string>{public int Compare(string a,string b){Check();return StringComparer.Ordinal.Compare(a,b);}}
        private static string WriteRun(List<string> lines,string workspace,int number){Check();lines.Sort(new CheckedComparer());Check();string path=Path.Combine(workspace,"run-"+number+".txt");using(var w=new StreamWriter(path,false,new UTF8Encoding(false))){foreach(var line in lines){Check();w.WriteLine(line);}}return path;}
        private static void Merge(List<string> paths,string output){var readers=new List<StreamReader>();try{var heads=new string[paths.Count];for(int i=0;i<paths.Count;i++){readers.Add(new StreamReader(paths[i],Encoding.UTF8));heads[i]=readers[i].ReadLine();}using(var w=new StreamWriter(output,false,new UTF8Encoding(false))){while(true){Check();int best=-1;for(int i=0;i<heads.Length;i++)if(heads[i]!=null&&(best<0||StringComparer.Ordinal.Compare(heads[i],heads[best])<0))best=i;if(best<0)break;w.WriteLine(heads[best]);heads[best]=readers[best].ReadLine();}}}finally{foreach(var reader in readers)reader.Dispose();}}
    }
}
