using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Forms;

internal static class DesktopHost {
    [STAThread] private static int Main(string[] args) {
        string root=AppDomain.CurrentDomain.BaseDirectory;
        try {
            string script=File.ReadAllText(Path.Combine(root,"ui","SmartClean.Wpf.ps1"));
            using(var runspace=RunspaceFactory.CreateRunspace()) {
                runspace.ApartmentState=ApartmentState.STA;
                runspace.ThreadOptions=PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using(var shell=PowerShell.Create()) {
                    shell.Runspace=runspace;
                    shell.AddScript(script).AddParameter("AppRoot",root);
                    if(args.Length>0 && args[0]=="--smoke") {
                        shell.AddParameter("SmokeTest",true);
                        if(args.Length>1)shell.AddParameter("ScreenshotPath",args[1]);
                    }
                    shell.Invoke();
                    // Handled PowerShell errors can leave HadErrors sticky after a normal window close.
                    if(shell.InvocationStateInfo.State==PSInvocationState.Failed)
                        throw shell.InvocationStateInfo.Reason ?? new Exception("WPF invocation failed");
                }
            }
            return 0;
        }catch(Exception ex) {
            string log=Path.Combine(root,"data","ui-startup-error.txt");
            try{Directory.CreateDirectory(Path.GetDirectoryName(log));File.WriteAllText(log,ex.ToString());}catch{}
            MessageBox.Show("SmartClean could not start. Details: "+log+Environment.NewLine+ex.Message,"SmartClean",MessageBoxButtons.OK,MessageBoxIcon.Error);
            return 1;
        }
    }
}
