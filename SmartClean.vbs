Set fs = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
base = fs.GetParentFolderName(WScript.ScriptFullName)
python = base & "\.venv\Scripts\pythonw.exe"
sh.CurrentDirectory = base
If fs.FileExists(python) Then
    sh.Run Chr(34) & python & Chr(34) & " -m smartclean.desktop --data-dir " & Chr(34) & base & "\.local" & Chr(34), 0, False
Else
    sh.Run Chr(34) & base & "\Start-SmartClean.cmd" & Chr(34), 1, False
End If
