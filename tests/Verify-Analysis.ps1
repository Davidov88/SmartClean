#requires -Version 5.1
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
foreach($module in @('Core','Inventory','Scanner','Reports','Analysis','Menu')){. (Join-Path $project ('modules\'+$module+'.ps1'))}
$run=Join-Path $PSScriptRoot ('runs\analysis-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
$root=Join-Path $run 'fixture';$outside=Join-Path $run 'outside'
[IO.Directory]::CreateDirectory($root)|Out-Null;[IO.Directory]::CreateDirectory($outside)|Out-Null
$link=Join-Path $root 'moved';New-Item -ItemType Junction -Path $link -Target $outside|Out-Null
$cycle=Join-Path $root 'cycle';New-Item -ItemType Junction -Path $cycle -Target $root|Out-Null
$rows=New-Object 'Collections.Generic.List[object]'
function Add-Row($relative,$flags,$size,$identity){
    $path=if($relative){Join-Path $root $relative}else{$root}
    $rows.Add([pscustomobject][ordered]@{Name=$path;'Logical Size'=$size;'Physical Size'=$size;Attributes='';'WinDirStat Attributes'=$flags;Index=$identity})
}
Add-Row '' '0x4' 0 '0x0'
foreach($dir in @('profile','profile\AppData','profile\AppData\Local','profile\AppData\Local\pip','profile\AppData\Local\pip\Cache','profile\AppData\Local\Temp')){Add-Row $dir '0x4' 0 '0x0'}
Add-Row 'profile\AppData\Local\pip\Cache\payload.bin' '0x8' (300MB) '0x100'
Add-Row 'profile\AppData\Local\important.db' '0x8' (400MB) '0x101'
Add-Row 'cycle' '0x400004' 0 '0x0'
Add-Row 'moved' '0x400004' 0 '0x0'
$csv=Join-Path $root 'test.csv';$rows.ToArray()|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
Import-SCIndexType
$totals=[SmartClean.SnapshotIndex]::ImportWinDirStat($csv,$root,$root)
$id=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$m=[pscustomobject]@{SchemaVersion=1;HasIndex=$true;SnapshotId=$id;HostId=(Get-SCHostId);Root=$root+'\';VolumeId='fixture-volume';SnapshotDirectory=$root;FinishedUtc=[DateTime]::UtcNow.ToString('o');StartedUtc=[DateTime]::UtcNow.ToString('o');Coverage='unverified';EngineVersion='2.9.3';Elevated=$false;Metric='logical-and-allocated-per-path';LinkPolicy='fixture'}
$checks=New-Object 'Collections.Generic.List[string]'
function Assert($condition,$label){if(-not $condition){throw ('FAIL: '+$label)};$checks.Add($label)}
$a=New-SCAnalysis $m
Assert ($a.LinkCount -eq 2 -and $a.Links.Count -eq 2) 'inspection retains all detected links'
$mapped=@($a.Links|Where-Object {$_.Path -eq $link})[0]
Assert ($mapped.Target -eq $outside -and $mapped.Win32Error -eq 0) 'native reparse query reads junction target without following it'
$mapped=@($a.Links|Where-Object {$_.Path -eq $cycle})[0]
Assert ($mapped.Target -eq $root) 'junction cycle is reported rather than traversed'
$normal=[SmartClean.NativeLinks]::Read($outside)
Assert ($normal.Error -eq 4390 -and -not $normal.Target) 'ordinary directory is not misreported as a link'
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class TestSymbolicLink {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 [return:MarshalAs(UnmanagedType.I1)]
 public static extern bool CreateSymbolicLinkW(string path,string target,int flags);
}
'@
$relativeLink=Join-Path $root 'relative-link'
if([TestSymbolicLink]::CreateSymbolicLinkW($relativeLink,'..\outside',1)){
    $relative=[SmartClean.NativeLinks]::Read($relativeLink)
    Assert ($relative.Type -eq 'SymbolicLink' -and $relative.Target -eq '..\outside') 'native symbolic-link buffer preserves relative destination'
    Assert ($relative.ResolvedTarget -eq $outside) 'relative target is resolved against link parent'
}else{Write-Warning ('Symbolic-link creation unavailable in this environment, error '+[Runtime.InteropServices.Marshal]::GetLastWin32Error())}
$foreign=@(Get-SCLinkDestinations @([pscustomobject]@{Path=$link}) $false)[0]
Assert (-not $foreign.Target -and $foreign.Status -like 'другой компьютер*') 'foreign-computer snapshot does not query misleading local targets'
Assert ($a.TopFiles.Count -eq 2 -and $a.TopFiles[0].AllocatedBytes -eq 400MB) 'large files sorted by measured allocation'
Assert (@($a.Focus|Where-Object {$_.Path -eq (Join-Path $root 'profile\AppData\Local')}).Count -eq 0) 'automatic focus expands AppData containers'
Assert ($a.Candidates.Count -eq 1 -and $a.Candidates[0].RuleId -eq 'pip-cache') 'only known nonempty cache candidate matched; database is not garbage'
Assert (-not $a.Candidates[0].Approved) 'candidate detection never grants cleanup permission'
Assert ($a.Candidates[0].ObservedBytes -eq 300MB) 'candidate size comes from saved index'
$overlap=$false
foreach($x in $a.Focus){foreach($y in $a.Focus){if($x.Path -ne $y.Path -and $x.Path.StartsWith($y.Path+'\',[StringComparison]::OrdinalIgnoreCase)){$overlap=$true}}}
Assert (-not $overlap) 'focus does not repeat a parent and its descendant'
$config=Get-SCConfig;$config.DataRoot=Join-Path $run 'exports'
$destination=Export-SCAnalysis $config $a
Assert ((Test-Path -LiteralPath (Join-Path $destination 'summary.md')) -and (Test-Path -LiteralPath (Join-Path $destination 'analysis.json')) -and (Test-Path -LiteralPath (Join-Path $destination 'links.csv'))) 'human report, machine data and links CSV exported'
$roundtrip=Get-Content -LiteralPath (Join-Path $destination 'analysis.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert ($roundtrip.LinkCount -eq 2 -and $roundtrip.Candidates[0].ObservedBytes -eq 300MB) 'machine export roundtrips sizes and links'
$snapshotFolder=Join-Path $config.DataRoot ('snapshots\'+$id);[IO.Directory]::CreateDirectory($snapshotFolder)|Out-Null
Write-SCJson (Join-Path $snapshotFolder 'manifest.json') $m
$message=Show-SCLatestChanges $config 6>&1|Out-String
Assert ($message -like '*есть только один замер*') 'single snapshot gives guidance instead of old/new selection'
$report=[pscustomobject]@{Passed=$checks.Count;Checks=$checks.ToArray();Utc=[DateTime]::UtcNow.ToString('o')}
Write-SCJson (Join-Path $run 'verification.json') $report
$report|ConvertTo-Json -Depth 6
