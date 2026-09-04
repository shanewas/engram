' Launches engram sync with no console window (avoids focus-steal that minimizes windows / fullscreen games)
Set sh = CreateObject("Wscript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
syncPs1 = fso.BuildPath(scriptDir, "sync.ps1")
obsidianPy = fso.BuildPath(scriptDir, "sync-obsidian-vault-mcp.py")

Set args = WScript.Arguments
mode = "push"
If args.Count > 0 Then mode = args(0)

sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & syncPs1 & """ " & mode, 0, True
If fso.FileExists(obsidianPy) Then
    sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ""python """"" & obsidianPy & """"" *> $env:TEMP\pc-notes-mirror.log""", 0, True
End If
