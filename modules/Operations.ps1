function Import-SCFileOperations {
    if(-not ('SmartClean.FileOperations' -as [type])){Add-Type -Path @((Join-Path $script:ProjectRoot 'src\FileOperations.cs'),(Join-Path $script:ProjectRoot 'src\DuplicateFingerprint.cs'))};[SmartClean.FileOperations]::Checkpoint=[Action]{Assert-SCJobBudget}
}
function Get-SCField($Object,[string]$Name,$Fallback=$null) {if($Object -and $Object.PSObject.Properties[$Name]){return $Object.$Name};return $Fallback}
function Test-SCCancel([string]$CancelFile) {Assert-SCJobBudget;if($CancelFile -and (Test-Path -LiteralPath $CancelFile)){throw [OperationCanceledException]::new('Операция остановлена пользователем.')}}
function Get-SCStamp([string]$Path,[string]$CancelFile) {Import-SCFileOperations;[SmartClean.FileOperations]::Describe($Path,$true,$CancelFile)}
function ConvertTo-SCStamp($Value) {
    Import-SCFileOperations;$s=New-Object SmartClean.FileStamp
    foreach($k in @('Path','Identity','SHA256','ContentHash','Security','Length','LastWriteTicks','CreationTicks','AccessTicks','TotalBytes','Links','Attributes','SchemaVersion')){if($Value.PSObject.Properties[$k]){$s.$k=$Value.$k}};if($Value.PSObject.Properties['Streams']){$s.Streams=@($Value.Streams|ForEach-Object {$v=New-Object SmartClean.StreamStamp;$v.Name=$_.Name;$v.Length=$_.Length;$v.SHA256=$_.SHA256;$v})};return $s
}
function Get-SCDecisionDirectory($Config,[string]$PlanId) {
    if($PlanId -notmatch '^[a-f0-9]{32}$'){throw 'Некорректный идентификатор плана.'}
    Join-Path (Get-SCPolicyRoot $Config) ('decisions\'+$Config.HostId+'\'+$PlanId)
}
function Add-SCDecisionEvent($Config,[string]$PlanId,[string]$Kind,[string]$Status,$Details) {
    $directory=Join-Path (Get-SCDecisionDirectory $Config $PlanId) 'events'
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $name=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff')+'-'+[Guid]::NewGuid().ToString('N')+'.json'
    Write-SCJson (Join-Path $directory $name) ([ordered]@{SchemaVersion=1;Utc=[DateTime]::UtcNow.ToString('o');HostId=$Config.HostId;PlanId=$PlanId;Kind=$Kind;Status=$Status;Details=$Details})
}
function Get-SCDecisionEvents($Config,[string]$PlanId) {
    $dir=Join-Path (Get-SCDecisionDirectory $Config $PlanId) 'events'
    if(Test-Path -LiteralPath $dir){Get-ChildItem -LiteralPath $dir -Filter '*.json' -File|Sort-Object Name|ForEach-Object {$event=Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8|ConvertFrom-Json;$event|Add-Member NoteProperty EventId $_.BaseName -Force;$event}}
}
function Get-SCPlan($Config,[string]$PlanId) {
    $file=Join-Path (Get-SCDecisionDirectory $Config $PlanId) 'plan.json';$raw=[IO.File]::ReadAllText($file)
    $plan=$raw|ConvertFrom-Json
    if($plan.SchemaVersion -notin @(1,2) -or $plan.HostId -ne $Config.HostId -or $plan.Id -ne $PlanId){throw 'Несовместимый или чужой план.'}
    foreach($op in $plan.Operations){if($op.Action -notin @('MoveFile','QuarantineFile','PurgeFile','CompletePublishedMove')){throw 'План содержит неизвестное действие.'};if($op.Stamp.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Некорректный отпечаток файла в плане.'}}
    $plan|Add-Member NoteProperty FileHash (Get-SCTextHash $raw) -Force
    $events=@(Get-SCDecisionEvents $Config $PlanId);$state=@($events|Where-Object {$_.Status}|Select-Object -Last 1)
    $plan|Add-Member NoteProperty Status $(if($state.Count){$state[0].Status}else{'Proposed'}) -Force
    return $plan
}
function Get-SCPlans($Config) {
    $root=Join-Path (Get-SCPolicyRoot $Config) ('decisions\'+$Config.HostId)
    if(Test-Path -LiteralPath $root){foreach($folder in @(Get-ChildItem -LiteralPath $root -Directory|Sort-Object LastWriteTime -Descending)){if($folder.Name -match '^[a-f0-9]{32}$'){Get-SCPlan $Config $folder.Name}}}
}
function New-SCFilePlan($Config,[string]$Type,$Mappings,[string]$CancelFile,$Notes=@(),$Preparation=$null) {
    $policy=Get-SCPolicy $Config;$id=[Guid]::NewGuid().ToString('N');$operations=New-Object 'Collections.Generic.List[object]';$warnings=New-Object 'Collections.Generic.List[string]';$seen=@{};$targets=@{};$considered=0;$planLimited=$false
    foreach($mapping in $Mappings){
        Test-SCCancel $CancelFile
        if($operations.Count -ge $policy.Defaults.MaxPlanFiles){$warnings.Add('Достигнут предел файлов: оставшаяся часть не включена в этот план.');$planLimited=$true;break};$considered++
        try{
            $source=Assert-SCMutablePath $Config $policy ([string]$mapping.Source)
            if($seen.ContainsKey($source)){continue};$seen[$source]=$true
            if($operations.Count -ge $policy.Defaults.MaxPlanFiles){throw 'Достигнут лимит файлов плана.'}
            $stamp=Get-SCStamp $source $CancelFile
            $expectedHash=Get-SCField $mapping 'ExpectedContentHash' ''
            if($expectedHash -and $stamp.ContentHash -ne $expectedHash){throw 'Файл изменился после поиска дублей.'}
            [SmartClean.FileOperations]::AssertSupported($source,'',$stamp)
            if($stamp.Links -gt 1){throw 'Файл имеет жёсткие ссылки. Автоматический перенос исключён.'}
            $action=[string](Get-SCField $mapping 'Action' 'MoveFile')
            $destination=[string](Get-SCField $mapping 'Destination' '')
            if($action -eq 'QuarantineFile'){$destination=Join-Path $Config.DataRoot ('vault\'+$id+'\'+$operations.Count.ToString('d6')+'-'+[IO.Path]::GetFileName($source))}
            elseif($action -eq 'PurgeFile'){
                $vault=[IO.Path]::GetFullPath((Join-Path $Config.DataRoot 'vault')).TrimEnd('\')+'\'
                if(-not $source.StartsWith($vault,[StringComparison]::OrdinalIgnoreCase)){throw 'Безвозвратное удаление разрешено только для выбранных файлов карантина SmartClean.'}
            }elseif($action -notin @('MoveFile','CompletePublishedMove')){throw 'Неизвестное действие плана.'}
            if($destination){
                $destination=Assert-SCMutablePath $Config $policy $destination
                if($destination -eq $source -or ((Test-Path -LiteralPath $destination) -and $action -ne 'CompletePublishedMove') -or $targets.ContainsKey($destination)){throw 'Назначение совпадает с источником, занято или повторяется.'};$targets[$destination]=$true
            }
            if($destination){[SmartClean.FileOperations]::AssertSupported($source,$destination,$stamp);Assert-SCDestinationSpace $Config $destination ([SmartClean.FileOperations]::RequiredCopyBytes($stamp,$destination))}
            $existing=$null
            if($action -eq 'CompletePublishedMove'){$existing=Get-SCStamp $destination $CancelFile;if(-not [SmartClean.FileOperations]::SameStamp($existing,(ConvertTo-SCStamp $mapping.DestinationStamp),$true) -or -not [SmartClean.FileOperations]::SameStamp($existing,$stamp,$false)){throw 'Опубликованная копия изменилась.'}}
            $keep=[string](Get-SCField $mapping 'KeepFile' '')
            $keepStamp=$null
            if($keep){$keepStamp=Get-SCStamp $keep $CancelFile;if($keepStamp.Identity -eq $stamp.Identity -or -not [SmartClean.FileOperations]::SameContent($keepStamp,$stamp)){throw 'Сохраняемая копия не является независимым совпадающим файлом.'}}
            $operations.Add([pscustomobject]@{Id=[Guid]::NewGuid().ToString('N');Action=$action;Source=$source;Destination=$destination;Stamp=$stamp;KeepFile=$keep;KeepStamp=$keepStamp;RuleId=(Get-SCField $mapping 'RuleId' '');RuleVersion=1;RuleScope=(Get-SCField $mapping 'RuleScope' '');Bytes=$stamp.TotalBytes;CopyBytes=$(if($destination){[SmartClean.FileOperations]::RequiredCopyBytes($stamp,$destination)}else{0});DestinationStamp=$existing})
        }catch{
            if($_.Exception -is [OperationCanceledException] -or $_.Exception.InnerException -is [OperationCanceledException]){throw}
            $warnings.Add([string]$mapping.Source+': '+$_.Exception.Message)
        }
    }
    $bytes=0L;foreach($operation in $operations){$bytes+=$operation.Bytes}
    $prep=if($Preparation){$Preparation}else{[pscustomobject]@{Discovered=@($Mappings).Count;Limited=$false;Errors=@();Skipped=@()}}
    $partial=$planLimited -or [bool]$prep.Limited -or @($prep.Errors).Count -gt 0 -or $warnings.Count -gt 0
    $coverage=[ordered]@{Discovered=$prep.Discovered;Considered=$considered;Eligible=$operations.Count;CandidateCount=@($Mappings).Count;Included=$operations.Count;Skipped=@($prep.Skipped).Count+$warnings.Count;Limited=$partial;RemainingKnown=(-not (Get-SCField $prep 'DiscoveryLimited' $prep.Limited));Remaining=$(if((Get-SCField $prep 'DiscoveryLimited' $prep.Limited)){$null}else{[Math]::Max(0,[long]$prep.Discovered-$considered)});Diagnostics=@(Get-SCField $prep 'Diagnostics' @());ErrorCount=(Get-SCField $prep 'ErrorCount' @($prep.Errors).Count);SkippedCount=(Get-SCField $prep 'SkippedCount' @($prep.Skipped).Count);Reasons=@($prep.Errors)+@($prep.Skipped)+$warnings.ToArray()}
    $plan=[ordered]@{SchemaVersion=2;Preparation=$coverage;Id=$id;HostId=$Config.HostId;Type=$Type;CreatedUtc=[DateTime]::UtcNow.ToString('o');PolicyHash=$policy.Hash;Operations=$operations.ToArray();Warnings=$warnings.ToArray();Notes=@($Notes);Bytes=$bytes}
    $requirements=@{};$balances=@{};$reserve=[long]$Config.MinimumFreeMiB*1MB
    foreach($op in $operations){
        if($op.Destination -and $op.Action -ne 'CompletePublishedMove'){
            $destRoot=[IO.Path]::GetPathRoot($op.Destination);$sourceRoot=[IO.Path]::GetPathRoot($op.Source)
            if(-not $balances.ContainsKey($destRoot)){$balances[$destRoot]=0L;$requirements[$destRoot]=0L}
            $balances[$destRoot]+=$op.CopyBytes;$requirements[$destRoot]=[Math]::Max([long]$requirements[$destRoot],[long]$balances[$destRoot])
            if($sourceRoot -eq $destRoot){$balances[$destRoot]-=$op.CopyBytes}
        }
    }
    $plan['SpaceRequirements']=@($requirements.Keys|ForEach-Object {[pscustomobject]@{Root=$_;PeakAdditionalBytes=$requirements[$_];ReserveBytes=$reserve}})
    foreach($volume in $requirements.Keys){Assert-SCDestinationSpace $Config $volume $requirements[$volume]}
    $dir=Get-SCDecisionDirectory $Config $id;[IO.Directory]::CreateDirectory($dir)|Out-Null
    $archived=New-Object 'Collections.Generic.List[string]'
    $workRoot=[IO.Path]::GetFullPath((Join-Path $Config.DataRoot 'work')).TrimEnd('\')+'\'
    foreach($path in $coverage.Diagnostics){
        Assert-SCOwnPath $workRoot $path
        $target=Join-Path $dir ('findings-'+$archived.Count+'.jsonl')
        $sourceStream=[IO.File]::OpenRead($path)
        try{$output=[IO.File]::Open($target,[IO.FileMode]::CreateNew);try{$sourceStream.CopyTo($output);$output.Flush($true)}finally{$output.Dispose()}}finally{$sourceStream.Dispose()}
        $archived.Add($target)
    }
    $coverage.Diagnostics=$archived.ToArray()
    $reasonFile=Join-Path $dir 'reasons.jsonl';$reasonWriter=New-Object IO.StreamWriter($reasonFile,$false,$script:Utf8)
    try{foreach($reason in $coverage.Reasons){$reasonWriter.WriteLine((@{Reason=[string]$reason}|ConvertTo-Json -Compress))}}finally{$reasonWriter.Dispose()}
    $coverage.ReasonCount=@($coverage.Reasons).Count;$coverage.Reasons=@($coverage.Reasons|Select-Object -First 200);$coverage.Diagnostics=@($coverage.Diagnostics)+@($reasonFile)
    $plan.Warnings=@($plan.Warnings|Select-Object -First 200)
    Write-SCJson (Join-Path $dir 'plan.json') $plan
    Add-SCDecisionEvent $Config $id 'Created' 'Proposed' @{Count=$operations.Count}
    if(-not $partial -and $Type -eq 'Cleanup' -and (Test-SCRepeatPermission $policy $operations.ToArray())){
        $saved=Get-SCPlan $Config $id
        $bindings=@(Get-SCRepeatBindings $policy $operations.ToArray());$expires=[DateTimeOffset]::UtcNow.AddHours([double]$policy.Defaults.ApprovalHours)
        foreach($binding in $bindings){$end=ConvertTo-SCUtc $binding.ExpiresUtc;if($end -lt $expires){$expires=$end}}
        Add-SCDecisionEvent $Config $id 'Approval' 'Approved' @{PlanHash=$saved.FileHash;ExpiresUtc=$expires.ToString('o');Source='ExactRepeatPermission';Bindings=$bindings;Count=$operations.Count}
    }
    Get-SCPlan $Config $id
}
function Approve-SCPlan($Config,[string]$PlanId,[switch]$Confirmed,[string]$Source='CLI explicit approval',[switch]$AcceptPartial) {
    if(-not $Confirmed){throw 'Необходимо явное подтверждение конкретного плана.'}
    $plan=Get-SCPlan $Config $PlanId;$policy=Get-SCPolicy $Config
    if($plan.SchemaVersion -ne 2){throw 'Исторический план: подготовьте новый план v2.'}
    if($plan.Preparation.Limited -and -not $AcceptPartial){throw 'Требуется явное принятие частичного охвата.'}
    if($plan.PolicyHash -ne $policy.Hash){throw 'Правила изменились: подготовьте план заново.'}
    if(@($plan.Operations).Count -eq 0){throw 'План не содержит операций.'}
    if($plan.Status -in @('Verified','InProgress')){throw 'Этот план уже выполнен или выполняется.'}
    Add-SCDecisionEvent $Config $PlanId 'Approval' 'Approved' @{PlanHash=$plan.FileHash;ExpiresUtc=[DateTime]::UtcNow.AddHours([double]$policy.Defaults.ApprovalHours).ToString('o');Source=$Source;AcceptPartial=[bool]$AcceptPartial;Bindings=@();Count=@($plan.Operations).Count}
    Get-SCPlan $Config $PlanId
}
function Get-SCFreeObservation($Operations) {
    $roots=@($Operations|ForEach-Object {[IO.Path]::GetPathRoot($_.Source);if($_.Destination){[IO.Path]::GetPathRoot($_.Destination)}}|Sort-Object -Unique)
    @($roots|ForEach-Object {$d=New-Object IO.DriveInfo($_);[pscustomobject]@{Root=$_;FreeBytes=$d.AvailableFreeSpace;Utc=[DateTime]::UtcNow.ToString('o')}})
}
function Invoke-SCPlan($Config,[string]$PlanId,[string]$CancelFile) {
    if(-not $script:SCReleaseAllowsMutation){throw 'Промежуточная версия 0.4: исполнение пользовательских переносов, очистки и purge выключено. Диагностика и подготовка планов доступны.'}
    $mutex=New-Object Threading.Mutex($false,('Local\SmartClean-Mutation-'+$Config.HostId));$held=$false
    try{
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'Другая операция SmartClean уже изменяет файлы. Дождитесь её завершения.'}
        $plan=Get-SCPlan $Config $PlanId;$policy=Get-SCPolicy $Config
        if($plan.SchemaVersion -ne 2){throw 'Планы v1 доступны только как история. Подготовьте новый план.'}
        if($plan.Status -eq 'Verified'){throw 'План уже выполнен.'}
        if($plan.PolicyHash -ne $policy.Hash){throw 'Правила изменились после создания плана. Подготовьте новый план.'}
        $events=@(Get-SCDecisionEvents $Config $PlanId)
        if(@($events|Where-Object {$_.Kind -eq 'RecoveryResolved'}).Count){throw 'План прошёл восстановление; подготовьте новый план для оставшихся действий.'}
        if(@(Get-SCRecovery $Config $PlanId).Count){throw 'Есть незавершённые фазы. Сначала подготовьте отдельный план восстановления.'}
        $approved=@($events|Where-Object {$_.Kind -eq 'Approval' -and $_.Details.PlanHash -eq $plan.FileHash -and (Test-SCExpiry $_.Details.ExpiresUtc)})
        if(-not $approved.Count){throw 'Нет действующего подтверждения именно этого плана.'}
        $approval=$approved[-1]
        Assert-SCApproval $Config $plan $approval
        $done=@{};foreach($e in $events){if($e.Kind -eq 'OperationVerified'){$done[[string]$e.Details.OperationId]=$true}}
        $before=@(Get-SCFreeObservation $plan.Operations);$completed=$done.Count;$failures=New-Object 'Collections.Generic.List[object]';$cancelled=$false
        Add-SCDecisionEvent $Config $PlanId 'Started' 'InProgress' @{Before=$before}
        foreach($op in $plan.Operations){
            if($done.ContainsKey([string]$op.Id)){continue}
            try{
                Test-SCCancel $CancelFile
                $currentPolicy=Get-SCPolicy $Config
                Assert-SCApproval $Config $plan $approval
                if($currentPolicy.Hash -ne $plan.PolicyHash){throw 'Политика изменена во время выполнения.'}
                $source=Assert-SCMutablePath $Config $currentPolicy $op.Source
                $expected=ConvertTo-SCStamp $op.Stamp
                if($op.RuleId){Assert-SCCleanupPrecondition $Config $currentPolicy $op}
                if($op.Action -eq 'PurgeFile'){
                    $vault=[IO.Path]::GetFullPath((Join-Path $Config.DataRoot 'vault')).TrimEnd('\')+'\'
                    if(-not $source.StartsWith($vault,[StringComparison]::OrdinalIgnoreCase)){throw 'Удаление вне карантина запрещено.'}
                    $now=Get-SCStamp $source $CancelFile
                    if(-not [SmartClean.FileOperations]::SameStamp($now,$expected,$true)){throw 'Файл карантина изменился.'}
                    Assert-SCApproval $Config $plan $approval
                    Add-SCDecisionEvent $Config $PlanId 'Phase' '' @{OperationId=$op.Id;Phase='PurgeIntent';Source=$source;Temporary='';SourceStamp=$expected}
                    [SmartClean.FileOperations]::DeleteVerified($source,$expected,$CancelFile,[Action]{Assert-SCApproval $Config $plan $approval});$destinationStamp=$null
                    if(Test-Path -LiteralPath $source){throw 'Файл не удалён.'}
                }else{
                    $destination=Assert-SCMutablePath $Config $currentPolicy $op.Destination
                    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))|Out-Null
                    $checked=Assert-SCMutablePath $Config $currentPolicy $destination
                    $authorize=[Action]{Test-SCCancel $CancelFile;Assert-SCApproval $Config $plan $approval;$p=Get-SCPolicy $Config;$null=Assert-SCMutablePath $Config $p $source;$null=Assert-SCMutablePath $Config $p $destination;if($op.RuleId){Assert-SCCleanupPrecondition $Config $p $op}}
                    $phase=[Action[string,SmartClean.FileStamp,string]]{param($name,$stamp,$temporary)
                        Add-SCDecisionEvent $Config $PlanId 'Phase' '' @{OperationId=$op.Id;Phase=$name;Source=$source;Destination=$destination;Temporary=$temporary;SourceStamp=$expected;DestinationStamp=$stamp}
                    }
                    if($op.Action -eq 'CompletePublishedMove'){
                        $published=ConvertTo-SCStamp $op.DestinationStamp
                        $phase.Invoke('DestinationPublished',$published,'')
                        $destinationStamp=[SmartClean.FileOperations]::FinishPublishedMove($source,$destination,$expected,$published,$CancelFile,[Action]{
                            $authorize.Invoke()
                            $phase.Invoke('SourceDeleteAuthorized',$published,'')
                        })
                        $phase.Invoke('SourceRemoved',$destinationStamp,'')
                    }else{
                        Assert-SCDestinationSpace $Config $destination ([SmartClean.FileOperations]::RequiredCopyBytes($expected,$destination))
                        if($op.KeepFile){$destinationStamp=[SmartClean.FileOperations]::MoveDuplicate($source,$destination,$expected,$op.KeepFile,(ConvertTo-SCStamp $op.KeepStamp),$CancelFile,$phase,$authorize)}
                        else{$destinationStamp=[SmartClean.FileOperations]::MoveVerified($source,$destination,$expected,$CancelFile,$phase,$authorize)}
                    }
                }
                $completed++
                Add-SCDecisionEvent $Config $PlanId 'OperationVerified' '' @{OperationId=$op.Id;Action=$op.Action;Source=$source;Destination=$op.Destination;DestinationStamp=$destinationStamp;Bytes=$op.Bytes}
            }catch{
                $cancelled=$_.Exception -is [OperationCanceledException] -or $_.Exception.InnerException -is [OperationCanceledException]
                $failure=[pscustomobject]@{OperationId=$op.Id;Message=$_.Exception.Message;SourceExists=(Test-Path -LiteralPath $op.Source);DestinationExists=($op.Destination -and (Test-Path -LiteralPath $op.Destination))}
                $failures.Add($failure);Add-SCDecisionEvent $Config $PlanId 'OperationFailed' '' $failure;break
            }
        }
        $after=@(Get-SCFreeObservation $plan.Operations)
        $state=if($failures.Count){if($completed){'PartiallyCompleted'}elseif($cancelled){'Cancelled'}else{'Failed'}}else{'Verified'}
        $result=[pscustomobject]@{PlanId=$PlanId;Status=$state;Completed=$completed;Total=@($plan.Operations).Count;Failures=$failures.ToArray();Before=$before;After=$after;Note='Изменение свободного места наблюдается при работающих программах. Карантин на том же диске не освобождает этот диск.'}
        Add-SCDecisionEvent $Config $PlanId 'Finished' $state $result
        if($state -eq 'Verified'){foreach($link in @($events|Where-Object {$_.Kind -eq 'RecoveryLink'})){foreach($originalId in @($link.Details.OperationIds)){Add-SCDecisionEvent $Config $link.Details.OriginalPlanId 'RecoveryResolved' '' @{OperationId=$originalId;RecoveryPlanId=$PlanId;Mode=$link.Details.Mode}}}}
        Initialize-SCStore $Config;Add-SCHistory $Config @{Type='execute-plan';Result=$result}
        return $result
    }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function New-SCRollbackPlan($Config,[string]$PlanId,[string]$CancelFile) {
    $events=@(Get-SCDecisionEvents $Config $PlanId|Where-Object {$_.Kind -eq 'OperationVerified' -and $_.Details.Action -ne 'PurgeFile'})
    $mappings=New-Object 'Collections.Generic.List[object]'
    foreach($e in $events){
        $d=$e.Details
        if(Test-Path -LiteralPath $d.Source){throw 'Исходный путь уже занят: восстановление не перезаписывает данные.'}
        $now=Get-SCStamp $d.Destination $CancelFile
        if(-not [SmartClean.FileOperations]::SameStamp($now,(ConvertTo-SCStamp $d.DestinationStamp),$true)){throw 'Перенесённый файл изменился: автоматический откат остановлен.'}
        $mappings.Add([pscustomobject]@{Source=$d.Destination;Destination=$d.Source;Action='MoveFile'})
    }
    New-SCFilePlan $Config 'Restore' $mappings.ToArray() $CancelFile @('Восстановление по журналу плана '+$PlanId)
}

function Assert-SCDestinationSpace($Config,[string]$Destination,[long]$Bytes) {
    $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Destination))
    if(-not $drive.IsReady -or $drive.AvailableFreeSpace -lt ($Bytes+[long]$Config.MinimumFreeMiB*1MB)){throw 'Недостаточно места для полной проверяемой копии и резерва. Карантин на том же томе не освобождает место.'}
}
function Assert-SCApproval($Config,$Plan,$Approval) {
    if($Approval.Details.PlanHash -ne $Plan.FileHash -or -not (Test-SCExpiry $Approval.Details.ExpiresUtc)){throw 'Подтверждение истекло или относится к другому плану.'}
    $policy=Get-SCPolicy $Config
    if($policy.Hash -ne $Plan.PolicyHash){throw 'Политика изменилась; требуется новый план.'}
    if($Plan.Preparation.Limited -and -not (Get-SCField $Approval.Details 'AcceptPartial' $false)){throw 'Частичный охват не принят.'}
    if($Approval.Details.Source -eq 'ExactRepeatPermission'){
        if(-not (Test-SCRepeatPermission $policy $Plan.Operations)){throw 'Повторное разрешение отозвано или истекло.'}
        foreach($binding in $Approval.Details.Bindings){if(-not (Test-SCExpiry $binding.ExpiresUtc)){throw 'Исходное разрешение истекло.'}}
    }
}
function Get-SCRecovery($Config,[string]$PlanId) {
    $plan=Get-SCPlan $Config $PlanId;$events=@(Get-SCDecisionEvents $Config $PlanId)
    $done=@{};$phases=@{};$copies=@{}
    foreach($event in $events){
        $id=Get-SCField $event.Details 'OperationId' ''
        if(-not $id){continue}
        if($event.Kind -in @('OperationVerified','RecoveryResolved')){$done[$id]=$true}
        if($event.Kind -eq 'Phase'){
            $phases[$id]=$event.Details
            $copy=Get-SCField $event.Details 'DestinationStamp'
            if($copy -and $event.Details.Phase -in @('CopyVerified','PublishIntent','DestinationPublished','SourceDeleteAuthorized','SourceRemoved')){$copies[$id]=$copy}
        }
    }
    foreach($op in $plan.Operations){
        Test-SCCancel ''
        if($done.ContainsKey($op.Id) -or -not $phases.ContainsKey($op.Id)){continue}
        $last=$phases[$op.Id]
        [pscustomobject]@{PlanId=$PlanId;OperationId=$op.Id;Phase=$last.Phase;Source=$op.Source;Destination=$op.Destination;Temporary=(Get-SCField $last 'Temporary' '');DestinationStamp=$copies[$op.Id];Note='Требуется сверка файлов и отдельный план восстановления.'}
    }
}
function New-SCRecoveryPlan($Config,[string]$PlanId,[ValidateSet('Finish','QuarantineCopy')][string]$Mode,[string]$CancelFile) {
    $old=Get-SCPlan $Config $PlanId;$mappings=New-Object 'Collections.Generic.List[object]';$operationIds=New-Object 'Collections.Generic.List[string]'
    foreach($r in @(Get-SCRecovery $Config $PlanId)){
        Test-SCCancel $CancelFile
        $op=@($old.Operations|Where-Object {$_.Id -eq $r.OperationId})[0];$operationIds.Add($op.Id)
        $destination=if($r.Destination -and (Test-Path -LiteralPath $r.Destination)){$r.Destination}else{$r.Temporary}
        if(-not $destination -or -not $r.DestinationStamp){throw 'Нет проверенной копии; требуется ручной разбор без изменений.'}
        $copy=Get-SCStamp $destination $CancelFile
        if(-not [SmartClean.FileOperations]::SameStamp($copy,(ConvertTo-SCStamp $r.DestinationStamp),$true)){throw 'Копия изменилась; восстановление остановлено.'}
        if(-not (Test-Path -LiteralPath $op.Source)){
            if($Mode -eq 'Finish'){throw 'Источник отсутствует. Используйте план восстановления копии на исходный путь.'}
            $mappings.Add([pscustomobject]@{Source=$destination;Destination=$op.Source;Action='MoveFile'});continue
        }
        if(-not [SmartClean.FileOperations]::SameStamp((Get-SCStamp $op.Source $CancelFile),(ConvertTo-SCStamp $op.Stamp),$true)){throw 'Источник изменился; автоматическое восстановление запрещено.'}
        if($Mode -eq 'Finish'){
            if($destination -ne $op.Destination){throw 'Копия ещё не опубликована; сначала уберите её в карантин отдельным планом.'}
            $mappings.Add([pscustomobject]@{Source=$op.Source;Destination=$destination;Action='CompletePublishedMove';DestinationStamp=$copy})
        }else{$mappings.Add([pscustomobject]@{Source=$destination;Action='QuarantineFile';KeepFile=$op.Source})}
    }
    $new=New-SCFilePlan $Config 'Recovery' $mappings.ToArray() $CancelFile @('Восстановление частичных фаз плана '+$PlanId+'; '+$Mode)
    if($new.Operations.Count -ne $mappings.Count){throw 'Не все операции восстановления допустимы. План не утверждён; исходный журнал не изменён.'}
    Add-SCDecisionEvent $Config $new.Id 'RecoveryLink' '' @{OriginalPlanId=$PlanId;OperationIds=$operationIds.ToArray();Mode=$Mode}
    return $new
}

function Get-SCPlanFindingsPage($Config,$Plan,[int]$Page=0) {
    if($Page -lt 0){throw 'Некорректная страница.'}
    $rows=New-Object 'Collections.Generic.List[object]';$count=0L
    foreach($path in @(Get-SCField $Plan.Preparation 'Diagnostics' @())){
        $full=[IO.Path]::GetFullPath($path);$work=[IO.Path]::GetFullPath((Join-Path $Config.DataRoot 'work')).TrimEnd('\')+'\';$decision=[IO.Path]::GetFullPath((Get-SCDecisionDirectory $Config $Plan.Id)).TrimEnd('\')+'\'
        $roots=@($decision,$work)+@(Get-SCField $Config 'PreviousDataRoots' @()|ForEach-Object {[IO.Path]::GetFullPath((Join-Path $_ 'work')).TrimEnd('\')+'\'})
        $base=@($roots|Where-Object {$full.StartsWith($_,[StringComparison]::OrdinalIgnoreCase)}|Select-Object -First 1)
        if(-not $base.Count){throw 'Диагностика не принадлежит этому плану или рабочему хранилищу.'}
        Assert-SCOwnPath $base[0] $full
        if(-not [IO.File]::Exists($full)){continue}
        foreach($line in [IO.File]::ReadLines($full)){Test-SCCancel ''
            if($count -ge $Page*200 -and $rows.Count -lt 200){$r=$line|ConvertFrom-Json;$rows.Add([pscustomobject]@{Reason=$(if($r.PSObject.Properties['Path']){$r.Path+': '+$r.Reason}else{$r.Reason})})};$count++
        }
    }
    [pscustomobject]@{Rows=$rows.ToArray();Count=$count;Page=$Page}
}
