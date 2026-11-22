#requires -Version 5.1
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent;. (Join-Path $project 'modules\Load.ps1')
$root=Join-Path $PSScriptRoot ('features\'+[Guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($root)|Out-Null
$c=Get-SCConfig;$c.DataRoot=Join-Path $root 'data';$c|Add-Member NoteProperty PolicyRoot (Join-Path $root 'policy') -Force
Initialize-SCStore $c
$checks=New-Object 'Collections.Generic.List[string]'
function Assert($value,$message){if(-not $value){throw ('FAIL: '+$message)};$checks.Add($message)}
$json=Join-Path $root 'overwrite.json'
for($i=0;$i -lt 100;$i++){Write-SCJson $json @{Sequence=$i};$r=Get-Content -LiteralPath $json -Raw -Encoding UTF8|ConvertFrom-Json;if($r.Sequence -ne $i){throw 'JSON overwrite failed'}}
Assert $true '100 atomic JSON replacements remain readable'
$source=Join-Path $root 'scan';$excluded=Join-Path $source 'do not scan [x]';[IO.Directory]::CreateDirectory($excluded)|Out-Null
[IO.File]::WriteAllText((Join-Path $source 'visible.bin'),'keep');[IO.File]::WriteAllBytes((Join-Path $excluded 'hidden.bin'),(New-Object byte[] 8192))
$p=Add-SCScanExclusion $c $excluded 'test exclusion'
$scan=Start-SCScan -Config $c -Path $source
Assert ($scan.HasIndex -and $scan.Totals.LogicalBytes -eq 4) ('scanner honors shared exclusion with spaces and brackets: '+$scan.Failure)
Assert ($scan.PolicyHash -eq (Get-SCPolicy $c).Hash -and $scan.ExcludedRoots.Count -eq 2) 'snapshot records policy provenance and exclusions'
$cache=Join-Path $root 'profile\AppData\Local\pip\cache';[IO.Directory]::CreateDirectory($cache)|Out-Null
[IO.File]::WriteAllText((Join-Path $cache 'old.bin'),'cache')
$selected=@([pscustomobject]@{Selected=$true;RuleId='pip-cache';Path=$cache})
$p=Grant-SCRepeatPermission $c $selected -Confirmed
$plan=New-SCCleanupPlan $c $selected ''
Assert ($plan.Status -eq 'Approved') 'explicit repeated rule/scope permission approves only matching cleanup plan'
$other=Join-Path $root 'other\AppData\Local\pip\cache';[IO.Directory]::CreateDirectory($other)|Out-Null;[IO.File]::WriteAllText((Join-Path $other 'old.bin'),'other')
$plan2=New-SCCleanupPlan $c @([pscustomobject]@{Selected=$true;RuleId='pip-cache';Path=$other}) ''
Assert ($plan2.Status -eq 'Proposed') 'repeat permission does not extend to another matching-looking path'
$result=Invoke-SCPlan $c $plan.Id ''
Assert ($result.Status -eq 'Verified') 'repeated cleanup still uses verified shared executor'
$report=@{Passed=$checks.Count;Checks=$checks.ToArray();Utc=[DateTime]::UtcNow.ToString('o');Root=$root}
Write-SCJson (Join-Path $root 'verification.json') $report;$report|ConvertTo-Json -Depth 6
