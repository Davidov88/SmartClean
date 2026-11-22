$script:DuplicateReferences=@{}
$script:DuplicateGroup=$null
$script:DuplicateGroupsPage=$null
$script:DuplicateCopyPage=0

function Read-SCUiDuplicateRoots {
    $script:C.DuplicateRootsBox.Text -split '[\r\n]+' |
        ForEach-Object {$_.Trim()} | Where-Object {$_}
}
function Set-SCDuplicateResult($Result) {
    Clear-SCDuplicateResult
    $script:DuplicateResult=$Result
    $script:C.DuplicateRootsBox.Text=$Result.Roots -join "`r`n"
    $script:C.DuplicateCrossVolume.IsChecked=$false
    Set-SCDuplicateGroupPage ([pscustomobject]@{Rows=$Result.Groups;Page=0;Count=$Result.GroupCount;CrossVolume=$false})
    $script:C.DuplicatesHint.Text=('Файлов: {0}; групп: {1}; выборок: {2}; полных чтений: {3}; из кэша: {4}; повторных hardlinks: {5}; ошибок: {6}. {7}' -f
        $Result.FilesExamined,$Result.GroupCount,$Result.Sampled,$Result.FilesHashed,$Result.CacheHits,$Result.HardlinksSkipped,$Result.ErrorCount,$Result.Note)
    if($Result.Resumed){$script:C.DuplicatesHint.Text+=' Обход сохранён '+(ConvertTo-SCUtc $Result.CheckpointUtc).ToLocalTime().ToString('dd.MM.yyyy HH:mm')+'.'}
}
function Clear-SCDuplicateResult {
    $script:DuplicateResult=$null;$script:DuplicateGroup=$null;$script:DuplicateGroupsPage=$null
    $script:DuplicateChoices=@{};$script:DuplicateReferences=@{};$script:DuplicateCopyPage=0
    Set-SCGrid 'DuplicateGroupsGrid' @()
    Set-SCGrid 'DuplicatesGrid' @()
    $script:C.DuplicatePageText.Text=''
}
function Set-SCDuplicateGroupPage($Result) {
    $script:DuplicateGroupsPage=$Result
    $script:DuplicateGroup=$null;$script:DuplicateCopyPage=0
    Set-SCGrid 'DuplicatesGrid' @()
    Set-SCGrid 'DuplicateGroupsGrid' @($Result.Rows|ForEach-Object {
        $_|Add-Member NoteProperty DuplicateMiB ([Math]::Round($_.DuplicateBytes/1MB,2)) -Force
        $_
    })
    $script:C.DuplicatePageText.Text='Страница групп '+($Result.Page+1)+' · всего '+$Result.Count
    $script:C.DuplicateGroupsGrid.ToolTip='Оценка повтора — логический объём. Фактически освобождённое место зависит от тома и операции.'
}
function Set-SCDuplicateCopyPage($Result) {
    if(-not $script:DuplicateGroup -or $Result.GroupId -ne $script:DuplicateGroup.GroupId){return}
    $script:DuplicateCopyPage=$Result.Page
    Set-SCGrid 'DuplicatesGrid' @($Result.Rows|ForEach-Object {
        $reference=($script:DuplicateReferences[$_.GroupId] -eq $_.Path)
        $_.Keep=$reference -or -not $script:DuplicateChoices.ContainsKey($_.Path)
        $_|Add-Member NoteProperty MiB ([Math]::Round($_.Bytes/1MB,2)) -Force
        $_|Add-Member NoteProperty ReferenceLabel $(if($reference){'Да'}else{''}) -Force
        $_|Add-Member NoteProperty HashLabel $(if($_.Cached){'Из кэша'}else{'Перечитан'}) -Force
        $_
    })
    $script:C.DuplicatePageText.Text='Группа '+$script:DuplicateGroup.Label+' · '+$script:DuplicateGroup.Copies+' копий · страница '+($Result.Page+1)
}
function Get-SCDuplicateCopyRequest([int]$Page) {
    @{
        RowsFile=$script:DuplicateResult.RowsFile
        GroupId=$script:DuplicateGroup.GroupId
        Offset=$script:DuplicateGroup.Offset
        Page=$Page
    }
}
function Request-SCDuplicateGroupPage([int]$Page) {
    if(-not $script:DuplicateResult){return}
    Save-SCDuplicateChoices
    Start-SCUiJob 'DuplicateGroups' @{
        GroupsFile=$script:DuplicateResult.GroupsFile;Page=$Page
        CrossVolume=[bool]$script:C.DuplicateCrossVolume.IsChecked
    }
}
function Open-SCUiDuplicateGroup {
    if($script:ActiveJob -or -not $script:C.DuplicateGroupsGrid.SelectedItem){return}
    Save-SCDuplicateChoices
    $script:DuplicateGroup=$script:C.DuplicateGroupsGrid.SelectedItem
    Start-SCUiJob 'DuplicateCopies' (Get-SCDuplicateCopyRequest 0)
}
function Update-SCDuplicateControls {
    if($script:ActiveJob){return}
    $script:C.DuplicatePlanButton.IsEnabled=$null -ne $script:DuplicateResult
    $script:C.DuplicateFilterButton.IsEnabled=$null -ne $script:DuplicateResult
    $script:C.DuplicateOpenGroup.IsEnabled=$null -ne $script:C.DuplicateGroupsGrid.SelectedItem
    $script:C.DuplicateGroupBack.IsEnabled=$script:DuplicateGroupsPage -and $script:DuplicateGroupsPage.Page -gt 0
    $script:C.DuplicateGroupNext.IsEnabled=$script:DuplicateGroupsPage -and ($script:DuplicateGroupsPage.Page+1)*50 -lt $script:DuplicateGroupsPage.Count
    $script:C.DuplicateCopyBack.IsEnabled=$script:DuplicateGroup -and $script:DuplicateCopyPage -gt 0
    $script:C.DuplicateCopyNext.IsEnabled=$script:DuplicateGroup -and ($script:DuplicateCopyPage+1)*200 -lt $script:DuplicateGroup.Copies
    $script:C.DuplicateReferenceButton.IsEnabled=$null -ne $script:C.DuplicatesGrid.SelectedItem
    $script:C.DuplicateVolumeProposalButton.IsEnabled=$script:DuplicateGroup -and $script:DuplicateReferences.ContainsKey($script:DuplicateGroup.GroupId) -and $null -ne $script:C.DuplicatesGrid.SelectedItem
    $script:C.DuplicatePreviewButton.IsEnabled=$null -ne $script:C.DuplicatesGrid.SelectedItem
}
function Show-SCDuplicateImage($Result) {
    $bytes=[Convert]::FromBase64String($Result.Jpeg)
    $stream=New-Object IO.MemoryStream(,$bytes)
    try{
        $bitmap=New-Object Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.StreamSource=$stream
        $bitmap.EndInit()
        $bitmap.Freeze()
    }finally{$stream.Dispose()}
    $dialog=New-Object Windows.Window
    $dialog.Owner=$script:Window
    $dialog.Title='Предпросмотр · '+[IO.Path]::GetFileName($Result.Path)
    $dialog.Width=540;$dialog.Height=580;$dialog.WindowStartupLocation='CenterOwner'
    $panel=New-Object Windows.Controls.DockPanel
    $label=New-Object Windows.Controls.TextBlock
    $label.Text=$Result.Path+"`n"+$Result.Width+' × '+$Result.Height
    $label.TextWrapping='Wrap';$label.Margin='12'
    [Windows.Controls.DockPanel]::SetDock($label,'Bottom')
    $null=$panel.Children.Add($label)
    $image=New-Object Windows.Controls.Image
    $image.Source=$bitmap;$image.Stretch='Uniform';$image.Margin='12'
    $null=$panel.Children.Add($image)
    $dialog.Content=$panel
    $null=$dialog.ShowDialog()
}

