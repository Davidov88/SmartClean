#requires -Version 5.1
[CmdletBinding()]
param([switch]$SmokeTest,[string]$ScreenshotPath,[string]$AppRoot)
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Запустите интерфейс через Start-SmartClean.cmd (STA).'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
$project=if($AppRoot){$AppRoot.TrimEnd('\')}else{Split-Path $PSScriptRoot -Parent}
$uiRoot=Join-Path $project 'ui'
. (Join-Path $project 'modules\Load.ps1')
. (Join-Path $uiRoot 'Storage.ps1')
$script:Config=Get-SCConfig
if(-not $script:Config.Configured){$setup=Show-SCStorageDialog $script:Config;if(-not $setup){return};$script:Config=Save-SCStorageSettings $script:Config $setup.Root $setup.MaxSnapshots $setup.MaxStoreGiB $setup.MinimumFreeMiB $false}
Initialize-SCStore $script:Config;$initialPolicy=Get-SCPolicy $script:Config
[xml]$xaml=[IO.File]::ReadAllText((Join-Path $uiRoot 'MainWindow.xaml'))
$xmlReader=New-Object Xml.XmlNodeReader($xaml)
$script:Window=[Windows.Markup.XamlReader]::Load($xmlReader)
$script:C=@{}
foreach($node in $xaml.SelectNodes('//*[@Name]')){$script:C[$node.Name]=$script:Window.FindName($node.Name)}
$script:ActiveJob=$null;$script:CurrentPlan=$null;$script:LoadedPolicy=$initialPolicy;$script:Snapshots=@();$script:SmokeDone=$false
$script:C.ExecuteButton.ToolTip='Промежуточная версия 0.4: исполнение изменений пользовательских файлов пока выключено.'
$script:C.ScanRootBox.Text=[IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows'))
function Set-SCGrid([string]$Name,$Rows){$items=[object[]]@($Rows|Where-Object {$null -ne $_});$script:C[$Name].ItemsSource=$items;$script:C[$Name].ToolTip=$(if($items.Count){'Получено записей на странице: '+$items.Count+'; полный текст — в подробностях'}else{'Результат получен: подходящих записей нет. Измените область или правила.'});if((Get-Variable EmptyLabels -Scope Script -ErrorAction SilentlyContinue) -and $script:EmptyLabels.ContainsKey($Name)){$script:EmptyLabels[$Name].Text=$script:C[$Name].ToolTip;$script:EmptyLabels[$Name].Visibility=$(if($items.Count){'Collapsed'}else{'Visible'})}}
function Show-SCUiError([string]$Message){$script:C.StatusText.Text=$Message;[Windows.MessageBox]::Show($script:Window,$Message,'SmartClean',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Warning)|Out-Null}
function Set-SCUiBusy([bool]$Busy){
    foreach($button in $script:C.BrowseBreadcrumbs.Children){$button.IsEnabled=-not $Busy}
    $script:C.CancelButton.IsEnabled=$Busy;$script:C.BusyBar.IsIndeterminate=$Busy
    foreach($name in $script:C.Keys){if($script:C[$name] -is [Windows.Controls.Button] -and $name -notin @('CancelButton','DetailsButton')){$script:C[$name].IsEnabled=-not $Busy}}
    if(-not $Busy){if(Get-Variable DuplicateResult -Scope Script -ErrorAction SilentlyContinue){if(Get-Command Update-SCDuplicateControls -ErrorAction SilentlyContinue){Update-SCDuplicateControls};if(Get-Variable RuleField -Scope Script -ErrorAction SilentlyContinue){$script:C.RuleAddButton.IsEnabled=$script:RuleField -ne 'CleanupPermissions'}};$script:C.ApproveButton.IsEnabled=$script:CurrentPlan -and $script:CurrentPlan.SchemaVersion -eq 2 -and $script:CurrentPlan.OperationCount -gt 0 -and $script:CurrentPlan.Status -notin @('Verified','InProgress');$script:C.ExecuteButton.IsEnabled=$script:SCReleaseAllowsMutation -and $script:CurrentPlan -and $script:CurrentPlan.Status -eq 'Approved' -and $script:CurrentPlan.SchemaVersion -eq 2}
}
function Start-SCUiJob([string]$Action,$Arguments) {
    $section=Get-SCJobSection $Action
    try{
        if($script:ActiveJob){throw 'Дождитесь текущей операции или нажмите «Остановить».'}
        $dir=Join-Path $script:Config.DataRoot ('jobs\'+[Guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($dir)|Out-Null
        $request=Join-Path $dir 'request.json'
        Write-SCJson $request @{SchemaVersion=1;Action=$Action;Arguments=$Arguments;DataRoot=$script:Config.DataRoot;PolicyRoot=(Get-SCPolicyRoot $script:Config)}
        $exe=Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
        $args='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File '+(ConvertTo-SCArgument (Join-Path $script:ProjectRoot 'Worker.ps1'))+' -JobFile '+(ConvertTo-SCArgument $request)
        $p=Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $dir 'stdout.log') -RedirectStandardError (Join-Path $dir 'stderr.log')
        $handle=$p.Handle
        $script:ActiveJob=[pscustomobject]@{Action=$Action;Section=$section;Directory=$dir;Process=$p;Started=[DateTime]::UtcNow;Reader=$null;ReadHandle=$null}
        Set-SCUiBusy $true;$script:C.StatusText.Text='Выполняется: '+(Get-SCUiText $Action);Set-SCSectionState $section 'Выполняется'
    }catch{Set-SCSectionState $section 'Ошибка запуска';Show-SCUiError $_.Exception.Message}
}
function Set-SCUiPolicy($Policy){
    $script:LoadedPolicy=$Policy
    Set-SCGrid 'ProtectionGrid' $Policy.ProtectedPaths
    $script:C.HostPolicyBox.Text=ConvertTo-Json -InputObject $Policy.Host -Depth 16
    if(Get-Command Set-SCRuleForm -ErrorAction SilentlyContinue){Set-SCRuleForm}
    if($script:CurrentPlan -and $script:CurrentPlan.PolicyHash -ne $Policy.Hash){$script:C.ExecuteButton.IsEnabled=$false;$script:C.ApproveButton.IsEnabled=$false}
}
function Set-SCUiPlan($Plan){
    $script:CurrentPlan=$Plan
    foreach($kind in @('План','Предупреждения','Диагностика')){$script:PageNumbers[$kind]=0}
    if(-not $Plan.PSObject.Properties['Preparation']){$Plan|Add-Member NoteProperty Preparation ([pscustomobject]@{Reasons=@('Исторический формат v1; исполнение запрещено.');Limited=$false})}
    $rows=@($Plan.Operations|ForEach-Object {$_|Add-Member NoteProperty MiB ([Math]::Round($_.Bytes/1MB,2)) -Force;$_|Add-Member NoteProperty ActionLabel (Get-SCUiText $_.Action) -Force;$_})
    Set-SCGrid 'PlanGrid' $rows
    $warnings=' | Предупреждений: '+$Plan.WarningCount;Set-SCGrid 'WarningsGrid' @($Plan.Preparation.Reasons|ForEach-Object {[pscustomobject]@{Reason=[string]$_}})
    $script:C.PlanDetailsText.Text=('{0} | {1} | {2} файлов | {3} | {4}{5}' -f $Plan.Id,(Get-SCUiText $Plan.Type),$Plan.OperationCount,(Format-SCBytes $Plan.Bytes),(Get-SCUiText $Plan.Status),$warnings)
    if($Plan.SchemaVersion -eq 2 -and $Plan.Preparation.Limited){$script:C.PlanDetailsText.Text+="`nЧАСТИЧНЫЙ ПЛАН: обнаружено $($Plan.Preparation.Discovered), включено $($Plan.OperationCount); остаток: $(if($Plan.Preparation.RemainingKnown){$Plan.Preparation.Remaining}else{'неизвестен'})."}
    if($Plan.Notes.Count){$script:C.PlanDetailsText.Text+="`n"+($Plan.Notes -join ' ')}
    $script:C.PlanExpander.IsExpanded=$true
    $script:C.ApproveButton.IsEnabled=$Plan.SchemaVersion -eq 2 -and $Plan.OperationCount -gt 0 -and $Plan.Status -notin @('Verified','InProgress')
    $script:C.ExecuteButton.IsEnabled=$script:SCReleaseAllowsMutation -and $Plan.SchemaVersion -eq 2 -and $Plan.Status -eq 'Approved'
}
function Handle-SCUiResult([string]$Action,$Result){
    switch($Action){
        'Overview'{
            $volumes=@($Result.Inventory.Volumes|Sort-Object @{Expression={if($_.DriveLetter){0}else{1}}},DriveLetter|ForEach-Object {
                $v=$_;$media=@($Result.Inventory.Disks|Where-Object {$v.DiskNumbers -contains $_.Number}|ForEach-Object {$_.MediaType}) -join ', '
                [pscustomobject]@{DriveLetter=$(if($v.DriveLetter){$v.DriveLetter+':'}else{$v.Path});Label=$v.Label;FileSystem=$v.FileSystem;TotalGiB=[Math]::Round($v.SizeBytes/1GB,2);FreeGiB=[Math]::Round($v.FreeBytes/1GB,2);Medium=$media}
            })
            Set-SCGrid 'VolumesGrid' $volumes
            Set-SCGrid 'FocusGrid' @($Result.Focus|Sort-Object Root,@{Expression={$_.GiB};Descending=$true}|ForEach-Object {$_|Add-Member NoteProperty ScanLabel ([DateTime]::Parse($_.ScanUtc).ToUniversalTime().ToString('dd.MM HH:mm')) -Force;$_})
            $script:Snapshots=@($Result.Snapshots|Where-Object {$_.HasIndex})
            foreach($m in $script:Snapshots){$m|Add-Member NoteProperty Label ($m.Root+'  '+$m.FinishedUtc+'  '+$m.SnapshotId) -Force}
            foreach($name in @('SnapshotPicker','BeforePicker','AfterPicker')){$script:C[$name].ItemsSource=[object[]]$script:Snapshots;$script:C[$name].DisplayMemberPath='Label'}
            if($script:Snapshots.Count){$script:C.SnapshotPicker.SelectedIndex=0;$script:C.BeforePicker.SelectedIndex=0}
            $pair=@($script:Snapshots|Group-Object Root,VolumeId|Where-Object {$_.Count -ge 2}|Select-Object -First 1)
            if($pair.Count){$ordered=@($pair[0].Group|Sort-Object StartedUtc -Descending);$script:C.BeforePicker.SelectedItem=$ordered[1];$script:C.AfterPicker.SelectedItem=$ordered[0]}
            else{$script:C.GrowthHint.Text='Пока нет двух замеров одного диска. Выполните новый скан того же тома, затем сравните с предыдущим.'}
            Set-SCUiPolicy $Result.Policy
            $script:C.CoverageText.Text='Сохранённые карты: охват не подтверждён. Дата, права и исключения доступны в подробностях выбранной строки.'
            if(@($Result.Recovery).Count){$script:C.CoverageText.Text+=' Есть незавершённые операции: откройте историю и журнал фаз.'}
        }
        'Scan'{
            if($Result.HasIndex){$script:C.StatusText.Text='Скан сохранён. Полнота доступа не подтверждена движком.';Start-SCUiJob 'Overview' @{}}
            elseif($Result.Status -eq 'cancelled'){$script:C.StatusText.Text='Сканирование остановлено; готового дерева этого запуска нет.'}
            else{Show-SCUiError ('Скан: '+$Result.Status+' '+$Result.Failure)}
        }
        'Analyze'{
            Set-SCGrid 'FocusGrid' @($Result.Focus|ForEach-Object {[pscustomobject]@{SnapshotId=$Result.SnapshotId;Path=$_.Path;GiB=[Math]::Round($_.AllocatedBytes/1GB,2);Category=$_.Category;ScanLabel=[DateTime]::Parse($Result.ScanFinishedUtc).ToUniversalTime().ToString('dd.MM HH:mm')}})
            $script:C.StatusText.Text='Разбор и карта ссылок сохранены; скан исходного диска не повторялся.'
        }
        'Changes'{
            $script:GrowthResult=$Result;$script:PageNumbers['Рост']=0;Set-SCGrowthRows $Result.Changes
            $script:C.GrowthHint.Text=$Result.Warning
        }
        'Candidates'{Set-SCGrid 'CandidatesGrid' @($Result.Rows|ForEach-Object {$_|Add-Member NoteProperty MiB ([Math]::Round($_.ObservedBytes/1MB,2)) -Force;$_})}
        {$_ -in @('Duplicates','ResumeDuplicates')}{Set-SCDuplicateResult $Result}
        'DuplicateGroups'{Set-SCDuplicateGroupPage $Result}
        'DuplicateCopies'{Set-SCDuplicateCopyPage $Result}
        'DuplicatePreview'{Show-SCDuplicateImage $Result}
        'DuplicateVolumeProposal'{Set-SCDuplicateVolumeProposal $Result}
        {$_ -in @('CleanupPlan','DuplicatePlan','OrganizePlan','RelocatePlan','RestorePlan','RecoveryPlan','PurgePlan','Approve','LoadPlan')}{Set-SCUiPlan $Result}
        'Execute'{
            $script:C.HistoryDetailsBox.Text=(Get-SCUiText $Result.Status)+'; выполнено '+$Result.Completed+' из '+$Result.Total+"`r`n"+$Result.Note+"`r`n"+(@($Result.Failures|ForEach-Object {$_.OperationId+': '+$_.Message}) -join "`r`n")
            $script:C.ExecuteButton.IsEnabled=$false;$script:C.ApproveButton.IsEnabled=$false
            $script:C.PlanDetailsText.Text+=' | Итог: '+$Result.Status+'; проверено файлов: '+$Result.Completed
            if($Result.Status -notin @('Verified','Cancelled')){Show-SCUiError ('Операция завершилась со статусом '+$Result.Status+'. Подробности в истории; не повторяйте вслепую.')}
            Start-SCUiJob 'History' @{}
        }
        'History'{$script:PlanHistory=$Result;$script:PageNumbers['Планы истории']=$Result.Page;$script:C.PageLabel.Text='Планы: страница '+($Result.Page+1)+'; всего '+$Result.Count;Set-SCGrid 'HistoryGrid' @($Result.Plans|ForEach-Object {$_|Add-Member NoteProperty TypeLabel (Get-SCUiText $_.Type) -Force;$_|Add-Member NoteProperty StatusLabel (Get-SCUiText $_.Status) -Force;$_})}
        'Events'{Set-SCHistoryEvents $Result}
        'EventDetail'{$script:C.HistoryDetailsBox.Text=ConvertTo-Json -InputObject $Result -Depth 16}
        'Browse'{Set-SCBrowseResult $Result}
        'RowsPage'{Set-SCPagedResult $Result}
        'PlanPage'{Set-SCPagedResult $Result}
        'Diagnostics'{Set-SCPagedResult $Result}
        'Recovery'{$script:C.HistoryDetailsBox.Text=ConvertTo-Json -InputObject $Result -Depth 10}
        'Storage'{$value=Show-SCStorageDialog $script:Config $Result $script:Window;if($value){if($value.PSObject.Properties['Action']){Start-SCUiJob $value.Action $value}else{Start-SCUiJob 'SaveStorage' $value}}}
        'SaveStorage'{$script:Config=$Result;Clear-SCDuplicateResult;Start-SCUiJob 'Overview' @{}}
        {$_ -in @('RemoveArtifact','Maintain')}{Start-SCUiJob 'Overview' @{}}
        {$_ -in @('Policy','SavePolicy','Protect','Exclude','PermitRepeat')}{Set-SCUiPolicy $Result;$script:C.StatusText.Text='Общие правила прочитаны. Хеш политики: '+$Result.Hash.Substring(0,12)}
    }
}
function Get-SCUiPlanSelection {if(-not $script:C.HistoryGrid.SelectedItem){throw 'Выберите план в истории.'};return $script:C.HistoryGrid.SelectedItem.Id}
function Pick-SCUiFolder([string]$Control,[switch]$Append) {
    $dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description='Выберите фактическую папку';$dialog.ShowNewFolderButton=$true
    try{if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){if($Append -and $script:C[$Control].Text){$script:C[$Control].Text+="`r`n"+$dialog.SelectedPath}else{$script:C[$Control].Text=$dialog.SelectedPath}}}finally{$dialog.Dispose()}
}
function On-SCUiClick([string]$Name,[scriptblock]$Body){$script:C[$Name].Add_Click($Body)}
On-SCUiClick 'RefreshButton' {Start-SCUiJob 'Overview' @{}}
On-SCUiClick 'CancelButton' {if($script:ActiveJob){[IO.File]::WriteAllText((Join-Path $script:ActiveJob.Directory 'cancel.flag'),'cancel');$script:C.StatusText.Text='Остановка запрошена. Дождитесь результата текущего файла.'}}
On-SCUiClick 'PickScanRoot' {Pick-SCUiFolder 'ScanRootBox'}
On-SCUiClick 'ScanButton' {Start-SCUiJob 'Scan' @{Path=$script:C.ScanRootBox.Text}}
On-SCUiClick 'AnalyzeButton' {if($script:C.SnapshotPicker.SelectedItem){Start-SCUiJob 'Analyze' @{SnapshotId=$script:C.SnapshotPicker.SelectedItem.SnapshotId}}else{Show-SCUiError 'Сначала выберите сохранённый замер.'}}
On-SCUiClick 'ReportButton' {
    if($script:C.SnapshotPicker.SelectedItem){$file=Join-Path $script:Config.DataRoot ('reports\'+$script:C.SnapshotPicker.SelectedItem.SnapshotId+'\summary.md');if(Test-Path -LiteralPath $file){Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('System')) 'notepad.exe') -ArgumentList (ConvertTo-SCArgument $file)}else{Show-SCUiError 'Сначала нажмите «Разобрать замер».'}}
}
On-SCUiClick 'CompareButton' {
    $a=$script:C.BeforePicker.SelectedItem;$b=$script:C.AfterPicker.SelectedItem
    if(-not $a -or -not $b){Show-SCUiError 'Нужны два замера одного диска.'}elseif($a.Root -ne $b.Root){Show-SCUiError 'Выберите два замера одной области.'}else{Start-SCUiJob 'Changes' @{Before=$a.SnapshotId;After=$b.SnapshotId}}
}
On-SCUiClick 'CandidatesButton' {Start-SCUiJob 'Candidates' @{}}
On-SCUiClick 'CleanupPlanButton' {$script:C.CandidatesGrid.CommitEdit()|Out-Null;Start-SCUiJob 'CleanupPlan' @{Candidates=@($script:C.CandidatesGrid.ItemsSource)}}
On-SCUiClick 'RepeatPermissionButton' {
    $script:C.CandidatesGrid.CommitEdit()|Out-Null;$selected=@($script:C.CandidatesGrid.ItemsSource|Where-Object {$_.Selected})
    if(-not $selected.Count){Show-SCUiError 'Отметьте конкретные категории.'}else{
        $text="Разрешить повторную подготовку утверждённых планов на 30 дней только для этих правил и путей?`n`n"+(@($selected|ForEach-Object {$_.RuleId+': '+$_.Path+"`n"+$_.Consequence}) -join "`n`n")+"`n`nЗапуск остаётся ручным; защита данных и проверки активности продолжают действовать."
        if([Windows.MessageBox]::Show($script:Window,$text,'Повторное разрешение',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question) -eq [Windows.MessageBoxResult]::Yes){Start-SCUiJob 'PermitRepeat' @{Candidates=$selected;Confirmed=$true}}
    }
}
On-SCUiClick 'PurgeButton' {Start-SCUiJob 'PurgePlan' @{}}
On-SCUiClick 'PickOrganizationRoot' {Pick-SCUiFolder 'OrganizationRootBox'}
On-SCUiClick 'PickOrganizationDestination' {Pick-SCUiFolder 'OrganizationDestinationBox'}
On-SCUiClick 'OrganizePlanButton' {Start-SCUiJob 'OrganizePlan' @{Root=$script:C.OrganizationRootBox.Text;Destination=$script:C.OrganizationDestinationBox.Text}}
On-SCUiClick 'RelocatePlanButton' {Start-SCUiJob 'RelocatePlan' @{Root=$script:C.OrganizationRootBox.Text;Destination=$script:C.OrganizationDestinationBox.Text}}
On-SCUiClick 'PolicyLoadButton' {Start-SCUiJob 'Policy' @{}}
On-SCUiClick 'ProtectButton' {Start-SCUiJob 'Protect' @{Path=$script:C.PolicyPathBox.Text;Reason=$script:C.PolicyReasonBox.Text}}
On-SCUiClick 'ExcludeButton' {Start-SCUiJob 'Exclude' @{Path=$script:C.PolicyPathBox.Text;Reason=$script:C.PolicyReasonBox.Text}}
On-SCUiClick 'SavePolicyButton' {try{$value=$script:C.HostPolicyBox.Text|ConvertFrom-Json;Start-SCUiJob 'SavePolicy' @{Policy=$value;ExpectedRevision=$script:LoadedPolicy.Revision}}catch{Show-SCUiError ('Неверный JSON: '+$_.Exception.Message)}}
On-SCUiClick 'HistoryButton' {Start-SCUiJob 'History' @{}}
On-SCUiClick 'LoadPlanButton' {try{Start-SCUiJob 'LoadPlan' @{PlanId=(Get-SCUiPlanSelection)}}catch{Show-SCUiError $_.Exception.Message}}
On-SCUiClick 'EventsButton' {try{Start-SCUiJob 'Events' @{PlanId=(Get-SCUiPlanSelection)}}catch{Show-SCUiError $_.Exception.Message}}
On-SCUiClick 'RestoreButton' {try{Start-SCUiJob 'RestorePlan' @{PlanId=(Get-SCUiPlanSelection)}}catch{Show-SCUiError $_.Exception.Message}}
On-SCUiClick 'ApproveButton' {
    if($script:CurrentPlan){
        $p=$script:CurrentPlan;$preview=@($p.Operations|Select-Object -First 8|ForEach-Object {$_.Action+': '+$_.Source+' → '+$_.Destination}) -join "`n"
        $body='Утвердить только этот план: '+$p.Id+"`n"+$p.OperationCount+' файлов; '+(Format-SCBytes $p.Bytes)+"`nПоказаны первые "+[Math]::Min(8,$p.OperationCount)+" из "+$p.OperationCount+" операций. Полный список доступен постранично.`n`n"+$preview+"`n`n"+($p.Notes -join "`n")
        $partial=$p.SchemaVersion -eq 2 -and $p.Preparation.Limited
        if($partial){$body+="`n`nПлан частичный. Подтверждением вы принимаете ограниченный охват."}
        if($p.Type -eq 'PurgeVault'){$body+="`n`nБЕЗВОЗВРАТНОЕ УДАЛЕНИЕ: восстановление после исполнения невозможно."}
        if([Windows.MessageBox]::Show($script:Window,$body,'Подтверждение конкретного плана',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question) -eq [Windows.MessageBoxResult]::Yes){Start-SCUiJob 'Approve' @{PlanId=$p.Id;Confirmed=$true;AcceptPartial=$partial}}
    }
}
On-SCUiClick 'ExecuteButton' {if($script:CurrentPlan){Start-SCUiJob 'Execute' @{PlanId=$script:CurrentPlan.Id}}}
. (Join-Path $uiRoot 'Workspace.ps1')
. (Join-Path $uiRoot 'Duplicates.ps1')
$script:Timer=New-Object Windows.Threading.DispatcherTimer;$script:Timer.Interval=[TimeSpan]::FromMilliseconds(300)
$script:Timer.Add_Tick({
    if(-not $script:ActiveJob){return}
    try{
        $job=$script:ActiveJob;$seconds=[int]([DateTime]::UtcNow-$job.Started).TotalSeconds
        $progress=Join-Path $job.Directory 'progress.json'
        if(Test-Path -LiteralPath $progress){try{$stage=Get-Content -LiteralPath $progress -Raw -Encoding UTF8|ConvertFrom-Json;$script:C.StatusText.Text=$stage.Stage+' • '+$seconds+' с'+$(if($stage.Total -gt 0){' • '+$stage.Completed+'/'+$stage.Total}else{''})}catch{}}
        if($job.Process.HasExited -and -not $job.Reader){
            $reader=[PowerShell]::Create();[void]$reader.AddScript('param($path) Write-Output -NoEnumerate (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)').AddArgument((Join-Path $job.Directory 'result.json'));$job.Reader=$reader;$job.ReadHandle=$reader.BeginInvoke();return
        }
        if($job.Process.HasExited -and $job.Reader -and $job.ReadHandle.IsCompleted){
            $job.Process.WaitForExit();$job.Process.Dispose();$script:ActiveJob=$null;Set-SCUiBusy $false
            $file=Join-Path $job.Directory 'status.json'
            if(-not(Test-Path -LiteralPath $file)){throw ('Рабочий процесс завершился без результата. Лог: '+$job.Directory)}
            $state=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json
            if($state.State -eq 'Cancelled'){$job.Reader.Dispose();$script:C.StatusText.Text='Операция остановлена по запросу. Состояние сохранено.';Set-SCSectionState $job.Section 'Отменено';return}
            if($state.State -ne 'Completed'){$job.Reader.Dispose();throw $(if($state.State -eq 'Failed'){$state.Message}else{'Рабочий процесс прервался. Журнал: '+$job.Directory})}
            $values=$job.Reader.EndInvoke($job.ReadHandle);try{if($job.Reader.HadErrors){throw ($job.Reader.Streams.Error|Out-String)};$result=$values[0]}finally{$job.Reader.Dispose()}
            $script:C.StatusText.Text='Готово: '+(Get-SCUiText $job.Action)+' • '+$seconds+' с'
            $stateText=if($job.Action -eq 'Scan' -and -not $result.HasIndex){if($result.Status -eq 'cancelled'){'Отменено'}else{'Ошибка'}}elseif((Get-SCField (Get-SCField $result 'Preparation') 'Limited' $false) -or (Get-SCField $result 'Limited' $false)){'Частичный результат'}else{'Обновлено'}
            Set-SCSectionState $job.Section $stateText
            if($job.Action -eq 'Scan' -and $result.HasIndex){Set-SCSectionStale @('Рост','Очистка')}
            if($job.Action -in @('SavePolicy','Protect','Exclude','PermitRepeat')){Set-SCSectionStale @('Очистка','Дубли','Порядок и переносы')}
            if($job.Action -eq 'SaveStorage'){Set-SCSectionStale @('Обзор','Рост','Очистка','Дубли','Порядок и переносы','История')}
            Handle-SCUiResult $job.Action $result
            if(-not $script:ActiveJob){Set-SCUiBusy $false}
            if($SmokeTest -and $job.Action -eq 'Overview'){$script:SmokeDone=$true}
        }
    }catch{$script:ActiveJob=$null;Set-SCUiBusy $false;Set-SCSectionState $job.Section 'Ошибка';Show-SCUiError $_.Exception.Message;if($SmokeTest){$script:Window.Close()}}
})
$script:Window.Add_ContentRendered({$script:Timer.Start();if(Get-SCField $script:Config 'MaintenanceEnabled' $false){Start-SCUiJob 'Maintain' @{Confirmed=$true}}else{Start-SCUiJob 'Overview' @{}}})
$script:Window.Add_Closing({if($script:ActiveJob){[IO.File]::WriteAllText((Join-Path $script:ActiveJob.Directory 'cancel.flag'),'cancel')};$script:Timer.Stop()})
if($SmokeTest){
    $smokeTimer=New-Object Windows.Threading.DispatcherTimer;$smokeTimer.Interval=[TimeSpan]::FromSeconds(1);$smokeStart=[DateTime]::UtcNow
    $smokeTimer.Add_Tick({
        if($script:SmokeDone){
            if($ScreenshotPath){
                $script:Window.UpdateLayout();$visual=$script:Window.Content;$bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$visual.ActualWidth,[int]$visual.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($visual)
                $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Create($ScreenshotPath);try{$encoder.Save($stream)}finally{$stream.Dispose()}
            }
            $smokeTimer.Stop();$script:Window.Close()
        }elseif(([DateTime]::UtcNow-$smokeStart).TotalSeconds -gt 90){$smokeTimer.Stop();$script:Window.Close();throw 'WPF smoke timeout'}
    });$smokeTimer.Start()
}
$script:Window.ShowDialog()|Out-Null
if($SmokeTest -and -not $script:SmokeDone){exit 1}
