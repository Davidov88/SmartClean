function Show-SCSummary($Manifest) {
    $state=if($Manifest.HasIndex){'результат сохранён'}elseif($Manifest.Status -eq 'cancelled'){'остановлено, готового дерева нет'}elseif($Manifest.Status -eq 'failed'){'ошибка'}else{'выполняется'}
    Write-Host ("`nЗамер: {0} | {1}" -f $Manifest.SnapshotId,$state) -ForegroundColor Cyan
    Write-Host ('Область: '+$Manifest.Root)
    Write-Host ('Интервал UTC: '+$Manifest.StartedUtc+' — '+$Manifest.FinishedUtc)
    if($Manifest.HasIndex){
        Write-Host ('Файлы: {0:N0} | каталоги: {1:N0} | исключённые ссылки: {2}' -f $Manifest.Totals.Files,$Manifest.Totals.Directories,$Manifest.Totals.Links)
        Write-Host ('Логический размер: '+(Format-SCBytes $Manifest.Totals.LogicalBytes))
        Write-Host ('Занято файлами, с учётом каждого пути: '+(Format-SCBytes $Manifest.Totals.AllocatedBytes))
        Write-Host ('После исключения повторов жёстких ссылок: '+(Format-SCBytes $Manifest.Totals.UniqueAllocatedBytes))
        Write-Host ('Дополнительных имён тех же файлов (hardlinks): '+$Manifest.Totals.HardlinkDuplicates)
    }
    if($Manifest.Failure){Write-Host $Manifest.Failure -ForegroundColor Red}
    if($Manifest.HasIndex){Write-Host 'Сканирование завершено. Подробного списка ошибок доступа у сканера нет: доступ к каждой папке не подтверждён. Это не ошибка сохранения результатов.' -ForegroundColor Yellow}
    elseif($Manifest.Warnings){foreach($warning in $Manifest.Warnings){Write-Host ('  ! '+$warning) -ForegroundColor Yellow}}
    Write-Host ('Результаты: '+$Manifest.SnapshotDirectory)
}
function Show-SCTree($Index,[long]$NodeId=0,[int]$Depth=3,[int]$Top=8,[string]$Metric='allocated') {
    $budget=150
    Write-Host ('Обзор: '+$Index.Get($NodeId).Path)
    Write-SCTreeBranch $Index $NodeId 0 $Depth $Top $Metric ([ref]$budget)
    if($budget -le 0){Write-Host 'Достигнут лимит 150 строк обзора. Углубитесь в нужную ветку.'}
}
function Write-SCTreeBranch($Index,[long]$id,[int]$level,[int]$Depth,[int]$Top,[string]$Metric,[ref]$Budget) {
        foreach($n in $Index.Children($id,$Top,$Metric)){
            if($Budget.Value -le 0){break};$Budget.Value--
            $name=Split-Path $n.Path -Leaf
            $mark=if($n.Kind -eq 1){'[+]'}elseif($n.Kind -eq 3){'[@]'}else{'   '}
            $size=if($Metric -eq 'logical'){$n.LogicalBytes}else{$n.AllocatedBytes}
            Write-Host ('{0}{1} {2,13}  {3}' -f ('  '*$level),$mark,(Format-SCBytes $size),$name)
            if($n.Kind -eq 1 -and $level+1 -lt $Depth){Write-SCTreeBranch $Index $n.Id ($level+1) $Depth $Top $Metric $Budget}
        }
        if($Index.ChildCount($id) -gt $Top){Write-Host ('{0}… показано {1} из {2} элементов в {3}' -f ('  '*$level),$Top,$Index.ChildCount($id),$Index.Get($id).Path) -ForegroundColor DarkGray}
}
function Get-SCDiff($Before,$After) {
    foreach($key in @('SchemaVersion','HostId','Root','VolumeId','Elevated','Engine','EngineVersion','Metric','LinkPolicy')){
        if([string]$Before.$key -ne [string]$After.$key){throw "Замеры несовместимы: $key"}
    }
    if(-not $Before.VolumeId){throw 'Нет стабильного идентификатора тома: автоматическое сравнение запрещено.'}
    if([DateTime]::Parse($Before.StartedUtc) -gt [DateTime]::Parse($After.StartedUtc)){throw 'Новый замер сделан раньше старого. Поменяйте их местами.'}
    if(($Before.ExcludedRoots -join '|') -ne ($After.ExcludedRoots -join '|')){throw 'Различаются исключения сканирования.'}
    $a=Open-SCIndex $Before;$b=Open-SCIndex $After
    try{
        Import-SCDiskData
        $config=if(Get-Variable SCJobContext -Scope Script -ErrorAction SilentlyContinue){$script:SCJobContext.Config}else{Get-SCConfig}
        $workspace=New-SCWorkspace $config
        $files=@()
        foreach($index in @($a,$b)){
            $number=$files.Count;$raw=Join-Path $workspace ("dirs-$number.txt");$sorted=Join-Path $workspace ("dirs-$number-sorted.txt")
            $w=New-Object IO.StreamWriter($raw,$false,$script:Utf8)
            try{foreach($n in $index.EnumerateDirectories()){
                Test-SCCancel '';Write-SCWorkProgress 'Сопоставление каталогов'
                $key=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($n.Path.ToUpperInvariant()));$path=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($n.Path))
                $w.WriteLine($key+"`t"+$path+"`t"+$n.LogicalBytes+"`t"+$n.AllocatedBytes)
            }}finally{$w.Dispose()}
            [SmartClean.DiskData]::Sort($raw,$sorted,(Join-Path $workspace ("sort-$number")));$files+=@($sorted)
        }
        $left=New-Object IO.StreamReader($files[0]);$right=New-Object IO.StreamReader($files[1]);$raw=Join-Path $workspace 'changes.txt';$sorted=Join-Path $workspace 'changes-sorted.txt';$out=New-Object IO.StreamWriter($raw,$false,$script:Utf8);$count=0L
        try{
            $x=$left.ReadLine();$y=$right.ReadLine()
            while($null -ne $x -or $null -ne $y){
                Test-SCCancel '';$xp=if($null -ne $x){$x -split "`t"}else{$null};$yp=if($null -ne $y){$y -split "`t"}else{$null}
                $cmp=if($null -eq $x){1}elseif($null -eq $y){-1}else{[StringComparer]::Ordinal.Compare($xp[0],$yp[0])}
                $row=$null
                if($cmp -eq 0){$logical=[long]$yp[2]-[long]$xp[2];$allocated=[long]$yp[3]-[long]$xp[3];if($logical -ne 0 -or $allocated -ne 0){$row=[ordered]@{Path=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($yp[1]));Observation='observed-both';LogicalDelta=$logical;AllocatedDelta=$allocated;BeforeBytes=[long]$xp[3];AfterBytes=[long]$yp[3]}};$x=$left.ReadLine();$y=$right.ReadLine()}
                elseif($cmp -lt 0){$row=[ordered]@{Path=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($xp[1]));Observation='not-observed-now';LogicalDelta=$null;AllocatedDelta=$null;BeforeBytes=[long]$xp[3];AfterBytes=$null};$x=$left.ReadLine()}
                else{$row=[ordered]@{Path=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($yp[1]));Observation='newly-observed';LogicalDelta=$null;AllocatedDelta=$null;BeforeBytes=$null;AfterBytes=[long]$yp[3]};$y=$right.ReadLine()}
                if($row){$count++;$row.ParentPath=[IO.Path]::GetDirectoryName($row.Path);$rank=if($null -eq $row.AllocatedDelta){'2'+'0'*20}elseif($row.AllocatedDelta -ge 0){'0'+([decimal][long]::MaxValue-[decimal]$row.AllocatedDelta).ToString('00000000000000000000')}else{'1'+([decimal][long]::MaxValue+[decimal]$row.AllocatedDelta).ToString('00000000000000000000')};$out.WriteLine($rank+"`t"+($row|ConvertTo-Json -Compress))}
            }
        }finally{$left.Dispose();$right.Dispose();$out.Dispose()}
        [SmartClean.DiskData]::Sort($raw,$sorted,(Join-Path $workspace 'sort-changes'))
        $rows=Join-Path $workspace 'rows.jsonl';$w=New-Object IO.StreamWriter($rows,$false,$script:Utf8)
        try{foreach($line in [IO.File]::ReadLines($sorted)){Test-SCCancel '';$w.WriteLine($line.Substring($line.IndexOf("`t")+1))}}finally{$w.Dispose()}
        foreach($temporary in @($files)+@((Join-Path $workspace 'dirs-0.txt'),(Join-Path $workspace 'dirs-1.txt'),$raw,$sorted)){if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
        return [pscustomobject]@{SchemaVersion=2;BeforeId=$Before.SnapshotId;AfterId=$After.SnapshotId;RowsFile=$rows;RowCount=$count;Warning='Охват не подтверждён. Не наблюдавшиеся ветки не считаются удалёнными. Родительские и дочерние размеры пересекаются и не складываются.';Changes=@(Read-SCJsonLinesPage $rows 0)}
    }finally{$a.Dispose();$b.Dispose()}
}
function Show-SCDiff($Diff) {
    Write-Host $Diff.Warning -ForegroundColor Yellow
    foreach($r in @($Diff.Changes|Where-Object {$_.Observation -eq 'observed-both'}|Sort-Object @{Expression={[Math]::Abs($_.AllocatedDelta)};Descending=$true}|Select-Object -First 25)){
        $sign=if($r.AllocatedDelta -ge 0){'+'}else{'-'}
        Write-Host ('{0}{1,12}  {2}' -f $sign,(Format-SCBytes ([Math]::Abs($r.AllocatedDelta))),$r.Path)
    }
    foreach($r in @($Diff.Changes|Where-Object {$_.Observation -ne 'observed-both'}|Select-Object -First 15)){
        Write-Host ('{0}: {1}' -f $(if($r.Observation -eq 'newly-observed'){'Впервые наблюдается'}else{'Не наблюдается в новом замере'}),$r.Path)
    }
    if($Diff.Changes.Count -eq 0){Write-Host 'Изменений каталогов в сопоставимой области не найдено.'}
}