On-SCUiClick 'PickDuplicateRoot' {Pick-SCUiFolder 'DuplicateRootsBox' -Append}
On-SCUiClick 'DuplicatesButton' {
    $roots=@(Read-SCUiDuplicateRoots)
    if($roots.Count){Start-SCUiJob 'Duplicates' @{Roots=$roots}}
    else{Show-SCUiError 'Добавьте хотя бы одну папку.'}
}
On-SCUiClick 'DuplicateResumeButton' {Start-SCUiJob 'ResumeDuplicates' @{Roots=@(Read-SCUiDuplicateRoots)}}
On-SCUiClick 'DuplicateFilterButton' {Request-SCDuplicateGroupPage 0}
On-SCUiClick 'DuplicateGroupBack' {Request-SCDuplicateGroupPage ($script:DuplicateGroupsPage.Page-1)}
On-SCUiClick 'DuplicateGroupNext' {Request-SCDuplicateGroupPage ($script:DuplicateGroupsPage.Page+1)}
On-SCUiClick 'DuplicateOpenGroup' {Open-SCUiDuplicateGroup}
On-SCUiClick 'DuplicateCopyBack' {Save-SCDuplicateChoices;Start-SCUiJob 'DuplicateCopies' (Get-SCDuplicateCopyRequest ($script:DuplicateCopyPage-1))}
On-SCUiClick 'DuplicateCopyNext' {Save-SCDuplicateChoices;Start-SCUiJob 'DuplicateCopies' (Get-SCDuplicateCopyRequest ($script:DuplicateCopyPage+1))}
On-SCUiClick 'DuplicateReferenceButton' {
    Save-SCDuplicateChoices
    $row=$script:C.DuplicatesGrid.SelectedItem
    if(-not $row){return}
    $script:DuplicateReferences[$row.GroupId]=$row.Path
    $script:DuplicateChoices.Remove($row.Path)
    Set-SCDuplicateCopyPage ([pscustomobject]@{GroupId=$row.GroupId;Page=$script:DuplicateCopyPage;Rows=@($script:C.DuplicatesGrid.ItemsSource)})
}
function Set-SCDuplicateVolumeProposal($Result) {
    if(-not $script:DuplicateGroup -or $script:DuplicateGroup.GroupId -ne $Result.GroupId){return}
    $text='Снять «Оставить» с '+@($Result.Paths).Count+' копий группы на '+$Result.SourceDrive+"?`nПроверенная сохраняемая копия: "+$Result.Reference
    if([Windows.MessageBox]::Show($script:Window,$text,'Предложение для группы',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question) -ne [Windows.MessageBoxResult]::Yes){return}
    foreach($path in $Result.Paths){$script:DuplicateChoices[$path]=$false}
    Set-SCDuplicateCopyPage ([pscustomobject]@{GroupId=$Result.GroupId;Page=$script:DuplicateCopyPage;Rows=@($script:C.DuplicatesGrid.ItemsSource)})
}
On-SCUiClick 'DuplicateVolumeProposalButton' {
    Save-SCDuplicateChoices
    $row=$script:C.DuplicatesGrid.SelectedItem
    if($row -and $script:DuplicateGroup){
        $request=Get-SCDuplicateCopyRequest $script:DuplicateCopyPage
        $request.Path=$row.Path;$request.Reference=$script:DuplicateReferences[$row.GroupId]
        Start-SCUiJob 'DuplicateVolumeProposal' $request
    }
}
On-SCUiClick 'DuplicatePreviewButton' {
    $row=$script:C.DuplicatesGrid.SelectedItem
    if($row){$request=Get-SCDuplicateCopyRequest $script:DuplicateCopyPage;$request.Path=$row.Path;Start-SCUiJob 'DuplicatePreview' $request}
}
On-SCUiClick 'DuplicatePlanButton' {
    Save-SCDuplicateChoices
    if(-not $script:DuplicateChoices.Count){Show-SCUiError 'Снимите «Оставить» с копий, которые хотите включить в план.';return}
    Start-SCUiJob 'DuplicatePlan' @{
        Rows=@();RowsFile=$script:DuplicateResult.RowsFile;Choices=$script:DuplicateChoices;References=$script:DuplicateReferences
    }
}
$script:C.DuplicateGroupsGrid.Add_MouseDoubleClick({Open-SCUiDuplicateGroup})
$script:C.DuplicateGroupsGrid.Add_SelectionChanged({Update-SCDuplicateControls})
$script:C.DuplicatesGrid.Add_BeginningEdit({param($sender,$eventArgs)
    $row=$eventArgs.Row.Item
    if($row -and $script:DuplicateReferences[$row.GroupId] -eq $row.Path){$eventArgs.Cancel=$true}
})
$script:C.DuplicatesGrid.Add_SelectionChanged({Update-SCDuplicateControls})
Update-SCDuplicateControls
