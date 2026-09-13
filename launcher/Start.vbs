Option Explicit
Dim shell, fileSystem, folder, launcherPath
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
folder = fileSystem.GetParentFolderName(WScript.ScriptFullName)
launcherPath = fileSystem.BuildPath(folder, "launch.vbs")
shell.Run "wscript.exe """ & launcherPath & """", 0, False
