function Enter-AuSharedCycleLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [ValidateRange(0,300000)][int]$TimeoutMilliseconds=60000
    )
    $fullPath=[IO.Path]::GetFullPath($Path)
    $parent=Split-Path -Parent $fullPath
    [void][IO.Directory]::CreateDirectory($parent)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        try{
            return [IO.File]::Open($fullPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        }catch [IO.IOException]{
            if($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds){return $null}
            $remaining=$TimeoutMilliseconds-[int]$timer.ElapsedMilliseconds
            if($remaining -le 0){return $null}
            Start-Sleep -Milliseconds ([Math]::Min($remaining,(Get-Random -Minimum 200 -Maximum 800)))
        }
    }
}

function Exit-AuSharedCycleLock {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][IO.FileStream]$LockHandle)
    $LockHandle.Dispose()
}
