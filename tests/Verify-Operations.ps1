#requires -Version 5.1
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'modules\Load.ps1')
$root=Join-Path $PSScriptRoot ('features\'+[Guid]::NewGuid().ToString('N'))
$input=Join-Path $root 'input';$target=Join-Path $root 'target'
[IO.Directory]::CreateDirectory($input)|Out-Null;[IO.Directory]::CreateDirectory($target)|Out-Null
$config=Get-SCConfig;$config.DataRoot=Join-Path $root 'data';$config|Add-Member NoteProperty PolicyRoot (Join-Path $root 'policy') -Force
Initialize-SCStore $config;Initialize-SCPolicy $config
$checks=New-Object 'Collections.Generic.List[string]'
function Assert($condition,$name){if(-not $condition){throw ('FAIL: '+$name)};$checks.Add($name)}
function Reject($action,$name){$failed=$false;try{& $action|Out-Null}catch{$failed=$true};Assert $failed $name}
function Put($path,$text){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null;[IO.File]::WriteAllText($path,$text)}
$a=Join-Path $input 'a.txt';$b=Join-Path $input 'nested\b.txt';$other=Join-Path $input 'different.txt'
Put $a 'SAME';Put $b 'SAME';Put $other 'DIFF'
& fsutil.exe hardlink create (Join-Path $input 'hardlink.txt') $a|Out-Null
$duplicates=Find-SCDuplicates $config @($input) ''
Assert ($duplicates.Rows.Count -eq 2) 'duplicate search confirms content, not only equal size'
Assert ($duplicates.HardlinksSkipped -eq 1) 'hardlinks are not separate duplicate copies'
Assert (@($duplicates.Rows|Where-Object {-not $_.Keep}).Count -eq 0) 'all duplicate copies are preserved by default'
foreach($row in $duplicates.Rows){$row.Keep=$row.Path -ne $b}
$plan=New-SCDuplicatePlan $config $duplicates.Rows ''
Assert ($plan.Operations.Count -eq 1) ('duplicate plan contains only explicitly unwanted copy: '+($plan.Warnings -join '; '))
Reject {Invoke-SCPlan $config $plan.Id ''} 'executor refuses unapproved plan'
$approved=Approve-SCPlan $config $plan.Id -Confirmed
$done=Invoke-SCPlan $config $plan.Id ''
Assert ($done.Status -eq 'Verified' -and (Test-Path -LiteralPath $a) -and -not(Test-Path -LiteralPath $b)) 'approved duplicate moved to quarantine and keeper retained'
$restore=New-SCRollbackPlan $config $plan.Id '';$approval=Approve-SCPlan $config $restore.Id -Confirmed;$result=Invoke-SCPlan $config $restore.Id ''
Assert ($result.Status -eq 'Verified' -and (Get-SCStamp $b '').SHA256 -eq (Get-SCStamp $a '').SHA256) 'journal-backed restore recovers original path and content'
$source=Join-Path $input 'move.bin';Put $source 'move-content'
$mapping=@([pscustomobject]@{Source=$source;Destination=(Join-Path $target 'move.bin');Action='MoveFile'})
$stale=New-SCFilePlan $config 'Relocate' $mapping '';$approval=Approve-SCPlan $config $stale.Id -Confirmed
Put $source 'changed-content'
$result=Invoke-SCPlan $config $stale.Id ''
Assert ($result.Status -eq 'Failed' -and (Test-Path -LiteralPath $source) -and -not(Test-Path -LiteralPath $mapping[0].Destination)) 'source changes after approval are refused without source deletion'
$protected=Join-Path $input 'protected';Put (Join-Path $protected 'keep.txt') 'important'
$policy=Add-SCProtection $config $protected 'test protection'
$blocked=New-SCFilePlan $config 'Relocate' @([pscustomobject]@{Source=(Join-Path $protected 'keep.txt');Destination=(Join-Path $target 'keep.txt')}) ''
Assert ($blocked.Operations.Count -eq 0 -and $blocked.Warnings.Count -gt 0) 'protected paths cannot enter an executable plan'
$revision=$policy.Revision;$policy.Host.Observations=@([pscustomobject]@{Fact='test'})
$saved=Save-SCHostPolicy $config $policy.Host $revision
Reject {Save-SCHostPolicy $config $policy.Host $revision} 'concurrent stale policy revision cannot overwrite newer decisions'
$source=Join-Path $input 'policy-change.bin';Put $source 'policy'
$old=New-SCFilePlan $config 'Relocate' @([pscustomobject]@{Source=$source;Destination=(Join-Path $target 'policy.bin')}) '';$approval=Approve-SCPlan $config $old.Id -Confirmed
$p=Add-SCProtection $config (Join-Path $input 'unrelated') 'new rule'
Reject {Invoke-SCPlan $config $old.Id ''} 'policy changes invalidate prior approvals'
$organizeRoot=Join-Path $root 'downloads';Put (Join-Path $organizeRoot 'document.pdf') 'pdf';Put (Join-Path $organizeRoot 'image.jpg') 'image'
$organization=New-SCOrganizationPlan $config $organizeRoot (Join-Path $root 'ordered') ''
Assert ($organization.Operations.Count -eq 2 -and @($organization.Operations|Where-Object {$_.Destination -match '\\Документы\\'}).Count -eq 1) 'organization builds categories and preserves relative layout'
$approval=Approve-SCPlan $config $organization.Id -Confirmed;$result=Invoke-SCPlan $config $organization.Id ''
Assert ($result.Status -eq 'Verified') 'organization executes through shared verified executor'
$collision=New-SCFilePlan $config 'Relocate' @([pscustomobject]@{Source=$source;Destination=$organization.Operations[0].Destination}) ''
Assert ($collision.Operations.Count -eq 0) 'existing destination is never overwritten'
$temp=Join-Path $root 'profile\AppData\Local\Temp';Put (Join-Path $temp 'old.tmp') 'old';Put (Join-Path $temp 'fresh.tmp') 'fresh'
[IO.File]::SetLastWriteTimeUtc((Join-Path $temp 'old.tmp'),[DateTime]::UtcNow.AddDays(-10))
$cleanup=New-SCCleanupPlan $config @([pscustomobject]@{Selected=$true;RuleId='user-temp';Path=$temp}) ''
Assert ($cleanup.Operations.Count -eq 1 -and $cleanup.Operations[0].Source.EndsWith('old.tmp')) 'cleanup selects only eligible old temp files'
$approval=Approve-SCPlan $config $cleanup.Id -Confirmed;$result=Invoke-SCPlan $config $cleanup.Id ''
Assert ($result.Status -eq 'Verified' -and (Test-Path -LiteralPath (Join-Path $temp 'fresh.tmp'))) 'cleanup quarantines selected file and preserves fresh temp data'
$purge=New-SCPurgePlan $config '';$approval=Approve-SCPlan $config $purge.Id -Confirmed;$result=Invoke-SCPlan $config $purge.Id ''
Assert ($result.Status -eq 'Verified') 'purge is an explicitly approved separate vault-only plan'
$badPurge=New-SCFilePlan $config 'PurgeVault' @([pscustomobject]@{Source=$source;Action='PurgeFile'}) ''
Assert ($badPurge.Operations.Count -eq 0) 'permanent deletion cannot target ordinary files outside vault'
$events=@(Get-SCDecisionEvents $config $organization.Id)
Assert (@($events|Where-Object {$_.Kind -eq 'OperationVerified'}).Count -eq 2) 'history records verified result for each operation'
Assert (@($events|Where-Object {$_.Kind -eq 'Finished'})[0].Details.After.Count -gt 0) 'execution records before/after free space'
$report=[pscustomobject]@{Passed=$checks.Count;Checks=$checks.ToArray();Utc=[DateTime]::UtcNow.ToString('o');Root=$root}
Write-SCJson (Join-Path $root 'verification.json') $report
$report|ConvertTo-Json -Depth 6
