#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
foreach($module in @('Core','Inventory','Scanner','Reports','Menu')){. (Join-Path $project ('modules\'+$module+'.ps1'))}
$run=Join-Path $PSScriptRoot ('runs\verify-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
$fixture=Join-Path $run 'Русский каталог [тест]'
$outside=Join-Path $run 'outside'
[IO.Directory]::CreateDirectory($fixture)|Out-Null
[IO.Directory]::CreateDirectory($outside)|Out-Null
$store=Join-Path $fixture 'SmartClean data [local]'
$config=Get-SCConfig;$config.DataRoot=$store;$config.MaxSnapshots=20
Initialize-SCStore $config
[IO.File]::WriteAllBytes((Join-Path $store 'canary.bin'),(New-Object byte[] 3145728))
$deep=Join-Path $fixture 'a\b\c\d\ещё глубже'
[IO.Directory]::CreateDirectory($deep)|Out-Null
[IO.Directory]::CreateDirectory((Join-Path $fixture 'empty'))|Out-Null
[IO.File]::WriteAllBytes((Join-Path $deep 'данные.bin'),(New-Object byte[] 7777))
[IO.File]::WriteAllBytes((Join-Path $fixture 'original.bin'),(New-Object byte[] 1048576))
& fsutil.exe hardlink create (Join-Path $fixture 'hardlink.bin') (Join-Path $fixture 'original.bin') | Out-Null
if($LASTEXITCODE -ne 0){throw 'Cannot create test hardlink'}
$sparse=Join-Path $fixture 'sparse.bin';[IO.File]::WriteAllBytes($sparse,(New-Object byte[] 0))
& fsutil.exe sparse setflag $sparse | Out-Null
$stream=[IO.File]::OpenWrite($sparse);try{$stream.SetLength(67108864)}finally{$stream.Dispose()}
[IO.File]::WriteAllBytes((Join-Path $outside 'outside.bin'),(New-Object byte[] 2097152))
New-Item -ItemType Junction -Path (Join-Path $fixture 'junction-outside') -Target $outside | Out-Null
New-Item -ItemType Junction -Path (Join-Path $fixture 'junction-cycle') -Target ([Management.Automation.WildcardPattern]::Escape($fixture)) | Out-Null
$passed=New-Object 'Collections.Generic.List[string]'
function Assert($condition,$message){if(-not $condition){throw "FAIL: $message"};$passed.Add($message)}
$first=Start-SCScan -Config $config -Path $fixture
Assert $first.HasIndex ('scan produced an index: '+$first.Failure)
Assert ($first.Totals.LogicalBytes -eq 69213793) 'logical total excludes own store and junction targets, includes both hardlink paths'
Assert ($first.Totals.AllocatedBytes -eq 2105344) 'sparse file allocation measured, not logical size'
Assert ($first.Totals.UniqueAllocatedBytes -eq 1056768) 'hardlink allocation counted once within scope'
Assert ($first.Totals.HardlinkDuplicates -eq 1) 'one duplicate file identity'
Assert ($first.Totals.Links -eq 2) 'junction and cycle excluded'
Assert ($first.Status -eq 'partial' -and $first.Coverage -eq 'unverified') 'unknown permission coverage is explicit'
$idx=Open-SCIndex $first
try{
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $target=$idx.FindDirectory($deep)
    Assert ($null -ne $target) 'deep Cyrillic path found in saved index'
    Assert ($target.LogicalBytes -eq 7777) 'deep directory retains complete subtree size'
    Assert ($idx.FindDirectory($store) -eq $null) 'self-output root is excluded by engine filter'
    $empty=$idx.FindDirectory((Join-Path $fixture 'empty'))
    Assert ($empty.LogicalBytes -eq 0 -and $empty.AllocatedBytes -eq 0) 'empty directory stays zero'
    $items=$idx.Children(0,30,'allocated')
    Assert (@($items|Where-Object {$_.Path -match 'sparse.bin$'})[0].AllocatedBytes -eq 0) 'zero allocated sparse file retained as known zero'
    $clock.Stop();$browseMs=$clock.Elapsed.TotalMilliseconds
    Show-SCTree $idx 0 3 8
}finally{$idx.Dispose()}
[IO.File]::WriteAllBytes((Join-Path $deep 'new.bin'),(New-Object byte[] 12345))
$second=Start-SCScan -Config $config -Path $fixture
Assert $second.HasIndex ('second scan produced an index: '+$second.Failure)
$diff=Get-SCDiff $first $second
$rootDelta=@($diff.Changes|Where-Object {$_.Path -eq $fixture})
Assert ($rootDelta.Count -eq 1 -and $rootDelta[0].LogicalDelta -eq 12345) 'snapshot diff finds exact root logical growth'
$changed=$second.PSObject.Copy();$changed.VolumeId='different-volume';$rejected=$false
try{Get-SCDiff $first $changed|Out-Null}catch{$rejected=$true}
Assert $rejected 'comparison refuses different volume identity'
$cancel=Join-Path $run 'cancel.flag';[IO.File]::WriteAllText($cancel,'cancel')
$stopped=Start-SCScan -Config $config -Path $fixture -CancelFile $cancel
Assert ($stopped.Status -eq 'cancelled' -and -not $stopped.HasIndex) 'cancellation records status and never claims a complete index'
Import-SCIndexType
$invalid=Join-Path $run 'invalid.csv';[IO.File]::WriteAllText($invalid,'Name,Wrong'+[Environment]::NewLine+'x,1')
$badOut=Join-Path $run 'bad-import';[IO.Directory]::CreateDirectory($badOut)|Out-Null
$rejected=$false;try{[SmartClean.SnapshotIndex]::ImportWinDirStat($invalid,$badOut,$fixture)|Out-Null}catch{$rejected=$true}
Assert $rejected 'import refuses unsupported export schema'
# Permission denial is confined to a directory created by this test and restored in finally.
$denied=Join-Path $fixture 'denied'
[IO.Directory]::CreateDirectory($denied)|Out-Null
[IO.File]::WriteAllBytes((Join-Path $denied 'private.bin'),(New-Object byte[] 4096))
$originalAcl=Get-Acl -LiteralPath $denied
try{
    $acl=Get-Acl -LiteralPath $denied
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,[Security.AccessControl.FileSystemRights]::ListDirectory,[Security.AccessControl.AccessControlType]::Deny)
    $acl.AddAccessRule($rule);Set-Acl -LiteralPath $denied -AclObject $acl
    $restricted=Start-SCScan -Config $config -Path $fixture
    Assert ($restricted.Status -eq 'partial' -and $restricted.Coverage -eq 'unverified') 'permission-denied scan never claims verified complete coverage'
}finally{Set-Acl -LiteralPath $denied -AclObject $originalAcl}
# Removing an own report must preserve fixture data and the other snapshots.
Remove-SCSnapshot $config $stopped
Assert ((Test-Path -LiteralPath (Join-Path $fixture 'original.bin')) -and -not(Test-Path -LiteralPath $stopped.SnapshotDirectory)) 'own-report deletion does not delete scanned data'
$report=[pscustomobject]@{Utc=[DateTime]::UtcNow.ToString('o');Passed=$passed.Count;Checks=@($passed);Fixture=$fixture;Store=$store;BrowseMilliseconds=$browseMs;FirstSnapshot=$first.SnapshotId;SecondSnapshot=$second.SnapshotId;FirstTotals=$first.Totals}
Write-SCJson (Join-Path $run 'verification.json') $report
$report|ConvertTo-Json -Depth 8
