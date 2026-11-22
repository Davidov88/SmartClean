#requires -Version 5.1
[CmdletBinding()]
param([switch]$Apply)
$ErrorActionPreference='Stop'
$tests=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
$runs=Join-Path $PSScriptRoot 'runs'
$targets=New-Object 'Collections.Generic.List[string]'
foreach($run in @(Get-ChildItem -LiteralPath $runs -Directory)){
    if($run.Name -notmatch '^(\d{8}-\d{6}|verify-[a-f0-9]{8}|analysis-[a-f0-9]{8})$'){continue}
    foreach($child in @(Get-ChildItem -LiteralPath $run.FullName -Directory -Force)){
        if($child.Name -in @('fixture','outside','bad-import') -or $child.Name -eq 'Русский каталог [тест]'){$targets.Add($child.FullName)}
    }
}
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'app-data')){$targets.Add((Join-Path $PSScriptRoot 'app-data'))}
foreach($target in $targets){
    $absolute=[IO.Path]::GetFullPath($target)
    if(-not $absolute.StartsWith($tests,[StringComparison]::OrdinalIgnoreCase)){throw 'Target escaped tests workspace'}
    $root=Get-Item -LiteralPath $absolute -Force
    if(($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Fixture root must not be a reparse point'}
    Write-Host $absolute
    if(-not $Apply){continue}
    $stack=New-Object 'Collections.Generic.Stack[string]';$dirs=New-Object 'Collections.Generic.List[string]'
    $stack.Push($absolute)
    while($stack.Count -gt 0){
        $dir=$stack.Pop();$dirs.Add($dir)
        foreach($entry in (New-Object IO.DirectoryInfo($dir)).GetFileSystemInfos()){
            if(-not $entry.FullName.StartsWith($absolute.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Entry escaped fixture'}
            $isDirectory=($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0
            $isLink=($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            if($isLink){
                # Nonrecursive unlink: never enumerate or delete the target.
                if($isDirectory){[IO.Directory]::Delete($entry.FullName)}else{[IO.File]::Delete($entry.FullName)}
            }elseif($isDirectory){$stack.Push($entry.FullName)}else{[IO.File]::Delete($entry.FullName)}
        }
    }
    foreach($dir in @($dirs|Sort-Object Length -Descending)){[IO.Directory]::Delete($dir)}
}
Write-Host $(if($Apply){'Generated fixtures removed; reports preserved.'}else{'Dry run. Use -Apply to remove only these generated test fixtures.'})
