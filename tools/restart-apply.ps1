param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$AppId,
    [Parameter(Mandatory=$true)][string]$StateRoot,
    [Parameter(Mandatory=$true)][string]$PackagePath,
    [Parameter(Mandatory=$true)][string]$EntryRelativePath,
    [Parameter(Mandatory=$true)][string]$TargetPath,
    [Parameter(Mandatory=$true)][string]$StateFile,
    [int]$ParentProcessId=0,
    [string[]]$Arguments=@(),
    [string]$WorkingDirectory,
    [ValidateSet('x86','x64','arm64')][string]$Architecture='x64',
    [ValidateRange(1,900)][int]$HealthTimeoutSeconds=60
)
$ErrorActionPreference='Stop'
$module=Join-Path $PSScriptRoot '..\source\AutoUpdate.Core.psm1'
Import-Module $module -Force
function Resolve-PackagePath([string]$Root,[string]$Relative){
    $base=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '(^[/\\]|^[A-Za-z]:|(^|[/\\])\.\.([/\\]|$)|:|[\x00-\x1f])'){throw 'Unsafe executable package path.'}
    $full=[IO.Path]::GetFullPath((Join-Path $base ($Relative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
    if(-not $full.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Executable path escapes package root.'}
    return $full
}function Quote-WindowsArgument([string]$Value){
    if($Value -notmatch '[\s"]'){return $Value}
    $builder=[Text.StringBuilder]::new();[void]$builder.Append('"');$slashes=0
    foreach($ch in $Value.ToCharArray()){
        if($ch -eq '\'){$slashes++;continue}
        if($ch -eq '"'){[void]$builder.Append(('\' * ($slashes*2+1)));[void]$builder.Append('"');$slashes=0;continue}
        if($slashes){[void]$builder.Append(('\' * $slashes));$slashes=0};[void]$builder.Append($ch)
    }
    if($slashes){[void]$builder.Append(('\' * ($slashes*2)))};[void]$builder.Append('"');return $builder.ToString()
}
function Start-App([string]$Exe,[string[]]$AppArguments,[string]$Directory,[string]$Resume,[string]$Health,[string]$Version){
    $commandArguments=@($AppArguments)+@('--autoupdate-state',$Resume,'--autoupdate-health',$Health,'--autoupdate-version',$Version)
    $joined=($commandArguments|ForEach-Object{Quote-WindowsArgument ([string]$_)}) -join ' '
    Start-Process -FilePath $Exe -ArgumentList $joined -WorkingDirectory $Directory -PassThru
}
function Wait-ForHealth($Process,[string]$Health,[string]$Version,[int]$Timeout){
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while($timer.Elapsed.TotalSeconds -lt $Timeout){
        if(Test-Path -LiteralPath $Health -PathType Leaf){
            $value=[IO.File]::ReadAllText($Health).Trim()
            if($value -ceq $Version){return $true}
        }
        if($Process.HasExited){return $false}
        Start-Sleep -Milliseconds 100
    }
    return $false
}
$target=[IO.Path]::GetFullPath($TargetPath);$package=[IO.Path]::GetFullPath($PackagePath);$resume=[IO.Path]::GetFullPath($StateFile)
$current=Get-AuVerifiedCurrent -StateRoot $StateRoot -AppId $AppId -Architecture $Architecture
if(-not $current){throw 'No verified package is installed for this app.'}
if([IO.Path]::GetFullPath($current.Path) -ine $package){throw 'PackagePath is not the active verified package.'}
if($current.Mode -ne 'restart'){throw 'Restart helper cannot apply a live package.'}
if(-not (Test-Path -LiteralPath $resume -PathType Leaf)){throw 'The app did not save its resume state.'}
$relative=$EntryRelativePath.Replace('\','/');$entry=@($current.Manifest.files|Where-Object{$_.path -ceq $relative})
if($entry.Count -ne 1 -or $entry[0].kind -notin @('executable','runtime')){throw 'EntryRelativePath is not a unique executable in the verified package.'}
$source=Resolve-PackagePath $package $relative
if(-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-Item -LiteralPath $source).Length -ne [long]$entry[0].size -or (Get-AuFileSha256 $source) -cne [string]$entry[0].sha256){throw 'Restart entry failed package integrity validation.'}
if(-not $WorkingDirectory){$WorkingDirectory=Split-Path -Parent $target};$working=[IO.Path]::GetFullPath($WorkingDirectory)
if(-not (Test-Path -LiteralPath $working -PathType Container)){throw 'Application working directory is missing.'}
$targetDirectory=Split-Path -Parent $target
if(-not (Test-Path -LiteralPath $targetDirectory -PathType Container)){throw 'Application target directory is missing.'}
$health=Join-Path (Join-Path $StateRoot ('apps\'+$AppId)) ('health-'+[guid]::NewGuid().ToString('N')+'.txt')
$stage=Join-Path $targetDirectory ((Split-Path -Leaf $target)+'.'+[guid]::NewGuid().ToString('N')+'.part')
$backup=Join-Path $targetDirectory ((Split-Path -Leaf $target)+'.rollback-'+$current.Version+'-'+[guid]::NewGuid().ToString('N'))
$hadTarget=Test-Path -LiteralPath $target -PathType Leaf;$launched=$null
$previousVersion=''
$previousPointer=Join-Path (Join-Path $StateRoot ('apps\'+$AppId)) 'previous.json'
if(Test-Path -LiteralPath $previousPointer -PathType Leaf){try{$previous=Get-Content -Raw -LiteralPath $previousPointer|ConvertFrom-Json;if($previous.version -match '^\d+\.\d+\.\d+$'){$previousVersion=[string]$previous.version}}catch{}}
try{
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $health))
    if($ParentProcessId -gt 0){$parent=Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue;if($parent){[void]$parent.WaitForExit(60000);if(-not $parent.HasExited){throw 'Application did not close normally before the restart update.'}}}
    [IO.File]::Copy($source,$stage,$false)
    if((Get-Item -LiteralPath $stage).Length -ne [long]$entry[0].size -or (Get-AuFileSha256 $stage) -cne [string]$entry[0].sha256){throw 'Staged restart executable failed integrity validation.'}
    if($hadTarget){[IO.File]::Replace($stage,$target,$backup)}else{[IO.File]::Move($stage,$target)}
    $launched=Start-App $target $Arguments $working $resume $health $current.Version
    if(Wait-ForHealth $launched $health $current.Version $HealthTimeoutSeconds){
        if($hadTarget -and (Test-Path -LiteralPath $backup)){Remove-Item -LiteralPath $backup -Force}
        [pscustomobject]@{schema=1;status='confirmed';app_id=$AppId;version=$current.Version;target_path=$target}|ConvertTo-Json -Compress
        exit 0
    }
    if($launched -and -not $launched.HasExited){Stop-Process -Id $launched.Id -Force -ErrorAction SilentlyContinue;[void]$launched.WaitForExit(5000)}
    if($hadTarget){$failedImage=$target+'.failed-'+[guid]::NewGuid().ToString('N');[IO.File]::Replace($backup,$target,$failedImage);Remove-Item -LiteralPath $failedImage -Force -ErrorAction SilentlyContinue}else{Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue}
    $old=if($hadTarget){Start-App $target $Arguments $working $resume $health $previousVersion}else{$null}
    [pscustomobject]@{schema=1;status='rolled-back';app_id=$AppId;version=$current.Version;target_path=$target;message='Health acknowledgement timed out; the previous executable was restored.'}|ConvertTo-Json -Compress
    exit 3
}finally{
    if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $health){Remove-Item -LiteralPath $health -Force -ErrorAction SilentlyContinue}
}