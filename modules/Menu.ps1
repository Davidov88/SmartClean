function Select-SCSnapshot($Config,[string]$Prompt='Выберите замер') {
    $snapshots=@(Get-SCSnapshots $Config)
    if($snapshots.Count -eq 0){Write-Host 'Сохранённых замеров пока нет.';return $null}
    for($i=0;$i -lt $snapshots.Count;$i++){
        $s=$snapshots[$i];$state=if($s.HasIndex){'сохранён'}elseif($s.Status -eq 'cancelled'){'остановлен'}else{$s.Status}
        Write-Host ('{0}. {1} | {2} | {3}' -f ($i+1),$s.SnapshotId,$state,$s.Root)
    }
    $choice=Read-Host ($Prompt+' (0 — назад)');$number=0
    if([int]::TryParse($choice,[ref]$number) -and $number -gt 0 -and $number -le $snapshots.Count){return $snapshots[$number-1]}
    return $null
}
function Show-SCBrowser($Manifest) {
    Show-SCSummary $Manifest
    if(-not $Manifest.HasIndex){return}
    $index=Open-SCIndex $Manifest
    try{
        $current=$index.RootId;$metric='allocated';$page=0
        while($true){
            $node=$index.Get($current)
            Write-Host ("`n"+$node.Path+' | данные из замера '+$Manifest.FinishedUtc) -ForegroundColor Cyan
            Write-Host ('Сумма путей: {0}; без повторов ID: {1}' -f (Format-SCBytes $node.AllocatedBytes),(Format-SCBytes $node.UniqueAllocatedBytes))
            $children=$index.ChildrenPage($current,$page,30,$metric)
            for($i=0;$i -lt $children.Length;$i++){
                $n=$children[$i];$mark=if($n.Kind -eq 1){'[папка]'}elseif($n.Kind -eq 3){'[ссылка, пропуск]'}else{'[файл]'}
                $size=if($metric -eq 'logical'){$n.LogicalBytes}else{$n.AllocatedBytes}
                Write-Host ('{0,2}. {1,13} {2} {3}' -f ($i+1),(Format-SCBytes $size),$mark,(Split-Path $n.Path -Leaf))
            }
            Write-Host ('Показано {0} из {1}. Метрика: {2}.' -f $children.Length,$index.ChildCount($current),$metric)
            Write-Host 'n/b — страницы; номер — раскрыть; .. — выше; t — дерево 3 уровня; m — сменить метрику; p — перейти по пути; 0 — назад.'
            $choice=Read-Host 'Команда';$number=0
            if($choice -eq '0'){break}
            elseif($choice -eq 'n'){$page++}
            elseif($choice -eq 'b'){$page=[Math]::Max(0,$page-1)}
            elseif($choice -eq '..'){if($node.ParentId -ge 0){$current=$node.ParentId;$page=0}}
            elseif($choice -eq 't'){Show-SCTree $index $current 3 8 $metric}
            elseif($choice -eq 'm'){$metric=if($metric -eq 'allocated'){'logical'}else{'allocated'}}
            elseif($choice -eq 'p'){
                $path=Read-Host 'Полный путь или путь относительно текущей ветки'
                if(-not [IO.Path]::IsPathRooted($path)){$path=[IO.Path]::Combine($node.Path+'\',$path)}
                $found=$index.FindDirectory([IO.Path]::GetFullPath($path))
                if($found){$current=$found.Id;$page=0}else{Write-Host 'Такой папки в сохранённом индексе нет.'}
            }
            elseif([int]::TryParse($choice,[ref]$number) -and $number -gt 0 -and $number -le $children.Length){
                $n=$children[$number-1]
                if($n.Kind -eq 1){$current=$n.Id;$page=0}else{Write-Host ($n|Format-List|Out-String)}
            }
        }
    }finally{$index.Dispose()}
}
function Remove-SCSnapshot($Config,$Manifest) {
    Remove-SCOwnArtifact $Config $Manifest.SnapshotDirectory 'snapshot' -Confirmed
}
function Start-SCMenu($Config) {
    if(-not $Config.Configured){
        Write-Host 'SmartClean: первый запуск. Полный скан автоматически не начинается.' -ForegroundColor Cyan
        Show-SCInventory (Get-SCInventory)
        Write-Host ('Результаты по умолчанию: '+$Config.DataRoot)
        $location=Read-Host 'Другой полный путь для результатов или Enter'
        if($location){$Config.DataRoot=[IO.Path]::GetFullPath($location)}
        $Config.Configured=$true;Initialize-SCStore $Config;Save-SCConfig $Config
    }
    while($true){
        Write-Host "`nSmartClean $script:AppVersion | диагностика без удаления пользовательских файлов" -ForegroundColor Cyan
        Write-Host '1. Обзор дисков и новый скан'
        Write-Host '2. Готовый разбор всех дисков: где занято место + отчёты'
        Write-Host '3. Что выросло: последние два замера каждого диска'
        Write-Host '4. Кандидаты на очистку: объяснения, без удаления'
        Write-Host '7. История, место результатов и лимиты'
        Write-Host '8. Ручной просмотр папок (дополнительно)'
        Write-Host '0. Выход'
        $choice=Read-Host 'Выбор'
        Initialize-SCJobContext $Config ''
        try{
            switch($choice){
                '0'{return}
                '1'{
                    Show-SCInventory (Get-SCInventory)
                    $path=Read-Host 'Том или папка для сканирования (например C:\), Enter — назад'
                    if($path){$m=Start-SCScan -Config $Config -Path $path;Show-SCSummary $m;if($m.HasIndex){Show-SCAnalysis $Config $m}}
                }
                '2'{Show-SCAutoReports $Config}
                '3'{Show-SCLatestChanges $Config}
                '4'{Show-SCAutoReports $Config -CandidatesOnly;Write-Host 'Полные последствия и условия каждого кандидата сохранены в summary.md. Ни одно правило пока не разрешает удаление.'}
                '8'{$m=Select-SCSnapshot $Config;if($m){Show-SCBrowser $m}}
                '7'{
                    Write-Host ('Каталог: {0}; занято: {1}; лимиты: {2} замеров / {3} GiB' -f $Config.DataRoot,(Format-SCBytes (Get-SCStorageBytes $Config.DataRoot)),$Config.MaxSnapshots,$Config.MaxStoreGiB)
                    $mode=Read-Host 's — настройки; Enter — список замеров'
                    if($mode -eq 's'){
                        $path=Read-Host 'Новый полный путь хранения или Enter (старые замеры не перемещаются)'
                        if($path){if(-not [IO.Path]::IsPathRooted($path)){throw 'Нужен полный путь.'};$Config.DataRoot=[IO.Path]::GetFullPath($path)}
                        $value=Read-Host ('Лимит замеров, сейчас '+$Config.MaxSnapshots+'; Enter — оставить');$number=0
                        if($value){if(-not [int]::TryParse($value,[ref]$number) -or $number -lt 2 -or $number -gt 1000){throw 'Допустимо 2–1000 замеров.'};$Config.MaxSnapshots=$number}
                        $value=Read-Host ('Лимит хранилища GiB, сейчас '+$Config.MaxStoreGiB+'; Enter — оставить')
                        if($value){if(-not [int]::TryParse($value,[ref]$number) -or $number -lt 1 -or $number -gt 1000){throw 'Допустимо 1–1000 GiB.'};$Config.MaxStoreGiB=$number}
                        Initialize-SCStore $Config;Save-SCConfig $Config
                    }else{
                    $m=Select-SCSnapshot $Config
                    if($m){Show-SCSummary $m;$action=Read-Host 'd — удалить только этот замер SmartClean; Enter — назад';if($action -eq 'd' -and (Read-Host 'Удалить этот сохранённый отчёт? Введите ДА') -eq 'ДА'){Remove-SCSnapshot $Config $m}}
                    }
                }
            }
        }catch{Write-Host ('Ошибка: '+$_.Exception.Message) -ForegroundColor Red}
    }
}
