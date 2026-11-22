$script:SectionStates=@{}
function Get-SCJobSection([string]$Action) {
    switch -Regex ($Action) {
        '^(Overview|Scan|Analyze|Browse)$' {return 'Обзор'}
        '^Changes$' {return 'Рост'}
        '^(Candidates|CleanupPlan|PurgePlan)$' {return 'Очистка'}
        '^(Duplicates|ResumeDuplicates|DuplicateGroups|DuplicateCopies|DuplicatePreview|DuplicateVolumeProposal|DuplicatePlan)$' {return 'Дубли'}
        '^(OrganizePlan|RelocatePlan)$' {return 'Порядок и переносы'}
        '^(Policy|SavePolicy|Protect|Exclude|PermitRepeat)$' {return 'Правила'}
        '^(History|Events|EventDetail|RestorePlan|Recovery|RecoveryPlan|Storage|SaveStorage|Maintain|RemoveArtifact)$' {return 'История'}
        default {return [string]$script:C.Tabs.SelectedItem.Header}
    }
}
function Update-SCSectionState {
    $section=[string]$script:C.Tabs.SelectedItem.Header
    if($script:SectionStates.ContainsKey($section)){$script:C.ResultStateText.Text=$section+' · '+$script:SectionStates[$section].Text}
    else{$script:C.ResultStateText.Text=$section+' · Ещё не запускалось. Выберите действие в разделе.'}
}
function Set-SCSectionState([string]$Section,[string]$State) {
    if(-not $Section){return}
    $script:SectionStates[$Section]=[pscustomobject]@{Text=$State+' · '+[DateTime]::Now.ToString('dd.MM HH:mm');State=$State}
    Update-SCSectionState
}
function Set-SCSectionStale([string[]]$Sections) {
    foreach($section in $Sections){if($script:SectionStates.ContainsKey($section)){Set-SCSectionState $section 'Данные могли устареть. Обновите результат'}}
}
$script:C.Tabs.Add_SelectionChanged({param($sender,$eventArgs) if($eventArgs.Source -eq $sender){Update-SCSectionState}})
$script:PageNumbers=@{'Дубли'=0;'Рост'=0;'Ветка'=0;'План'=0;'Предупреждения'=0;'Диагностика'=0;'История'=0;'Планы истории'=0}
$script:DuplicateChoices=@{};$script:DuplicateResult=$null;$script:GrowthResult=$null;$script:BrowseResult=$null;$script:RuleDraft=$null;$script:RuleField=''
$script:UiNames=@{
    Overview='Обзор';Scan='Сканирование';Analyze='Разбор замера';Changes='Рост';Candidates='Поиск кандидатов';Duplicates='Поиск дублей';ResumeDuplicates='Продолжение сравнения';DuplicateGroups='Страница групп';DuplicateCopies='Копии группы';DuplicatePreview='Предпросмотр фото';DuplicateVolumeProposal='Проверка копии на другом томе';Browse='Сохранённая ветка';RowsPage='Страница результата';PlanPage='Страница плана';Diagnostics='Причины пропусков';
    Cleanup='Очистка';CleanupPlan='Подготовка очистки';DuplicatePlan='План дублей';Organize='Организация';OrganizePlan='План организации';Relocate='Перенос';RelocatePlan='План переноса';Restore='Восстановление';RestorePlan='План восстановления';Recovery='Незавершённые фазы';RecoveryPlan='План восстановления фаз';PurgeVault='Безвозвратное удаление карантина';PurgePlan='План удаления карантина';
    History='История';LoadPlan='Открытие плана';Approve='Утверждение';Execute='Исполнение';Events='Журнал';Policy='Правила';SavePolicy='Сохранение правил';Protect='Защита';Exclude='Исключение сканирования';PermitRepeat='Повторное разрешение';Storage='Хранилище';SaveStorage='Настройка хранилища';Maintain='Обслуживание собственных файлов';RemoveArtifact='Удаление собственного артефакта';
    Proposed='Предложен';Approved='Утверждён';InProgress='Выполняется';Verified='Проверен исполнителем';Failed='Ошибка';Cancelled='Отменён';PartiallyCompleted='Частично выполнен';Imported='Импортированная история';HistoricalImport='Исторические наблюдения';
    'observed-both'='Наблюдается в обоих';'newly-observed'='Впервые наблюдается';'not-observed-now'='Не наблюдается сейчас';Phase='Фаза операции';OperationVerified='Файл проверен';OperationFailed='Ошибка файла';Finished='Итог';Started='Начало';Created='Создание';Approval='Согласование';Prepared='Источник проверен';CopyWritten='Копия записана';CopyVerified='Копия сверена';PublishIntent='Записано намерение публикации';DestinationPublished='Копия опубликована';SourceDeleteAuthorized='Удаление источника разрешено';SourceRemoved='Источник удалён';PurgeIntent='Записано намерение удаления из карантина';RecoveryResolved='Восстановление завершено';RecoveryLink='Связь с исходным планом';MoveFile='Перенос файла';QuarantineFile='Перенос в карантин';PurgeFile='Удаление из карантина';CompletePublishedMove='Завершение переноса'
}
function Get-SCUiText([string]$Code){if($script:UiNames.ContainsKey($Code)){return $script:UiNames[$Code]};return $Code}
function Set-SCGrowthRows($Rows){
    Set-SCGrid 'ChangesGrid' @($Rows|ForEach-Object {[pscustomobject]@{Path=$_.Path;ParentPath=$_.ParentPath;Observation=(Get-SCUiText $_.Observation);BeforeMiB=$(if($null -eq $_.BeforeBytes){'?'}else{[Math]::Round($_.BeforeBytes/1MB,2)});AfterMiB=$(if($null -eq $_.AfterBytes){'?'}else{[Math]::Round($_.AfterBytes/1MB,2)});DeltaMiB=$(if($null -eq $_.AllocatedDelta){'?'}else{[Math]::Round($_.AllocatedDelta/1MB,2)})}})
    $view=[Windows.Data.CollectionViewSource]::GetDefaultView($script:C.ChangesGrid.ItemsSource);$view.GroupDescriptions.Clear();$view.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription('ParentPath')))
}
function Save-SCDuplicateChoices {
    $script:C.DuplicatesGrid.CommitEdit()|Out-Null
    foreach($row in @($script:C.DuplicatesGrid.ItemsSource)){if(-not $row.Keep){$script:DuplicateChoices[$row.Path]=$false}else{$script:DuplicateChoices.Remove($row.Path)}}
}
function Set-SCBrowseResult($Result){
    $script:BrowseResult=$Result;$script:PageNumbers['Ветка']=$Result.Page
    Set-SCGrid 'BrowseGrid' @($Result.Rows|ForEach-Object {$_|Add-Member NoteProperty GiB ([Math]::Round($(if($Result.Metric -eq 'logical'){$_.LogicalBytes}else{$_.AllocatedBytes})/1GB,2)) -Force;$_})
    $script:C.BrowsePath.Text=$Result.Path
    $script:C.BrowseBreadcrumbs.Children.Clear()
    foreach($crumb in $Result.Breadcrumbs){
        $button=New-Object Windows.Controls.Button
        $button.Content=$crumb.Label;$button.Tag=$crumb.Path
        $button.ToolTip=$crumb.Path
        $button.Add_Click({param($sender,$eventArgs)
            if(-not $script:ActiveJob){Open-SCBrowse ([string]$sender.Tag) $script:BrowseResult.SnapshotId}
        })
        $null=$script:C.BrowseBreadcrumbs.Children.Add($button)
    }
    $m=$Result.Manifest;$script:C.CoverageText.Text='Замер '+$m.FinishedUtc+'; охват: '+$m.Coverage+' (не подтверждён); права администратора: '+$m.Elevated+'; исключения: '+($m.ExcludedRoots -join '; ')
    $script:C.PageLabel.Text='Ветка: страница '+($Result.Page+1)+'; объектов '+$Result.Count
}
function Set-SCPagedResult($Result){
    if($Result.Kind -eq 'История'){Set-SCHistoryEvents $Result;return}
    switch($Result.Kind){
        'Рост'{Set-SCGrowthRows $Result.Rows}
        'План'{Set-SCGrid 'PlanGrid' @($Result.Rows|ForEach-Object {$_|Add-Member NoteProperty ActionLabel (Get-SCUiText $_.Action) -Force;$_|Add-Member NoteProperty MiB ([Math]::Round($_.Bytes/1MB,2)) -Force;$_})}
        'Warnings'{Set-SCGrid 'WarningsGrid' @($Result.Rows|ForEach-Object {[pscustomobject]@{Reason=[string]$_}})}
        'Diagnostics'{Set-SCGrid 'WarningsGrid' @($Result.Rows|ForEach-Object {[pscustomobject]@{Reason=$_.Reason}})}
    }
    $script:C.PageLabel.Text='Страница '+($Result.Page+1)+'; показано '+@($Result.Rows).Count+' строк (до 200)'
}
function Move-SCUiPage([int]$Delta){
    $kind=[string]$script:C.PageKindPicker.SelectedItem.Content;$page=[Math]::Max(0,[int]$script:PageNumbers[$kind]+$Delta)
    switch($kind){
        'Рост'{if(-not $script:GrowthResult){return};if($page*200 -ge $script:GrowthResult.RowCount -and $page -gt 0){return};Start-SCUiJob 'RowsPage' @{Path=$script:GrowthResult.RowsFile;Page=$page;Kind=$kind;Scope=$(if($script:C.GrowthScope.Text -eq 'Все ветки') {''}else{$script:C.GrowthScope.Text})}}
        'Ветка'{if(-not $script:BrowseResult){return};if($page*200 -ge $script:BrowseResult.Count -and $page -gt 0){return};Start-SCUiJob 'Browse' @{SnapshotId=$script:BrowseResult.SnapshotId;Path=$script:BrowseResult.Path;Metric=$script:BrowseResult.Metric;Page=$page}}
        'Планы истории'{if($script:PlanHistory -and ($page -eq 0 -or $page*200 -lt $script:PlanHistory.Count)){Start-SCUiJob 'History' @{Page=$page}}}
        'История'{if($script:HistoryResult){Start-SCUiJob 'Events' @{PlanId=$script:HistoryResult.PlanId;Page=$page}}}
        'План'{if($script:CurrentPlan){Start-SCUiJob 'PlanPage' @{PlanId=$script:CurrentPlan.Id;Kind='План';Page=$page}}}
        'Предупреждения'{if($script:CurrentPlan){Start-SCUiJob 'PlanPage' @{PlanId=$script:CurrentPlan.Id;Kind='Warnings';Page=$page}}}
        'Диагностика'{if($script:CurrentPlan){Start-SCUiJob 'Diagnostics' @{PlanId=$script:CurrentPlan.Id;Page=$page}}}
    }
    $script:PageNumbers[$kind]=$page
}
function Open-SCBrowse([string]$Path='',[string]$SnapshotId=''){
    $script:C.BrowseTab.IsSelected=$true
    $m=$script:C.SnapshotPicker.SelectedItem;if(-not $SnapshotId -and $m){$SnapshotId=$m.SnapshotId};if(-not $SnapshotId){Show-SCUiError 'Выберите замер.';return}
    $metric=if($script:C.BrowseMetric.SelectedIndex -eq 1){'logical'}else{'allocated'}
    Start-SCUiJob 'Browse' @{SnapshotId=$SnapshotId;Path=$Path;Metric=$metric;Page=0}
}
function Save-SCRuleDraft {
    if(-not $script:RuleDraft -or -not $script:RuleField){return}
    $script:C.EditableRulesGrid.CommitEdit()|Out-Null
    $rows=@($script:C.EditableRulesGrid.ItemsSource)
    if($script:RuleField -eq 'OrganizationRules'){$rows=@($rows|ForEach-Object {[pscustomobject]@{Category=$_.Category;Extensions=@($_.Extensions -split '[,;\s]+'|Where-Object {$_})}})}
    $script:RuleDraft.($script:RuleField)=$rows
}
function Set-SCRuleForm {
    $script:RuleDraft=$script:LoadedPolicy.Host|ConvertTo-Json -Depth 24|ConvertFrom-Json
    $script:RuleField='';Show-SCRuleKind
}
function Show-SCRuleKind {
    Save-SCRuleDraft
    $script:RuleField=[string]$script:C.RuleKindPicker.SelectedItem.Tag
    $rows=@($script:RuleDraft.($script:RuleField))
    if($script:RuleField -eq 'OrganizationRules'){$rows=@($rows|ForEach-Object {[pscustomobject]@{Category=$_.Category;Extensions=($_.Extensions -join ', ')}})}
    $items=New-Object 'Collections.ObjectModel.ObservableCollection[object]';foreach($row in $rows){$items.Add($row)}
    $script:C.EditableRulesGrid.ItemsSource=$items
    $script:C.EditableRulesGrid.IsReadOnly=$script:RuleField -eq 'CleanupPermissions'
    $script:C.RuleAddButton.IsEnabled=$script:RuleField -ne 'CleanupPermissions'
}
On-SCUiClick 'PagePreviousButton' {Move-SCUiPage -1}
On-SCUiClick 'PageNextButton' {Move-SCUiPage 1}
On-SCUiClick 'BrowseSelectedButton' {Open-SCBrowse}
On-SCUiClick 'BrowseUpButton' {if($script:BrowseResult){Open-SCBrowse $script:BrowseResult.ParentPath $script:BrowseResult.SnapshotId}}
On-SCUiClick 'RefreshBranchButton' {if($script:BrowseResult){Start-SCUiJob 'Scan' @{Path=$(if($script:BrowseResult.Path -match '^[A-Za-z]:$'){$script:BrowseResult.Path+'\'}else{$script:BrowseResult.Path})}}}
$script:C.BrowseGrid.Add_MouseDoubleClick({$row=$script:C.BrowseGrid.SelectedItem;if($row -and $row.Kind -eq 1){Open-SCBrowse $row.Path $script:BrowseResult.SnapshotId}})
$script:C.FocusGrid.Add_MouseDoubleClick({$row=$script:C.FocusGrid.SelectedItem;if($row){$m=@($script:Snapshots|Where-Object {$_.SnapshotId -eq $row.SnapshotId});if($m.Count){$script:C.SnapshotPicker.SelectedItem=$m[0]};Open-SCBrowse $row.Path}})
$script:C.BrowseMetric.Add_SelectionChanged({if($script:BrowseResult -and -not $script:ActiveJob){Open-SCBrowse $script:BrowseResult.Path $script:BrowseResult.SnapshotId}})
On-SCUiClick 'RecoveryInspectButton' {try{Start-SCUiJob 'Recovery' @{PlanId=(Get-SCUiPlanSelection)}}catch{Show-SCUiError $_.Exception.Message}}
On-SCUiClick 'RecoveryFinishButton' {try{Start-SCUiJob 'RecoveryPlan' @{PlanId=(Get-SCUiPlanSelection);Mode='Finish'}}catch{Show-SCUiError $_.Exception.Message}}
On-SCUiClick 'RecoveryCopyButton' {try{Start-SCUiJob 'RecoveryPlan' @{PlanId=(Get-SCUiPlanSelection);Mode='QuarantineCopy'}}catch{Show-SCUiError $_.Exception.Message}}
On-SCUiClick 'StorageButton' {Start-SCUiJob 'Storage' @{}}
On-SCUiClick 'DetailsButton' {
    if($script:SelectedDetails){$script:C.SelectionDetails.Text=$script:SelectedDetails;$script:C.PlanExpander.IsExpanded=$true;[Windows.Clipboard]::SetText($script:SelectedDetails)}
}
foreach($name in @('FocusGrid','BrowseGrid','ChangesGrid','CandidatesGrid','DuplicatesGrid','DuplicateGroupsGrid','HistoryGrid','PlanGrid','WarningsGrid')){
    $script:C[$name].Add_SelectionChanged({param($sender,$eventArgs)
        if($sender.SelectedItem){$script:SelectedDetails=$sender.SelectedItem|ConvertTo-Json -Depth 12;$script:C.SelectionDetails.Text=$script:SelectedDetails}
    })
}
$script:C.RuleKindPicker.Add_SelectionChanged({if($script:RuleDraft){Show-SCRuleKind}})
On-SCUiClick 'RuleAddButton' {
    $row=switch($script:RuleField){'ProtectedPaths'{[pscustomobject]@{Path='';Scope='Tree';Reason=''}}'ScanExclusions'{[pscustomobject]@{Path='';Reason=''}}'OrganizationRules'{[pscustomobject]@{Category='';Extensions=''}}default{$null}}
    if($row){$script:C.EditableRulesGrid.ItemsSource.Add($row)}
}
On-SCUiClick 'RuleRemoveButton' {if($script:C.EditableRulesGrid.SelectedItem){$script:C.EditableRulesGrid.ItemsSource.Remove($script:C.EditableRulesGrid.SelectedItem)}}
On-SCUiClick 'RuleSaveButton' {Save-SCRuleDraft;Start-SCUiJob 'SavePolicy' @{Policy=$script:RuleDraft;ExpectedRevision=$script:LoadedPolicy.Revision}}
# Static labels and accessible names remain available even before any result exists.
foreach($name in $script:C.Keys){
    $control=$script:C[$name]
    if($control -is [Windows.FrameworkElement]){
        $label=if($control -is [Windows.Controls.Button]){[string]$control.Content}else{$name}
        [Windows.Automation.AutomationProperties]::SetName($control,$label)
        if($control -is [Windows.Controls.DataGrid]){$control.ToolTip='Ещё не загружено. Выберите соответствующую команду.'}
    }
}
$script:Window.Width=[Math]::Min(1320,[Windows.SystemParameters]::WorkArea.Width)
$script:Window.Height=[Math]::Min(900,[Windows.SystemParameters]::WorkArea.Height)
$script:Window.MinWidth=[Math]::Min(760,[Windows.SystemParameters]::WorkArea.Width)
$script:Window.MinHeight=[Math]::Min(540,[Windows.SystemParameters]::WorkArea.Height)
Set-SCRuleForm

# Each grid has its own visible empty-state text, rather than relying only on a status bar.
$script:EmptyLabels=@{}
foreach($name in @('FocusGrid','BrowseGrid','ChangesGrid','CandidatesGrid','DuplicatesGrid','DuplicateGroupsGrid','HistoryGrid','PlanGrid','WarningsGrid')){
    $grid=$script:C[$name];$parent=$grid.Parent;$row=[Windows.Controls.Grid]::GetRow($grid);$column=[Windows.Controls.Grid]::GetColumn($grid)
    $wrapper=New-Object Windows.Controls.Grid;$wrapper.Background=[Windows.Media.Brushes]::White
    if($parent -is [Windows.Controls.Panel]){$index=$parent.Children.IndexOf($grid);$parent.Children.Remove($grid);$parent.Children.Insert($index,$wrapper)}
    elseif($parent -is [Windows.Controls.ContentControl]){$parent.Content=$null;$parent.Content=$wrapper}else{continue}
    [Windows.Controls.Grid]::SetRow($wrapper,$row);[Windows.Controls.Grid]::SetColumn($wrapper,$column)
    $wrapper.Children.Add($grid)|Out-Null;[Windows.Controls.Grid]::SetRow($grid,0);[Windows.Controls.Grid]::SetColumn($grid,0)
    $empty=New-Object Windows.Controls.TextBlock;$empty.Text='Ещё не загружено. Выберите соответствующую команду.';$empty.TextWrapping='Wrap';$empty.HorizontalAlignment='Center';$empty.VerticalAlignment='Center';$empty.Margin='24';$empty.IsHitTestVisible=$false;$wrapper.Children.Add($empty)|Out-Null;$script:EmptyLabels[$name]=$empty
}
$script:C.EditableRulesGrid.Add_AutoGeneratingColumn({param($sender,$eventArgs)
    $names=@{Path='Путь';Scope='Область (Tree/Exact)';Reason='Причина';Category='Категория';Extensions='Расширения через запятую';RuleId='Правило';RuleVersion='Версия';GrantedUtc='Выдано, UTC';ExpiresUtc='Действует до, UTC';Repeat='Повтор';Source='Источник';Consequence='Последствия'}
    if($names.ContainsKey($eventArgs.PropertyName)){$eventArgs.Column.Header=$names[$eventArgs.PropertyName]}
})
$labels=@{ScanRootBox='Путь нового сканирования';OrganizationRootBox='Откуда переносить';OrganizationDestinationBox='Куда переносить';DuplicateRootsBox='Папки поиска дублей, одна на строку';PolicyPathBox='Защищаемый или исключаемый путь';PolicyReasonBox='Причина правила';BrowsePath='Путь в сохранённом замере';SnapshotPicker='Сохранённый замер';BeforePicker='Старый замер';AfterPicker='Новый замер';BrowseMetric='Метрика размера';RuleKindPicker='Вид правил';PageKindPicker='Раздел постраничного просмотра'}
foreach($key in $labels.Keys){[Windows.Automation.AutomationProperties]::SetName($script:C[$key],$labels[$key])}
$script:C.RefreshButton.Content='_Обновить обзор';$script:C.CancelButton.Content='О_становить';$script:C.AnalyzeButton.Content='_Разобрать замер'

On-SCUiClick 'GrowthUpButton' {if($script:GrowthResult){$script:C.GrowthScope.Text='Все ветки';Start-SCUiJob 'RowsPage' @{Path=$script:GrowthResult.RowsFile;Page=0;Kind='Рост'}}}
$script:C.ChangesGrid.Add_MouseDoubleClick({$row=$script:C.ChangesGrid.SelectedItem;if($row -and $script:GrowthResult){$script:C.GrowthScope.Text=$row.Path;Start-SCUiJob 'RowsPage' @{Path=$script:GrowthResult.RowsFile;Page=0;Kind='Рост';Scope=$row.Path}}})

$script:HistoryResult=$null;$script:PlanHistory=$null
function Set-SCHistoryEvents($Result){
    $script:HistoryResult=$Result
    Set-SCGrid 'HistoryEventsGrid' @($Result.Rows|ForEach-Object {$_|Add-Member NoteProperty KindLabel (Get-SCUiText $_.Kind) -Force;$_|Add-Member NoteProperty StatusLabel (Get-SCUiText $_.Status) -Force;if(-not $_.Reason){$_.Reason=Get-SCUiText $_.Phase};$_})
    $summary=New-Object 'Collections.Generic.List[string]'
    foreach($row in $Result.Rows){if(@($row.After).Count){foreach($after in $row.After){$before=@($row.Before|Where-Object {$_.Root -eq $after.Root}|Select-Object -First 1);if($before.Count){$delta=[long]$after.FreeBytes-[long]$before[0].FreeBytes;$summary.Add($after.Root+' изменение свободного места: '+$delta+' байт (наблюдение при работающих программах)')}}};if($row.Kind -eq 'Finished'){$summary.Add((Get-SCUiText $row.Status)+'; выполнено '+$row.Completed+' из '+$row.Total)}}
    $script:C.HistoryDetailsBox.Text=$summary -join "`r`n"
    $script:C.PageLabel.Text='История: страница '+($Result.Page+1)+'; событий '+$Result.Count
}
On-SCUiClick 'EventDetailButton' {if($script:HistoryResult -and $script:C.HistoryEventsGrid.SelectedItem){Start-SCUiJob 'EventDetail' @{PlanId=$script:HistoryResult.PlanId;EventId=$script:C.HistoryEventsGrid.SelectedItem.EventId}}}


foreach($scope in @('OverviewTab','GrowthTab','CleanupTab','DuplicatesTab','OrganizeTab','RulesTab','HistoryTab')){
    [Windows.Input.KeyboardNavigation]::SetTabNavigation($script:C[$scope],[Windows.Input.KeyboardNavigationMode]::Local)
}
$orders=@(
    'ScanRootBox PickScanRoot ScanButton FocusGrid BrowseSelectedButton BrowseUpButton RefreshBranchButton BrowseMetric BrowsePath BrowseGrid'
    'BeforePicker AfterPicker CompareButton GrowthUpButton ChangesGrid'
    'CandidatesButton CandidatesGrid CleanupPlanButton RepeatPermissionButton PurgeButton'
    'DuplicateRootsBox PickDuplicateRoot DuplicatesButton DuplicateResumeButton DuplicateCrossVolume DuplicateFilterButton DuplicateGroupsGrid DuplicateGroupBack DuplicateGroupNext DuplicateOpenGroup DuplicatesGrid DuplicateCopyBack DuplicateCopyNext DuplicateReferenceButton DuplicateVolumeProposalButton DuplicatePreviewButton DuplicatePlanButton'
    'OrganizationRootBox PickOrganizationRoot OrganizationDestinationBox PickOrganizationDestination OrganizePlanButton RelocatePlanButton'
    'PolicyLoadButton PolicyPathBox PolicyReasonBox ProtectButton ExcludeButton RuleKindPicker EditableRulesGrid RuleAddButton RuleRemoveButton RuleSaveButton ProtectionGrid HostPolicyBox SavePolicyButton'
    'HistoryButton HistoryGrid LoadPlanButton EventsButton HistoryEventsGrid EventDetailButton HistoryDetailsBox RestoreButton RecoveryInspectButton RecoveryFinishButton RecoveryCopyButton StorageButton'
)
foreach($order in $orders){
    $i=0
    foreach($name in $order.Split(' ')){if($script:C[$name] -is [Windows.Controls.Control]){$script:C[$name].TabIndex=$i;$i++}}
}
Update-SCSectionState
