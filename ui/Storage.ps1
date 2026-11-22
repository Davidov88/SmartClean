function Show-SCStorageDialog($Config,$Inventory=$null,$Owner=$null) {
    [xml]$layout=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="SmartClean — хранилище" Width="820" Height="650" MinWidth="620" MinHeight="480" Background="#F3F5F9" WindowStartupLocation="CenterScreen">
 <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="20">
  <TextBlock Text="Где хранить результаты" FontSize="22" FontWeight="SemiBold"/>
  <TextBlock Text="Замеры и технические результаты сохраняются здесь. Смена пути не перемещает старые данные. Карантин и решения не удаляются обслуживанием." TextWrapping="Wrap" Margin="0,8"/>
  <Label Content="Папка результатов"/><DockPanel><Button Name="Pick" Content="Выбрать…" DockPanel.Dock="Right"/><TextBox Name="Root" Padding="6"/></DockPanel>
  <TextBlock Name="Free" TextWrapping="Wrap" Margin="0,8"/>
  <Label Content="Максимум снимков"/><TextBox Name="Snapshots"/>
  <Label Content="Лимит хранилища, GiB"/><TextBox Name="Limit"/>
  <Label Content="Свободный резерв, MiB (не менее 512)"/><TextBox Name="Reserve"/>
  <CheckBox Name="Maintenance" Content="При запуске обслуживать завершённые технические файлы: старше 30 дней или сверх 100" Margin="0,12"/>
  <TextBlock Text="Предварительный список и объёмы. Активные задания, карантин и журнал решений сохраняются." TextWrapping="Wrap"/>
  <TextBox Name="Details" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" Height="150" VerticalScrollBarVisibility="Auto"/>
  <Label Content="Собственные артефакты — удаление только после подтверждения"/><ListBox Name="Artifacts" Height="100" DisplayMemberPath="Label"/><Button Name="Delete" Content="Удалить выбранный снимок / завершённый артефакт" Padding="8"/>
  <TextBlock Name="Error" TextWrapping="Wrap" Foreground="#A4262C"/>
  <WrapPanel Margin="0,14"><Button Name="Save" Content="Сохранить настройки" Padding="12,8"/><Button Name="Cancel" Content="Отмена" Padding="12,8" Margin="10,0"/></WrapPanel>
 </StackPanel></ScrollViewer>
</Window>
'@
    $dialog=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader($layout)));if($Owner){$dialog.Owner=$Owner}
    $d=@{};foreach($node in $layout.SelectNodes('//*[@Name]')){$d[$node.Name]=$dialog.FindName($node.Name)}
    $proposed=$Config.DataRoot
    if(-not $Config.Configured){
        $system=[IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows'))
        $best=@([IO.DriveInfo]::GetDrives()|Where-Object {$_.IsReady -and $_.DriveType -eq 'Fixed'}|Sort-Object @{Expression={if($_.Name -eq $system){1}else{0}}},@{Expression={$_.AvailableFreeSpace};Descending=$true}|Select-Object -First 1)
        if($best.Count){$proposed=Join-Path $best[0].RootDirectory.FullName ('SmartCleanData\'+$Config.HostId.Substring(0,12))}
    }
    $d.Root.Text=$proposed;$d.Snapshots.Text=[string]$Config.MaxSnapshots;$d.Limit.Text=[string]$Config.MaxStoreGiB;$d.Reserve.Text=[string]$Config.MinimumFreeMiB
    $d.Maintenance.IsChecked=[bool](Get-SCField $Config 'MaintenanceEnabled' $false)
    if($Inventory){$d.Details.Text=(@($Inventory.Inventory.Rows|ForEach-Object {$_.Category+': '+(Format-SCBytes $_.Bytes)})+@($Inventory.Candidates|ForEach-Object {$_.Path+' — '+$_.Reason})+@('Предыдущие хранилища:')+@(Get-SCField $Config 'PreviousDataRoots' @())) -join "`r`n"}
    $artifactRows=New-Object 'Collections.Generic.List[object]'
    if($Inventory){foreach($item in @($Inventory.Candidates)){$artifactRows.Add([pscustomobject]@{Path=$item.Path;Kind=$item.Kind;Label=$item.Path+' — '+$item.Reason})};foreach($item in @($Inventory.Snapshots)){$artifactRows.Add([pscustomobject]@{Path=$item.SnapshotDirectory;Kind='snapshot';Label='Замер '+$item.Root+' '+$item.FinishedUtc})}}
    $d.Artifacts.ItemsSource=$artifactRows.ToArray()
    $d.Delete.Add_Click({$item=$d.Artifacts.SelectedItem;if($item -and [Windows.MessageBox]::Show($dialog,'Удалить только собственный артефакт SmartClean?'+"`n"+$item.Path,'Подтверждение',[Windows.MessageBoxButton]::YesNo) -eq 'Yes'){$dialog.Tag=[pscustomobject]@{Action='RemoveArtifact';Path=$item.Path;Kind=$item.Kind;Confirmed=$true};$dialog.DialogResult=$true;$dialog.Close()}})
    $d.Pick.Add_Click({$picker=New-Object Windows.Forms.FolderBrowserDialog;try{if($picker.ShowDialog() -eq 'OK'){$d.Root.Text=$picker.SelectedPath}}finally{$picker.Dispose()}})
    $d.Root.Add_TextChanged({try{$drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($d.Root.Text));$d.Free.Text='Свободно: '+(Format-SCBytes $drive.AvailableFreeSpace)}catch{$d.Free.Text='Выберите доступный локальный том.'}})
    $d.Cancel.Add_Click({$dialog.DialogResult=$false;$dialog.Close()})
    $d.Save.Add_Click({try{
        if($d.Maintenance.IsChecked -and -not (Get-SCField $Config 'MaintenanceEnabled' $false)){if([Windows.MessageBox]::Show($dialog,'Разрешить при запуске удалять только перечисленные завершённые технические артефакты по указанным правилам? Карантин и решения сохраняются.','Обслуживание',[Windows.MessageBoxButton]::YesNo) -ne 'Yes'){return}}
        if($d.Maintenance.IsChecked -and -not $Inventory){throw 'Для включения обслуживания сначала откройте хранилище из истории и просмотрите предварительный список.'}
        $root=[IO.Path]::GetFullPath($d.Root.Text);$max=[int]$d.Snapshots.Text;$limit=[double]$d.Limit.Text;$reserve=[int]$d.Reserve.Text
        if($max -lt 1 -or $limit -le 0 -or $reserve -lt 512){throw 'Проверьте лимиты.'}
        $dialog.Tag=[pscustomobject]@{Root=$root;MaxSnapshots=$max;MaxStoreGiB=$limit;MinimumFreeMiB=$reserve;MaintenanceEnabled=[bool]$d.Maintenance.IsChecked};$dialog.DialogResult=$true;$dialog.Close()
    }catch{$d.Error.Text=$_.Exception.Message}})
    if($dialog.ShowDialog()){return $dialog.Tag};return $null
}
