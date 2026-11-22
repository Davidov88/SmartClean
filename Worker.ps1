#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$JobFile)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'modules\Load.ps1')
$request=Get-Content -LiteralPath $JobFile -Raw -Encoding UTF8|ConvertFrom-Json
$directory=Split-Path $JobFile -Parent
$script:SCJobDirectory=$directory
$script:SCProgressPath=Join-Path $directory 'progress.json'
$cancelFile=Join-Path $directory 'cancel.flag'
$config=Get-SCConfig
if($request.PSObject.Properties['Isolated'] -and $request.Isolated){
    if(-not $request.PSObject.Properties['DataRoot'] -or -not $request.PSObject.Properties['PolicyRoot'] -or -not $request.DataRoot -or -not $request.PolicyRoot){throw 'Изолированный профиль требует DataRoot и PolicyRoot.'}
    $allowed=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'tests')).TrimEnd('\')+'\'
    foreach($root in @($request.DataRoot,$request.PolicyRoot)){$full=[IO.Path]::GetFullPath($root);if(-not $full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Изолированные корни должны находиться внутри tests.'}}
}
if($request.PSObject.Properties['DataRoot'] -and $request.DataRoot){$config.DataRoot=$request.DataRoot}
if($request.PSObject.Properties['PolicyRoot'] -and $request.PolicyRoot){$config|Add-Member NoteProperty PolicyRoot ([string]$request.PolicyRoot) -Force}
Initialize-SCJobContext $config $cancelFile
$workspaceLease=$null;$storageWriter=$null
try{
    $process=Get-Process -Id $PID
    Write-SCJson (Join-Path $directory 'status.json') @{State='Running';Utc=[DateTimeOffset]::UtcNow.ToString('o');OwnerPid=$PID;OwnerStartedUtc=$process.StartTime.ToUniversalTime().ToString('o')}
    $writingActions=@('Overview','Scan','Analyze','Changes','Candidates','CleanupPlan','Duplicates','ResumeDuplicates','DuplicatePlan','OrganizePlan','RelocatePlan','RestorePlan','RecoveryPlan','PurgePlan','Execute','Storage','RemoveArtifact','Maintain')
    if($request.Action -in $writingActions){$storageWriter=Enter-SCStorageWriter $config}
    $script:SCJobContext.StorageRecovery=$request.Action -in @('Storage','SaveStorage','RemoveArtifact','Maintain')
    if($request.Action -in @('Overview','Analyze','Changes','Candidates','CleanupPlan','Duplicates','ResumeDuplicates','DuplicatePlan','OrganizePlan','RelocatePlan','RestorePlan','RecoveryPlan','PurgePlan','Execute')){
        $baseline=Get-SCStorageBaseline $config $cancelFile
        $script:SCJobContext.BaselineBytes=[long]$baseline.Bytes
        $script:SCJobContext.HasStorageBaseline=$true
        Register-SCStorageWrite $directory
    }
    if($request.Action -in @('RowsPage','DuplicatePlan','DuplicateGroups','DuplicateCopies','DuplicatePreview','DuplicateVolumeProposal')){
        $field=switch($request.Action){'RowsPage'{'Path'}'DuplicateGroups'{'GroupsFile'}default{'RowsFile'}}
        $rowsPath=Get-SCField $request.Arguments $field ''
        if($rowsPath){
            $root=[IO.Path]::GetFullPath((Join-Path $config.DataRoot 'work')).TrimEnd('\')+'\'
            Assert-SCOwnPath $root $rowsPath
            $workspaceLease=Enter-SCWorkspaceLease ([IO.Path]::GetDirectoryName($rowsPath))
        }
    }
    Write-SCWorkProgress 'Подготовка задания'
    $a=$request.Arguments
    $result=switch($request.Action){
        'Overview'{
            $inventory=Get-SCInventory;$snapshots=@(Get-SCSnapshots $config);$focus=New-Object 'Collections.Generic.List[object]'
            foreach($group in @($snapshots|Where-Object {$_.HasIndex -and $_.HostId -eq $config.HostId}|Group-Object VolumeId,Root)){
                $m=@($group.Group|Sort-Object StartedUtc -Descending)[0];$cache=Join-Path $config.DataRoot ('reports\'+$m.SnapshotId+'\analysis.json')
                if(Test-Path -LiteralPath $cache){$analysis=Get-Content -LiteralPath $cache -Raw -Encoding UTF8|ConvertFrom-Json}else{$analysis=New-SCAnalysis $m;$export=Export-SCAnalysis $config $analysis}
                foreach($row in $analysis.Focus){$focus.Add([pscustomobject]@{Root=$m.Root;SnapshotId=$m.SnapshotId;Coverage=$m.Coverage;Elevated=$m.Elevated;ExcludedRoots=$m.ExcludedRoots;Path=$row.Path;GiB=[Math]::Round($row.AllocatedBytes/1GB,2);Category=$row.Category;ScanUtc=$m.FinishedUtc})}
            }
            [pscustomobject]@{Inventory=$inventory;Snapshots=$snapshots;Focus=$focus.ToArray();Policy=(Get-SCPolicy $config);Recovery=@(Get-SCPlans $config|Where-Object {$_.Status -in @('InProgress','PartiallyCompleted','Failed','Cancelled')}|ForEach-Object {Get-SCRecovery $config $_.Id}|Select-Object -First 200)}
        }
        'Scan'{Start-SCScan -Config $config -Path $a.Path -CancelFile $cancelFile}
        'Analyze'{
            $m=@(Get-SCSnapshots $config|Where-Object {$_.SnapshotId -eq $a.SnapshotId});if($m.Count -ne 1){throw 'Замер не найден.'}
            $analysis=New-SCAnalysis $m[0];$export=Export-SCAnalysis $config $analysis;$analysis
        }
        'Changes'{
            $before=@(Get-SCSnapshots $config|Where-Object {$_.SnapshotId -eq $a.Before});$after=@(Get-SCSnapshots $config|Where-Object {$_.SnapshotId -eq $a.After})
            if($before.Count -ne 1 -or $after.Count -ne 1){throw 'Выберите старый и новый замеры одного диска.'};Get-SCDiff $before[0] $after[0]
        }
        'Candidates'{[pscustomobject]@{Rows=@(Get-SCCleanupCandidates $config)}}
        'CleanupPlan'{New-SCCleanupPlan $config $a.Candidates $cancelFile}
        'Duplicates'{Find-SCDuplicates $config ([string[]]$a.Roots) $cancelFile}
        'ResumeDuplicates'{Find-SCDuplicates $config ([string[]]$a.Roots) $cancelFile -Resume}
        'DuplicateGroups'{Get-SCDuplicateGroupPage $config $a.GroupsFile ([int]$a.Page) ([bool]$a.CrossVolume)}
        'DuplicateCopies'{Get-SCDuplicateCopies $config $a.RowsFile $a.GroupId ([long]$a.Offset) ([int]$a.Page)}
        'DuplicateVolumeProposal'{Get-SCDuplicateVolumeProposal $config $a}
        'DuplicatePreview'{
            . (Join-Path $PSScriptRoot 'modules\DuplicatePreview.ps1')
            Get-SCDuplicatePreview $config $a
        }
        'DuplicatePlan'{New-SCDuplicatePlan $config $a.Rows $cancelFile -RowsFile $a.RowsFile -Choices $a.Choices -References (Get-SCField $a 'References')}
        'OrganizePlan'{New-SCOrganizationPlan $config $a.Root $a.Destination $cancelFile}
        'RelocatePlan'{New-SCOrganizationPlan $config $a.Root $a.Destination $cancelFile -Relocate}
        'History'{
            $page=[int](Get-SCField $a 'Page' 0)
            if($page -lt 0){throw 'Недопустимая страница.'}
            $base=Join-Path (Get-SCPolicyRoot $config) ('decisions\'+$config.HostId)
            $ids=@(if(Test-Path -LiteralPath $base){
                Get-ChildItem -LiteralPath $base -Directory | Where-Object {$_.Name -match '^[a-f0-9]{32}$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'plan.json'))} | Sort-Object Name -Descending
            })
            $rows=@(Get-SCResultPage $ids $page|ForEach-Object {
                Test-SCCancel $cancelFile
                $plan=Get-SCPlan $config $_.Name
                [pscustomobject]@{Id=$plan.Id;Type=$plan.Type;Status=$plan.Status;CreatedUtc=$plan.CreatedUtc;Count=@($plan.Operations).Count;Bytes=$plan.Bytes}
            })
            [pscustomobject]@{Plans=$rows;Page=$page;Count=$ids.Count}
        }
        'LoadPlan'{Get-SCPlan $config $a.PlanId}
        'Events'{
            $page=[int](Get-SCField $a 'Page' 0);$events=@(Get-SCDecisionEvents $config $a.PlanId);$rows=@(Get-SCResultPage $events $page|ForEach-Object {$details=$_.Details;[pscustomobject]@{EventId=$_.EventId;Utc=$_.Utc;Kind=$_.Kind;Status=$_.Status;Phase=(Get-SCField $details 'Phase' '');Source=(Get-SCField $details 'Source' '');Destination=(Get-SCField $details 'Destination' '');Reason=(Get-SCField $details 'Message' '');Completed=(Get-SCField $details 'Completed' '');Total=(Get-SCField $details 'Total' '');Before=(Get-SCField $details 'Before' @());After=(Get-SCField $details 'After' @())}})
            [pscustomobject]@{Kind='История';PlanId=$a.PlanId;Rows=$rows;Page=$page;Count=$events.Count}
        }
        'EventDetail'{@(Get-SCDecisionEvents $config $a.PlanId|Where-Object {$_.EventId -eq $a.EventId}|Select-Object -First 1)}
        'Approve'{Approve-SCPlan $config $a.PlanId -Confirmed:([bool]$a.Confirmed) -Source 'WPF: explicit approval of displayed plan' -AcceptPartial:([bool](Get-SCField $a 'AcceptPartial' $false))}
        'Execute'{Invoke-SCPlan $config $a.PlanId $cancelFile}
        'RestorePlan'{New-SCRollbackPlan $config $a.PlanId $cancelFile}
        'PurgePlan'{New-SCPurgePlan $config $cancelFile}
        'Browse'{
            $m=@(Get-SCSnapshots $config|Where-Object {$_.SnapshotId -eq $a.SnapshotId -and $_.HostId -eq $config.HostId});if($m.Count -ne 1){throw 'Замер не найден.'}
            $index=Open-SCIndex $m[0]
            try{$node=if($a.Path){$index.FindDirectory($a.Path)}else{$index.Get(0)};if(-not $node){throw 'Каталог отсутствует в сохранённом индексе.'}
                $crumbs=New-Object 'Collections.Generic.List[object]'
                $ancestor=$node
                while($ancestor){
                    Test-SCCancel $cancelFile
                    $label=if($ancestor.ParentId -lt 0){$ancestor.Path}else{[IO.Path]::GetFileName($ancestor.Path)}
                    $crumbs.Add([pscustomobject]@{Path=$ancestor.Path;Label=$label})
                    if($ancestor.ParentId -lt 0){break}
                    $ancestor=$index.Get($ancestor.ParentId)
                }
                $crumbs.Reverse()
                [pscustomobject]@{SnapshotId=$m[0].SnapshotId;Breadcrumbs=$crumbs.ToArray();Path=$node.Path;ParentPath=$(if($node.ParentId -ge 0){$index.Get($node.ParentId).Path}else{''});Page=[int]$a.Page;Metric=$a.Metric;Count=$index.ChildCount($node.Id);Rows=$index.ChildrenPage($node.Id,[int]$a.Page,200,$a.Metric);Manifest=$m[0]}
            }finally{$index.Dispose()}
        }
        'RowsPage'{
            $path=[IO.Path]::GetFullPath($a.Path);$root=[IO.Path]::GetFullPath((Join-Path $config.DataRoot 'work')).TrimEnd('\')+'\'
            if(-not $path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($path) -ne 'rows.jsonl'){throw 'Чужой результат.'}
            if($a.PSObject.Properties['Scope'] -and $a.Scope){$rows=New-Object 'Collections.Generic.List[object]';$count=0L;foreach($line in [IO.File]::ReadLines($path)){Test-SCCancel $cancelFile;$row=$line|ConvertFrom-Json;if($row.Path.StartsWith($a.Scope.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){if($count -ge [int]$a.Page*200 -and $rows.Count -lt 200){$rows.Add($row)};$count++}};[pscustomobject]@{Kind=$a.Kind;Page=[int]$a.Page;Rows=$rows.ToArray();Count=$count}}else{[pscustomobject]@{Kind=$a.Kind;Page=[int]$a.Page;Rows=@(Read-SCJsonLinesPage $path ([int]$a.Page))}}
        }
        'PlanPage'{
            $p=Get-SCPlan $config $a.PlanId;$kind=[string]$a.Kind
            if($kind -eq 'Warnings'){$page=Get-SCPlanFindingsPage $config $p ([int]$a.Page);$rows=@($page.Rows|ForEach-Object {$_.Reason});$count=$page.Count}else{$rows=@(Get-SCResultPage $p.Operations ([int]$a.Page));$count=@($p.Operations).Count}
            [pscustomobject]@{Kind=$kind;Page=[int]$a.Page;Rows=$rows;Count=$count}
        }
        'Diagnostics'{
            $p=Get-SCPlan $config $a.PlanId;$page=Get-SCPlanFindingsPage $config $p ([int]$a.Page)
            [pscustomobject]@{Kind='Diagnostics';Page=$page.Page;Rows=$page.Rows;Count=$page.Count}
        }
        'Recovery'{@(Get-SCRecovery $config $a.PlanId)}
        'RecoveryPlan'{New-SCRecoveryPlan $config $a.PlanId $a.Mode $cancelFile}
        'Storage'{[pscustomobject]@{Inventory=(Get-SCStorageInventory $config $cancelFile);Candidates=@(Get-SCMaintenanceCandidates $config);Config=$config;Snapshots=@(Get-SCSnapshots $config)}}
        'SaveStorage'{Save-SCStorageSettings $config $a.Root ([int]$a.MaxSnapshots) ([double]$a.MaxStoreGiB) ([int]$a.MinimumFreeMiB) ([bool]$a.MaintenanceEnabled)}
        'RemoveArtifact'{Remove-SCOwnArtifact $config $a.Path $a.Kind -Confirmed:([bool]$a.Confirmed);[pscustomobject]@{Removed=$a.Path}}
        'Maintain'{
            if(-not (Get-SCField $config 'MaintenanceEnabled' $false)){throw 'Обслуживание собственных файлов выключено.'}
            if(-not $a.Confirmed){throw 'Сначала подтвердите предварительный список.'}
            foreach($item in @(Get-SCMaintenanceCandidates $config)){Test-SCCancel $cancelFile;Remove-SCOwnArtifact $config $item.Path $item.Kind -Confirmed}
            [pscustomobject]@{Note='Удалены только подходящие завершённые технические артефакты.'}
        }
        'Policy'{Get-SCPolicy $config}
        'SavePolicy'{Save-SCHostPolicy $config $a.Policy ([int]$a.ExpectedRevision)}
        'Protect'{Add-SCProtection $config $a.Path $a.Reason}
        'Exclude'{Add-SCScanExclusion $config $a.Path $a.Reason}
        'PermitRepeat'{Grant-SCRepeatPermission $config $a.Candidates -Confirmed:([bool]$a.Confirmed)}
        default{throw 'Неизвестное действие рабочего процесса.'}
    }
    if($result -and $result.PSObject.Properties['Operations']){
        $result|Add-Member NoteProperty OperationCount @($result.Operations).Count -Force
        $findings=if($result.SchemaVersion -eq 2){Get-SCPlanFindingsPage $config $result 0}else{[pscustomobject]@{Rows=@();Count=@($result.Warnings).Count}}
        $result|Add-Member NoteProperty WarningCount $findings.Count -Force
        if($result.SchemaVersion -eq 2){$result.Preparation.Reasons=@($findings.Rows|ForEach-Object {$_.Reason})}
        $result.Operations=@(Get-SCResultPage $result.Operations 0);$result.Warnings=@(Get-SCResultPage $result.Warnings 0)
        if($result.PSObject.Properties['Preparation']){$result.Preparation.Reasons=@(Get-SCResultPage $result.Preparation.Reasons 0)}
    }
    Assert-SCJobBudget
    Write-SCJson (Join-Path $directory 'result.json') $result
    Write-SCJson (Join-Path $directory 'status.json') @{State='Completed';Utc=[DateTime]::UtcNow.ToString('o')}
}catch{
    $errorObject=$_.Exception;$cancelled=$false
    while($errorObject){if($errorObject -is [OperationCanceledException]){$cancelled=$true;break};$errorObject=$errorObject.InnerException}
    Write-SCJson (Join-Path $directory 'status.json') @{State=$(if($cancelled){'Cancelled'}else{'Failed'});Message=$_.Exception.Message;Stack=$_.ScriptStackTrace;Utc=[DateTime]::UtcNow.ToString('o')}
    exit 1
}
finally{Exit-SCWorkspaceLease $workspaceLease;Exit-SCWorkspaceLease $storageWriter}
