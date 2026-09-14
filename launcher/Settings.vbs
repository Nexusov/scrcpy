Option Explicit
Dim shell, fileSystem, folder, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
folder = fileSystem.GetParentFolderName(WScript.ScriptFullName)
' Support both portable packages and existing flat installations.
If fileSystem.FileExists(fileSystem.BuildPath(folder, "app\setup.ps1")) Then
    folder = fileSystem.BuildPath(folder, "app")
End If
scriptPath = fileSystem.BuildPath(folder, "setup.ps1")
command = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """"
shell.Run command, 0, False
