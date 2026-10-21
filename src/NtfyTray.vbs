' NtfyTray hidden launcher: starts NtfyTray.ps1 with Windows PowerShell 5.1 and no console window.
Option Explicit
Dim fso, sh, dir, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & dir & "\NtfyTray.ps1"""
sh.Run cmd, 0, False
