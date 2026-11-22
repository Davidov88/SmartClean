function Get-SCReviewRules {
    # Detection-only rules. A match never grants permission to delete.
    @(
        [pscustomobject]@{Id='browser-cache';Title='Кэш браузера';Pattern='\\AppData\\Local\\(?:Google\\Chrome|Microsoft\\Edge)\\User Data\\(?:Default|Profile \d+)\\(?:Cache|Code Cache|GPUCache)$';Consequence='После закрытия браузера кэш обычно восстанавливается. Профиль, пароли и данные сайтов не входят в правило.';Review='Проверить владельца и закрытие браузера; удаления пока нет.'},
        [pscustomobject]@{Id='editor-vsix-cache';Title='Кэш установщиков расширений';Pattern='\\AppData\\(?:Roaming|Local)\\(?:Code|Code - Insiders|Kiro)\\CachedExtensionVSIXs$';Consequence='Повторная установка расширений может потребовать загрузки из сети.';Review='Проверить, что обновление редактора не выполняется.'},
        [pscustomobject]@{Id='pip-cache';Title='Кэш Python/pip';Pattern='\\AppData\\Local\\pip\\Cache$';Consequence='Пакеты потребуется скачать или собрать повторно; установленные среды не входят в правило.';Review='Проверить отсутствие установки пакетов.'},
        [pscustomobject]@{Id='npm-cache';Title='Кэш npm';Pattern='\\AppData\\Local\\npm-cache$';Consequence='Пакеты потребуется скачать повторно; глобальные программы и node_modules не входят в правило.';Review='Предпочтителен штатный механизм npm; проверить отсутствие установки.'},
        [pscustomobject]@{Id='user-temp';Title='Временные файлы пользователя';Pattern='\\AppData\\Local\\Temp$';Consequence='Среди файлов могут быть активные задачи и временные результаты. Весь каталог целиком не удалять.';Review='Требуется отдельное правило возраста, занятости и исключений.'},
        [pscustomobject]@{Id='crash-dumps';Title='Диагностические дампы';Pattern='\\AppData\\Local\\CrashDumps$';Consequence='Удаление лишит возможности разбирать прошлые сбои.';Review='Согласовать, нужны ли дампы для диагностики.'},
        [pscustomobject]@{Id='spotify-data';Title='Данные/кэш Spotify';Pattern='\\AppData\\(?:Local|Roaming)\\Spotify\\Data$';Consequence='Могут потребоваться повторная загрузка музыки и восстановление офлайн-доступа.';Review='Проверить актуальное назначение и согласовать потерю офлайн-копий.'}
    )
}
function Get-SCContentLabel([string]$Path) {
    if($Path -match '^[A-Za-z]:\\(?:Windows(?:\\|$)|\$|(?:pagefile|swapfile|hiberfil)\.sys$)'){return 'Системное: вручную не удалять'}
    if($Path -match '^[A-Za-z]:\\Program Files(?: \(x86\))?(?:\\|$)'){return 'Установленные программы: удаление через деинсталлятор'}
    if($Path -match '\\(?:AppData|ProgramData)(?:\\|$)'){return 'Данные программы: кэш и важные данные пока не разделены'}
    if($Path -match '(?i)\\(?:projects|repos?|\.git)(?:\\|$)'){return 'Проекты и рабочие данные'}
    return 'Пользовательские данные: назначение требует проверки'
}
function Get-SCFocusNodes($Index,[long]$MinimumBytes=268435456,[int]$Limit=25) {
    $frontier=New-Object 'Collections.Generic.List[object]'
    foreach($n in $Index.Children(0,64,'allocated')){if($n.Kind -ne 3 -and $n.AllocatedBytes -ge $MinimumBytes){$frontier.Add([pscustomobject]@{Node=$n;Depth=1;Stopped=$false})}}
    for($step=0;$step -lt 100;$step++){
        $chosen=$null
        foreach($entry in @($frontier|Sort-Object @{Expression={$_.Node.AllocatedBytes};Descending=$true})){
            $n=$entry.Node
            if($entry.Stopped){continue}
            if($n.Kind -ne 1 -or $entry.Depth -ge 9 -or $n.Path -match '^[A-Za-z]:\\Windows(?:\\|$)' -or $n.Path -match '\\(?:Chrome|Edge)\\User Data$'){$entry.Stopped=$true;continue}
            $children=@($Index.Children($n.Id,64,'allocated')|Where-Object {$_.Kind -ne 3 -and $_.AllocatedBytes -ge $MinimumBytes})
            $containers=$n.Path -match '\\(?:Users|AppData|Local|LocalLow|Roaming|projects|repos|repo)$' -or $n.Path -match '^[A-Za-z]:\\Users\\[^\\]+$' -or $n.Path -match '\\AppData\\(?:Local|Roaming)\\(?:Google|Microsoft)$'
            $dominant=$children.Count -eq 1 -and $children[0].AllocatedBytes -ge $n.AllocatedBytes*0.85
            if($children.Count -eq 0 -or (-not $containers -and $entry.Depth -gt 1 -and -not $dominant)){$entry.Stopped=$true;continue}
            # The display limit must not prevent expanding the most important containers.
            if($frontier.Count-1+$children.Count -gt 256){$entry.Stopped=$true;continue}
            $chosen=[pscustomobject]@{Entry=$entry;Children=$children};break
        }
        if(-not $chosen){break}
        [void]$frontier.Remove($chosen.Entry)
        foreach($n in $chosen.Children){$frontier.Add([pscustomobject]@{Node=$n;Depth=($chosen.Entry.Depth+1);Stopped=$false})}
    }
    @($frontier|Sort-Object @{Expression={$_.Node.AllocatedBytes};Descending=$true}|Select-Object -First $Limit|ForEach-Object {
        [pscustomobject]@{Path=$_.Node.Path;AllocatedBytes=$_.Node.AllocatedBytes;LogicalBytes=$_.Node.LogicalBytes;Category=(Get-SCContentLabel $_.Node.Path)}
    })
}
function Get-SCLinkDestinations($LinkNodes,[bool]$SameHost=$true) {
    if(-not ('SmartClean.NativeLinks' -as [type])){Add-Type -Path (Join-Path $script:ProjectRoot 'src\NativeLinks.cs')}
    $checked=[DateTime]::UtcNow.ToString('o')
    foreach($node in $LinkNodes){
        $target=$null;$resolved=$null;$linkType='Ссылка из скана';$status='назначение не определено';$targetVolume=$null;$errorCode=0
        try{
            if(-not $SameHost){throw 'Snapshot belongs to a different computer'}
            $native=[SmartClean.NativeLinks]::Read($node.Path);$errorCode=$native.Error
            if($native.Type){$linkType=$native.Type}
            $target=$native.Target;$resolved=$native.ResolvedTarget
            if($target){$status='назначение прочитано сейчас; содержимое не сканировалось';$targetVolume=[IO.Path]::GetPathRoot($resolved)}
            elseif($errorCode -eq 4390){$status='с момента скана путь перестал быть ссылкой'}
            elseif($errorCode -ne 0){$status='метаданные сейчас недоступны; код Windows '+$errorCode}
        }catch{$status=if($SameHost){'сейчас недоступна или больше не существует'}else{'другой компьютер; текущее назначение здесь не проверяется'}}
        [pscustomobject]@{Path=$node.Path;Type=$linkType;Target=$target;ResolvedTarget=$resolved;TargetVolume=$targetVolume;Status=$status;Win32Error=$errorCode;CheckedUtc=$checked;SnapshotBytesCharged=0}
    }
}
function New-SCAnalysis($Manifest) {
    Test-SCCancel '';Write-SCWorkProgress 'Разбор сохранённого индекса'
    $idx=Open-SCIndex $Manifest
    try{
        $rules=@(Get-SCReviewRules)
        $inspection=$idx.Inspect(30,[string[]]@($rules|ForEach-Object {$_.Pattern}))
        $focus=@(Get-SCFocusNodes $idx)
        $candidates=@($inspection.Candidates|ForEach-Object {
            $rule=$rules[$_.RuleIndex]
            $systemRoot=[Environment]::GetFolderPath([Environment+SpecialFolder]::Windows).TrimEnd('\')+'\'
            if($_.Node.AllocatedBytes -gt 0 -and -not $_.Node.Path.StartsWith($systemRoot,[StringComparison]::OrdinalIgnoreCase)){
                [pscustomobject]@{RuleId=$rule.Id;Title=$rule.Title;Path=$_.Node.Path;ObservedBytes=$_.Node.AllocatedBytes;Consequence=$rule.Consequence;Review=$rule.Review;Approved=$false}
            }
        }|Sort-Object ObservedBytes -Descending)
        [pscustomobject]@{SchemaVersion=1;AnalysisVersion=3;SnapshotId=$Manifest.SnapshotId;Root=$Manifest.Root;ScanFinishedUtc=$Manifest.FinishedUtc;GeneratedUtc=[DateTime]::UtcNow.ToString('o');Coverage=$Manifest.Coverage;Focus=$focus;TopFiles=$inspection.TopFiles;Links=@(Get-SCLinkDestinations $inspection.Links ($Manifest.HostId -eq (Get-SCHostId)));LinkCount=$inspection.LinkCount;CandidateCount=$candidates.Count;Candidates=$candidates;Notes=@('Разбор построен по сохранённому индексу, нового обхода диска нет.','Крупный размер не означает мусор. Перечень фокуса ограничен 25 ветками от 256 MiB; их сумма не равна всему диску.','Назначения ссылок проверены сейчас: это не доказательство их назначения на момент прошлого скана.','Кандидаты не являются разрешением на удаление; оценка объёма не гарантирует освобождение всего размера.')}
    }finally{$idx.Dispose()}
}
function Export-SCAnalysis($Config,$Analysis) {
    $directory=Join-Path $Config.DataRoot ('reports\'+$Analysis.SnapshotId)
    Register-SCStorageWrite $directory
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    Write-SCJson (Join-Path $directory 'analysis.json') $Analysis
    $Analysis.Links|Export-Csv -LiteralPath (Join-Path $directory 'links.csv') -NoTypeInformation -Encoding UTF8
    $text=New-Object Text.StringBuilder
    [void]$text.AppendLine('# Автоматический разбор '+$Analysis.Root)
    [void]$text.AppendLine('')
    [void]$text.AppendLine('Скан: '+$Analysis.ScanFinishedUtc+'; замер '+$Analysis.SnapshotId)
    [void]$text.AppendLine('Скан завершён, но сканер не сообщает все ошибки доступа. Полнота охвата не подтверждена. Результаты сохранены и читаются независимо от меню.')
    [void]$text.AppendLine('')
    [void]$text.AppendLine('## Где сосредоточен объём')
    [void]$text.AppendLine('')
    foreach($n in $Analysis.Focus){[void]$text.AppendLine(('- {0} — {1}. {2}.' -f $n.Path,(Format-SCBytes $n.AllocatedBytes),$n.Category))}
    [void]$text.AppendLine('')
    [void]$text.AppendLine('## Кандидаты на проверку перед очисткой')
    [void]$text.AppendLine('')
    if($Analysis.Candidates.Count -eq 0){[void]$text.AppendLine('Совпадений с текущими узкими правилами не найдено. Это не означает отсутствия кэшей.')}
    foreach($c in $Analysis.Candidates){[void]$text.AppendLine(('- {0}: {1} — {2}. {3} {4}' -f $c.Title,(Format-SCBytes $c.ObservedBytes),$c.Path,$c.Consequence,$c.Review))}
    [void]$text.AppendLine('')
    [void]$text.AppendLine('## Ссылки: путь → назначение')
    [void]$text.AppendLine('')
    foreach($link in $Analysis.Links){[void]$text.AppendLine(('- {0} → {1}. {2}; {3}.' -f $link.Path,$(if($link.Target){$link.Target}else{'не удалось прочитать'}),$link.Type,$link.Status))}
    [void]$text.AppendLine('')
    [void]$text.AppendLine('## Крупные отдельные файлы')
    [void]$text.AppendLine('')
    foreach($file in $Analysis.TopFiles){[void]$text.AppendLine(('- {0} — {1}' -f $file.Path,(Format-SCBytes $file.AllocatedBytes)))}
    [void]$text.AppendLine('')
    foreach($note in $Analysis.Notes){[void]$text.AppendLine('- '+$note)}
    [IO.File]::WriteAllText((Join-Path $directory 'summary.md'),$text.ToString(),$script:Utf8)
    return $directory
}
function Show-SCAnalysis($Config,$Manifest,[switch]$CandidatesOnly,[switch]$Refresh) {
    Write-Host "`nГотовлю автоматический разбор сохранённых данных..." -ForegroundColor Cyan
    $directory=Join-Path $Config.DataRoot ('reports\'+$Manifest.SnapshotId)
    $cache=Join-Path $directory 'analysis.json';$analysis=$null
    if(-not $Refresh -and (Test-Path -LiteralPath $cache)){
        try{$saved=Get-Content -LiteralPath $cache -Raw -Encoding UTF8|ConvertFrom-Json;if($saved.AnalysisVersion -eq 3 -and $saved.SnapshotId -eq $Manifest.SnapshotId){$analysis=$saved}}catch{}
    }
    if(-not $analysis){$analysis=New-SCAnalysis $Manifest;$directory=Export-SCAnalysis $Config $analysis}
    Write-Host ('Замер {0}, {1}. Новый скан не выполнялся.' -f $analysis.SnapshotId,$analysis.Root)
    Write-Host ('Разбор и проверка назначений ссылок: '+$analysis.GeneratedUtc+' UTC')
    if(-not $CandidatesOnly){
        Write-Host "`nГде сосредоточен объём (ветки раскрыты автоматически):" -ForegroundColor Cyan
        foreach($n in @($analysis.Focus|Select-Object -First 12)){Write-Host ('{0,13}  {1}' -f (Format-SCBytes $n.AllocatedBytes),$n.Path);Write-Host ('               '+$n.Category) -ForegroundColor DarkGray}
        if($analysis.Focus.Count -gt 12){Write-Host ('Показаны 12 крупнейших веток; все '+$analysis.Focus.Count+' — в сохранённом отчёте.')}
    }
    Write-Host "`nКандидаты на проверку; удаление не разрешено:" -ForegroundColor Cyan
    foreach($c in @($analysis.Candidates|Select-Object -First 12)){Write-Host ('{0,13}  {1}: {2}' -f (Format-SCBytes $c.ObservedBytes),$c.Title,$c.Path)}
    if($analysis.Candidates.Count -eq 0){Write-Host 'По текущим узким правилам кандидаты не найдены.'}
    Write-Host ("`nСсылок в скане: {0}; назначения прочитаны для {1}. Полная карта в links.csv и summary.md." -f $analysis.LinkCount,@($analysis.Links|Where-Object {$_.Target}).Count)
    foreach($link in @($analysis.Links|Where-Object {$_.TargetVolume -and $_.TargetVolume -ne [IO.Path]::GetPathRoot($_.Path)}|Sort-Object @{Expression={($_.Path -split '\\').Count}},Path|Select-Object -First 8)){Write-Host ($link.Path+' → '+$link.Target)}
    Write-Host ('Отчёт: '+(Join-Path $directory 'summary.md')) -ForegroundColor Green
    Write-Host ('Данные для анализа: '+(Join-Path $directory 'analysis.json'))
    Write-Host 'Результаты сохранены. Список ошибок доступа сканер не предоставляет; полный доступ к каждой папке не подтверждён.' -ForegroundColor Yellow
}
function Show-SCAutoReports($Config,[switch]$CandidatesOnly) {
    $snapshots=@(Get-SCSnapshots $Config|Where-Object {$_.HasIndex})
    if($snapshots.Count -eq 0){Write-Host 'Сначала выполните скан через пункт 1.';return}
    foreach($group in @($snapshots|Group-Object HostId,VolumeId,Root)){
        $latest=@($group.Group|Sort-Object StartedUtc -Descending)[0]
        Show-SCAnalysis $Config $latest -CandidatesOnly:$CandidatesOnly
    }
}
function Show-SCLatestChanges($Config) {
    $snapshots=@(Get-SCSnapshots $Config|Where-Object {$_.HasIndex})
    if($snapshots.Count -eq 0){Write-Host 'Сначала выполните первый скан.';return}
    foreach($group in @($snapshots|Group-Object HostId,VolumeId,Root,EngineVersion,Elevated,Metric,LinkPolicy)){
        $ordered=@($group.Group|Sort-Object StartedUtc -Descending)
        if($ordered.Count -lt 2){Write-Host ($ordered[0].Root+': есть только один замер. Для сравнения выполните новый скан этого же диска через пункт 1.');continue}
        Write-Host ("`n"+$ordered[0].Root+': сравниваю два последних замера.') -ForegroundColor Cyan
        try{Show-SCDiff (Get-SCDiff $ordered[1] $ordered[0])}catch{Write-Host $_.Exception.Message -ForegroundColor Yellow}
    }
}
