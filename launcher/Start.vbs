Option Explicit
Dim shell, fileSystem, folder, launcherPath
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
folder = fileSystem.GetParentFolderName(WScript.ScriptFullName)
' Support both portable packages and existing flat installations.
If fileSystem.FileExists(fileSystem.BuildPath(folder, "app\launch.vbs")) Then
    folder = fileSystem.BuildPath(folder, "app")
End If
launcherPath = fileSystem.BuildPath(folder, "launch.vbs")
shell.Run "wscript.exe """ & launcherPath & """", 0, False
