$ErrorActionPreference='SilentlyContinue'
$inputText=[Console]::In.ReadToEnd()
if($inputText -notmatch '(?m)^host=github\.com\s*$'){exit 0}
$source=@"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class AutoUpdateCredentialReader {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
 public struct CREDENTIAL {
  public UInt32 Flags;public UInt32 Type;public IntPtr TargetName;public IntPtr Comment;
  public FILETIME LastWritten;public UInt32 CredentialBlobSize;public IntPtr CredentialBlob;
  public UInt32 Persist;public UInt32 AttributeCount;public IntPtr Attributes;public IntPtr TargetAlias;public IntPtr UserName;
 }
 [DllImport("Advapi32.dll",EntryPoint="CredReadW",CharSet=CharSet.Unicode,SetLastError=true)]
 public static extern bool CredRead(string target,UInt32 type,UInt32 flags,out IntPtr credential);
 [DllImport("Advapi32.dll",EntryPoint="CredFree",SetLastError=false)]
 public static extern void CredFree(IntPtr buffer);
}
"@
try{
 Add-Type -TypeDefinition $source -ErrorAction Stop|Out-Null
 $ptr=[IntPtr]::Zero
 if(-not [AutoUpdateCredentialReader]::CredRead('AutoUpdate/github',1,0,[ref]$ptr)){exit 0}
 try{
  $cred=[Runtime.InteropServices.Marshal]::PtrToStructure($ptr,[type][AutoUpdateCredentialReader+CREDENTIAL])
  $token=[Runtime.InteropServices.Marshal]::PtrToStringUni($cred.CredentialBlob,[int]($cred.CredentialBlobSize/2)).TrimEnd([char]0)
  if([string]::IsNullOrWhiteSpace($token)-or $token -match '\s'){exit 0}
  [Console]::Out.WriteLine('username=x-access-token')
  [Console]::Out.WriteLine('password='+$token)
  [Console]::Out.WriteLine()
  [Console]::Out.Flush()
 }finally{[AutoUpdateCredentialReader]::CredFree($ptr)}
}catch{exit 0}