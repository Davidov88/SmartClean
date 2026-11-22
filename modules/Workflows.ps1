function Write-SCWorkProgress([string]$Stage,[long]$Completed=0,[long]$Total=0) {
    Assert-SCJobBudget
    if((Get-Variable SCProgressEmitted -Scope Script -ErrorAction SilentlyContinue) -and ([DateTime]::UtcNow-$script:SCProgressEmitted).TotalMilliseconds -lt 250){return};$script:SCProgressEmitted=[DateTime]::UtcNow
    Write-Progress -Activity 'SmartClean' -Status $Stage
    if(Get-Variable -Name SCProgressPath -Scope Script -ErrorAction SilentlyContinue){
        if($script:SCProgressPath){
            if(-not (Get-Variable -Name SCLastProgress -Scope Script -ErrorAction SilentlyContinue)){$script:SCLastProgress=[DateTime]::MinValue}
            if(([DateTime]::UtcNow-$script:SCLastProgress).TotalMilliseconds -ge 250){Write-SCJson $script:SCProgressPath @{Stage=$Stage;Completed=$Completed;Total=$Total;Utc=[DateTime]::UtcNow.ToString('o')};$script:SCLastProgress=[DateTime]::UtcNow}
        }
    }
}
function Get-SCWorkflowFiles($Config,[string[]]$Roots,[string]$CancelFile,[switch]$DuplicateMode) {
    Import-SCFileOperations;$policy=Get-SCPolicy $Config
    foreach($root in $Roots){
        $item=Get-Item -LiteralPath $root -Force
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Выберите фактический каталог вместо ссылки.'}
        $parent=if($item.PSIsContainer){$item.FullName}else{$item.DirectoryName}
        $ancestor=[IO.Path]::GetFullPath($parent)
        while($ancestor){$entry=Get-Item -LiteralPath $ancestor -Force;if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw ('Ссылка в исходном пути: '+$ancestor)};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
    }
    $excluded=@($policy.ProtectedPaths|Where-Object {$_.Scope -eq 'Tree'}|ForEach-Object {$_.Path})+@($policy.ScanExclusions|ForEach-Object {$_.Path})+@($Config.DataRoot,(Join-Path $script:ProjectRoot 'policy'),(Join-Path $script:ProjectRoot 'tools'))
    $segments=@('.git','node_modules','.venv','venv','site-packages','vendor','.gradle','.nuget','.claude','.codex','.vscode','.kiro','.android')
    if($DuplicateMode){$segments=@($policy.Defaults.DuplicateExcludedSegments)}
    $limit=[int](Get-SCField $policy.Defaults 'MaxDiscoveryFiles' 1000000)
    $workspace=New-SCWorkspace $Config
    $pathFile=Join-Path $workspace 'paths.txt';$diagnostics=Join-Path $workspace 'diagnostics.jsonl';$state=@{Limited=$false;Errors=0L;Skipped=0L;Files=0L}
    $writer=New-Object IO.StreamWriter($pathFile,$false,$script:Utf8);$log=New-Object IO.StreamWriter($diagnostics,$false,$script:Utf8)
    try{
        $sink=[Action[string,string,string]]{param($kind,$path,$reason)
            if($kind -eq 'Limit'){$state.Limited=$true}elseif($kind -eq 'Error'){$state.Errors++}else{$state.Skipped++}
            $log.WriteLine((@{Kind=$kind;Path=$path;Reason=$reason}|ConvertTo-Json -Compress))
        }
        foreach($path in [SmartClean.FileOperations]::Enumerate($Roots,[string[]]$segments,[string[]]$excluded,$limit,$CancelFile,$sink)){Test-SCCancel $CancelFile;$writer.WriteLine($path);$state.Files++;Write-SCWorkProgress 'Обнаружение файлов' $state.Files}
    }finally{$writer.Dispose();$log.Dispose()}
    [pscustomobject]@{PathFile=$pathFile;Workspace=$workspace;Diagnostics=$diagnostics;FileCount=$state.Files;Limited=$state.Limited;ErrorCount=$state.Errors;SkippedCount=$state.Skipped;Errors=@();Skipped=@()}
}
function New-SCWorkspace($Config) {
    $path=Join-Path $Config.DataRoot ('work\'+[Guid]::NewGuid().ToString('N'))
    Assert-SCOwnPath ([IO.Path]::GetFullPath($Config.DataRoot).TrimEnd('\')+'\') $path
    Register-SCStorageWrite $path
    [IO.Directory]::CreateDirectory($path)|Out-Null
    $process=Get-Process -Id $PID
    $jobId=if(Get-Variable SCJobDirectory -Scope Script -ErrorAction SilentlyContinue){Split-Path $script:SCJobDirectory -Leaf}else{''}
    Write-SCJson (Join-Path $path 'workspace.json') @{
        SchemaVersion=1;HostId=$Config.HostId;OwnerPid=$PID;OwnerStartedUtc=$process.StartTime.ToUniversalTime().ToString('o')
        JobId=$jobId;CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o')
    }
    return $path
}
function Import-SCDiskData {Import-SCIndexType;[SmartClean.DiskData]::Checkpoint=[Action]{Assert-SCJobBudget}}
function Get-SCDuplicateStateRoot($Config) {
    $root=Join-Path $Config.DataRoot 'duplicate-state'
    Assert-SCOwnPath ([IO.Path]::GetFullPath($Config.DataRoot).TrimEnd('\')+'\') $root
    return $root
}
function Find-SCDuplicates($Config,[string[]]$Roots,[string]$CancelFile,[switch]$Resume) {
    Import-SCFileOperations
    Import-SCDiskData
    $policy=Get-SCPolicy $Config
    $stateRoot=Get-SCDuplicateStateRoot $Config
    Register-SCStorageWrite $stateRoot
    [IO.Directory]::CreateDirectory($stateRoot)|Out-Null
    $checkpoint=Join-Path $stateRoot 'resume.json'
    $lease=$null;$cache=$null
    try{
        if($Resume){
            if(-not [IO.File]::Exists($checkpoint)){throw 'Нет завершённого обхода для продолжения. Запустите новый поиск.'}
            $saved=[IO.File]::ReadAllText($checkpoint)|ConvertFrom-Json
            if($saved.SchemaVersion -ne 1 -or $saved.HostId -ne $Config.HostId -or $saved.PolicyHash -ne $policy.Hash){throw 'Правила или версия контрольной точки изменились. Запустите новый поиск.'}
            if([DateTimeOffset]::UtcNow-(ConvertTo-SCUtc $saved.Utc) -gt [TimeSpan]::FromDays(30)){throw 'Срок хранения контрольной точки истёк. Запустите новый поиск.'}
            $oldWork=[IO.Path]::GetFullPath($saved.Workspace)
            $workRoot=[IO.Path]::GetFullPath((Join-Path $Config.DataRoot 'work')).TrimEnd('\')+'\'
            Assert-SCOwnPath $workRoot $oldWork
            $lease=Enter-SCWorkspaceLease $oldWork
            $sorted=Join-Path $oldWork 'sizes-sorted.txt'
            Assert-SCOwnPath $workRoot $sorted
            if(-not [IO.File]::Exists($sorted)){throw 'Файлы контрольной точки уже недоступны. Запустите новый поиск.'}
            if(@($Roots).Count){
                $requested=@($Roots|ForEach-Object {[IO.Path]::GetFullPath($_).TrimEnd('\')}|Sort-Object -Unique)
                $original=@($saved.Roots|ForEach-Object {[IO.Path]::GetFullPath($_).TrimEnd('\')}|Sort-Object -Unique)
                if(($requested -join '|') -ne ($original -join '|')){throw 'Для продолжения нужны прежние папки. Очистите список или запустите новый поиск.'}
            }
            $Roots=[string[]]@($saved.Roots)
            foreach($root in $Roots){
                $path=[IO.Path]::GetFullPath($root)
                Assert-SCOwnPath $path $path
            }
            $work=New-SCWorkspace $Config
            $diagnostics=Join-Path $work 'diagnostics.jsonl'
            $fileCount=[long]$saved.Files;$checkpointUtc=$saved.Utc
            $failureCount=@{Count=0L};$limited=$false
        }else{
            if(-not @($Roots).Count){throw 'Выберите хотя бы одну папку.'}
            $listing=Get-SCWorkflowFiles $Config $Roots $CancelFile -DuplicateMode
            $work=$listing.Workspace;$diagnostics=$listing.Diagnostics;$fileCount=$listing.FileCount
            $failureCount=@{Count=[long]$listing.ErrorCount};$limited=$listing.Limited
            $raw=Join-Path $work 'sizes.txt';$sorted=Join-Path $work 'sizes-sorted.txt'
            $log=New-Object IO.StreamWriter($diagnostics,$true,$script:Utf8)
            $writer=New-Object IO.StreamWriter($raw,$false,$script:Utf8)
            try{
                foreach($path in [IO.File]::ReadLines($listing.PathFile)){
                    Test-SCCancel $CancelFile
                    try{
                        $stamp=[SmartClean.FileOperations]::Describe($path,$false,$CancelFile)
                        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($path))
                        $writer.WriteLine($stamp.Length.ToString('d20')+"`t"+$stamp.Identity+"`t"+$encoded)
                    }catch{
                        Test-SCCancel $CancelFile;$failureCount.Count++
                        $log.WriteLine((@{Kind='Error';Path=$path;Reason=$_.Exception.Message}|ConvertTo-Json -Compress))
                    }
                }
            }finally{$writer.Dispose();$log.Dispose()}
            [SmartClean.DiskData]::Sort($raw,$sorted,(Join-Path $work 'sort-size'))
            [IO.File]::Delete($raw)
            [IO.File]::Delete($listing.PathFile)
            $checkpointUtc=$null
            if(-not $limited -and $failureCount.Count -eq 0){
                $checkpointUtc=[DateTimeOffset]::UtcNow.ToString('o')
                Write-SCJson $checkpoint @{SchemaVersion=1;HostId=$Config.HostId;PolicyHash=$policy.Hash;Roots=$Roots;Workspace=$work;Files=$fileCount;Utc=$checkpointUtc}
            }
        }

        $cachePath=Join-Path $stateRoot 'fingerprints'
        Assert-SCOwnPath ($stateRoot.TrimEnd('\')+'\') $cachePath
        $cache=New-Object SmartClean.DuplicateHashCache($cachePath)
        $stats=@{Sampled=0L;Hashed=0L;CacheHits=0L;Hardlinks=0L}
        $quick=Join-Path $work 'quick.txt';$quickSorted=Join-Path $work 'quick-sorted.txt'
        $hashes=Join-Path $work 'hashes.txt';$hashesSorted=Join-Path $work 'hashes-sorted.txt'
        $log=New-Object IO.StreamWriter($diagnostics,$true,$script:Utf8)
        try{
            $output=New-Object IO.StreamWriter($quick,$false,$script:Utf8)
            try{
                $sampleFile={
                    param([string]$line)
                    $parts=$line -split "`t"
                    $path=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[2]))
                    try{
                        $sample='small'
                        if([long]$parts[0] -gt 1MB){
                            Assert-SCOwnPath $path $path
                            $stamp=[SmartClean.FileOperations]::GetDuplicateFingerprint($path,[long]$parts[0],$parts[1],$true,$null,$CancelFile)
                            $sample=$stamp.Hash;$stats.Sampled++
                        }
                        $output.WriteLine($parts[0]+'|'+$sample+"`t"+$line)
                    }catch{
                        Test-SCCancel $CancelFile;$failureCount.Count++
                        $log.WriteLine((@{Kind='Error';Path=$path;Reason=$_.Exception.Message}|ConvertTo-Json -Compress))
                    }
                }
                $last='';$pending=$null
                foreach($line in [IO.File]::ReadLines($sorted)){
                    Test-SCCancel $CancelFile
                    Write-SCWorkProgress 'Сравнение размеров и выборок' $stats.Sampled
                    $key=$line.Substring(0,$line.IndexOf("`t"))
                    if($key -eq $last){if($pending){& $sampleFile $pending;$pending=$null};& $sampleFile $line}else{$pending=$line}
                    $last=$key
                }
            }finally{$output.Dispose()}
            [SmartClean.DiskData]::Sort($quick,$quickSorted,(Join-Path $work 'sort-quick'))
            $output=New-Object IO.StreamWriter($hashes,$false,$script:Utf8)
            try{
                $hashFile={
                    param([string]$line)
                    $parts=$line -split "`t"
                    $path=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[3]))
                    try{
                        Assert-SCOwnPath $path $path
                        $stamp=[SmartClean.FileOperations]::GetDuplicateFingerprint($path,[long]$parts[1],$parts[2],$false,$cache,$CancelFile)
                        if($stamp.Cached){$stats.CacheHits++}else{$stats.Hashed++}
                        $volume=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$stamp.Volume))
                        $identity=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($stamp.Identity))
                        $output.WriteLine(($stamp.Hash,$identity,$parts[3],$stamp.Bytes,$volume,$stamp.Cached) -join "`t")
                    }catch{
                        Test-SCCancel $CancelFile;$failureCount.Count++
                        $log.WriteLine((@{Kind='Error';Path=$path;Reason=$_.Exception.Message}|ConvertTo-Json -Compress))
                    }
                }
                $last='';$pending=$null
                foreach($line in [IO.File]::ReadLines($quickSorted)){
                    Test-SCCancel $CancelFile
                    Write-SCWorkProgress 'Проверка полного состава файлов' ($stats.Hashed+$stats.CacheHits)
                    $key=$line.Substring(0,$line.IndexOf("`t"))
                    if($key -eq $last){if($pending){& $hashFile $pending;$pending=$null};& $hashFile $line}else{$pending=$line}
                    $last=$key
                }
            }finally{$output.Dispose()}
        }finally{$log.Dispose()}
        [SmartClean.DiskData]::Sort($hashes,$hashesSorted,(Join-Path $work 'sort-hash'))
        $published=Publish-SCDuplicateResults $work $hashesSorted $stats $CancelFile
        foreach($temporary in @($quick,$quickSorted,$hashes,$hashesSorted)){
            if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
        }
        [pscustomobject]@{
            SchemaVersion=3;Roots=$Roots;CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');Resumed=[bool]$Resume;CheckpointUtc=$checkpointUtc
            Rows=@(Read-SCJsonLinesPage $published.RowsFile 0);RowsFile=$published.RowsFile;RowCount=$published.RowCount
            GroupsFile=$published.GroupsFile;GroupCount=$published.GroupCount
            Groups=@((Get-SCDuplicateGroupPage $Config $published.GroupsFile 0 $false).Rows)
            FilesExamined=$fileCount;FilesHashed=$stats.Hashed;CacheHits=$stats.CacheHits;Sampled=$stats.Sampled
            HardlinksSkipped=$stats.Hardlinks;Limited=($limited -or $failureCount.Count -gt 0 -or $Resume)
            Diagnostics=$diagnostics;ErrorCount=$failureCount.Count;Errors=@()
            Note=$(if($Resume){'Использован прежний список файлов. Для добавления новых файлов запустите новый поиск.'}else{'Сверяйте сохраняемую копию перед подготовкой плана.'})
        }
    }finally{
        try{if($cache){$cache.Dispose()}}finally{Exit-SCWorkspaceLease $lease}
    }
}
function Publish-SCDuplicateResults([string]$Workspace,[string]$Sorted,$Stats,[string]$CancelFile) {
    $rowsFile=Join-Path $Workspace 'rows.jsonl';$groupsFile=Join-Path $Workspace 'groups.jsonl'
    $rows=[IO.File]::Open($rowsFile,[IO.FileMode]::CreateNew)
    $groups=[IO.File]::Open($groupsFile,[IO.FileMode]::CreateNew)
    $rankPath=Join-Path $Workspace 'group-rank.txt'
    $rank=New-Object IO.StreamWriter($rankPath,$false,$script:Utf8)
    $scratch=Join-Path $Workspace 'group.txt';$group=$null
    $state=@{Rows=0L;Groups=0L};$key='';$identity='';$count=0;$volumes=@{};$known=0;$bytes=0L
    $flush={
        if($group){$group.Dispose()}
        if($count -lt 2){return}
        $position=$rows.Position
        foreach($line in [IO.File]::ReadLines($scratch)){
            Test-SCCancel $CancelFile
            $parts=$line -split "`t"
            $path=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[2]))
            $volume=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[4]))
            $row=@{Keep=$true;GroupId=$key;Path=$path;Bytes=[long]$parts[3];VolumeId=$volume;Drive=[IO.Path]::GetPathRoot($path);Copies=$count;Cached=($parts[5] -eq 'True')}
            $data=$script:Utf8.GetBytes(($row|ConvertTo-Json -Compress)+"`n")
            $rows.Write($data,0,$data.Length);$state.Rows++
        }
        $summary=@{GroupId=$key;Label=$key.Substring(0,12);Copies=$count;Volumes=$volumes.Count;CrossVolume=($volumes.Count -gt 1);UnknownVolumeCopies=($count-$known);Bytes=$bytes;DuplicateBytes=($count-1L)*$bytes;Offset=$position}
        $priority=([decimal][long]::MaxValue-[decimal]$summary.DuplicateBytes).ToString('00000000000000000000',[Globalization.CultureInfo]::InvariantCulture)
        $rank.WriteLine(($priority,$key,$groups.Position,$summary.CrossVolume) -join "`t")
        $data=$script:Utf8.GetBytes(($summary|ConvertTo-Json -Compress)+"`n")
        $groups.Write($data,0,$data.Length);$state.Groups++
    }
    try{
        foreach($line in [IO.File]::ReadLines($Sorted)){
            Test-SCCancel $CancelFile
            $parts=$line -split "`t"
            if($parts[0] -ne $key){
                & $flush
                $key=$parts[0];$identity='';$count=0;$volumes=@{};$known=0;$bytes=[long]$parts[3]
                $group=New-Object IO.StreamWriter($scratch,$false,$script:Utf8)
            }
            if($parts[1] -eq $identity){$Stats.Hardlinks++;continue}
            $identity=$parts[1];$group.WriteLine($line);$count++
            if($parts[4]){$volumes[$parts[4]]=$true;$known++}
        }
        & $flush
    }finally{if($group){$group.Dispose()};$rows.Dispose();$groups.Dispose();$rank.Dispose()}
    $rankSorted=Join-Path $Workspace 'group-rank-sorted.txt'
    [SmartClean.DiskData]::Sort($rankPath,$rankSorted,(Join-Path $Workspace 'sort-group'))
    $allIndex=New-Object IO.BinaryWriter([IO.File]::Open((Join-Path $Workspace 'groups-all.idx'),[IO.FileMode]::CreateNew))
    $crossIndex=New-Object IO.BinaryWriter([IO.File]::Open((Join-Path $Workspace 'groups-cross.idx'),[IO.FileMode]::CreateNew))
    try{
        foreach($line in [IO.File]::ReadLines($rankSorted)){
            Test-SCCancel $CancelFile
            $parts=$line -split "`t";$offset=[long]$parts[2]
            $allIndex.Write($offset)
            if($parts[3] -eq 'True'){$crossIndex.Write($offset)}
        }
    }finally{$allIndex.Dispose();$crossIndex.Dispose()}
    foreach($temporary in @($scratch,$rankPath,$rankSorted)){if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
    [pscustomobject]@{RowsFile=$rowsFile;GroupsFile=$groupsFile;RowCount=$state.Rows;GroupCount=$state.Groups}
}
function Get-SCDuplicateGroupPage($Config,[string]$GroupsFile,[int]$Page,[bool]$CrossVolume) {
    if($Page -lt 0){throw 'Неверная страница групп.'}
    $root=[IO.Path]::GetFullPath((Join-Path $Config.DataRoot 'work')).TrimEnd('\')+'\'
    Assert-SCOwnPath $root $GroupsFile
    if([IO.Path]::GetFileName($GroupsFile) -ne 'groups.jsonl'){throw 'Неверный файл групп.'}
    $indexName=if($CrossVolume){'groups-cross.idx'}else{'groups-all.idx'}
    $indexPath=Join-Path ([IO.Path]::GetDirectoryName($GroupsFile)) $indexName
    Assert-SCOwnPath $root $indexPath
    $index=[IO.File]::OpenRead($indexPath)
    try{
        if($index.Length%8 -ne 0){throw 'Индекс групп повреждён.'}
        $count=[long]($index.Length/8)
        $result=New-Object 'Collections.Generic.List[object]'
        if($Page*50L -lt $count){
            $index.Position=$Page*400L
            $offsetReader=New-Object IO.BinaryReader($index)
            $stream=[IO.File]::OpenRead($GroupsFile)
            try{
                $remaining=[Math]::Min(50L,$count-$Page*50L)
                for($i=0;$i -lt $remaining;$i++){
                    Test-SCCancel ''
                    $offset=$offsetReader.ReadInt64()
                    if($offset -lt 0 -or $offset -ge $stream.Length){throw 'Смещение группы повреждено.'}
                    $stream.Position=$offset
                    $reader=New-Object IO.StreamReader($stream,$script:Utf8,$false,4096,$true)
                    try{$result.Add(($reader.ReadLine()|ConvertFrom-Json))}finally{$reader.Dispose()}
                }
            }finally{$stream.Dispose();$offsetReader.Dispose()}
        }
        [pscustomobject]@{Rows=$result.ToArray();Count=$count;Page=$Page;CrossVolume=$CrossVolume}
    }finally{$index.Dispose()}
}
function Get-SCDuplicateCopies($Config,[string]$RowsFile,[string]$GroupId,[long]$Offset,[int]$Page) {
    if($GroupId -notmatch '^[a-f0-9]{64}$' -or $Offset -lt 0 -or $Page -lt 0){throw 'Неверная группа дублей.'}
    $root=[IO.Path]::GetFullPath((Join-Path $Config.DataRoot 'work')).TrimEnd('\')+'\'
    Assert-SCOwnPath $root $RowsFile
    if([IO.Path]::GetFileName($RowsFile) -ne 'rows.jsonl'){throw 'Неверный файл копий.'}
    $stream=[IO.File]::OpenRead($RowsFile)
    $result=New-Object 'Collections.Generic.List[object]'
    try{
        if($Offset -ge $stream.Length){throw 'Смещение группы отсутствует в результате.'}
        $stream.Position=$Offset
        $reader=New-Object IO.StreamReader($stream,$script:Utf8)
        try{
            $index=0L
            while($null -ne ($line=$reader.ReadLine()) -and $result.Count -lt 200){
                Test-SCCancel ''
                $copy=$line|ConvertFrom-Json
                if($copy.GroupId -ne $GroupId){break}
                if($index -ge $Page*200L){$result.Add($copy)}
                $index++
            }
        }finally{$reader.Dispose()}
    }finally{$stream.Dispose()}
    [pscustomobject]@{Rows=$result.ToArray();Page=$Page;GroupId=$GroupId}
}
function Get-SCDuplicateVolumeProposal($Config,$Request) {
    $page=Get-SCDuplicateCopies $Config $Request.RowsFile $Request.GroupId ([long]$Request.Offset) ([int]$Request.Page)
    $selected=@($page.Rows|Where-Object {$_.Path -eq $Request.Path}|Select-Object -First 1)
    if(-not $selected.Count -or -not $selected[0].VolumeId){throw 'Выберите копию на томе с известным идентификатором.'}
    $from=$selected[0].VolumeId
    $preferred=$null
    $suggestions=New-Object 'Collections.Generic.List[string]'
    $limit=[int](Get-SCPolicy $Config).Defaults.MaxPlanFiles
    $stream=[IO.File]::OpenRead($Request.RowsFile)
    try{
        $stream.Position=[long]$Request.Offset
        $reader=New-Object IO.StreamReader($stream,$script:Utf8)
        try{
            while($null -ne ($line=$reader.ReadLine())){
                Test-SCCancel ''
                $row=$line|ConvertFrom-Json
                if($row.GroupId -ne $Request.GroupId){break}
                if($row.Path -eq $Request.Reference){$preferred=$row;continue}
                if($row.VolumeId -eq $from){
                    if($suggestions.Count -ge $limit){throw 'Слишком много копий на исходном томе. Выберите файлы вручную.'}
                    $suggestions.Add($row.Path)
                }
            }
        }finally{$reader.Dispose()}
    }finally{$stream.Dispose()}
    if(-not $preferred -or -not $preferred.VolumeId -or $preferred.VolumeId -eq $from){
        throw 'Назначьте сохраняемую копию этой группы на другом известном томе.'
    }
    Assert-SCOwnPath $preferred.Path $preferred.Path
    $stamp=Get-SCStamp $preferred.Path ''
    if($stamp.ContentHash -ne $Request.GroupId){throw 'Сохраняемая копия изменилась. Запустите новый поиск.'}
    [pscustomobject]@{Paths=$suggestions.ToArray();SourceDrive=$selected[0].Drive;Reference=$preferred.Path;GroupId=$Request.GroupId}
}
function Read-SCJsonLinesPage([string]$Path,[int]$Page=0) {
    if($Page -lt 0){throw 'Некорректная страница.'};$i=0L;$end=($Page+1)*200
    foreach($line in [IO.File]::ReadLines($Path)){Test-SCCancel '';if($i -ge $end){break};if($i -ge $Page*200){$line|ConvertFrom-Json};$i++}
}
function New-SCDuplicatePlan($Config,$Rows,[string]$CancelFile,[string]$RowsFile='',$Choices=$null,$References=$null) {
    if($RowsFile){
        $full=[IO.Path]::GetFullPath($RowsFile);$root=[IO.Path]::GetFullPath((Join-Path $Config.DataRoot 'work')).TrimEnd('\')+'\'
        if(-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -ne 'rows.jsonl'){throw 'Чужой список дублей.'}
        $choiceMap=@{};if($Choices){foreach($p in $Choices.PSObject.Properties){$choiceMap[$p.Name]=[bool]$p.Value}}
        $referenceMap=@{}
        if($References){foreach($p in $References.PSObject.Properties){$referenceMap[$p.Name]=[string]$p.Value}}
        $keepers=@{};$mappings=New-Object 'Collections.Generic.List[object]'
        $limit=(Get-SCPolicy $Config).Defaults.MaxPlanFiles;$selected=0L
        foreach($line in [IO.File]::ReadLines($full)){
            Test-SCCancel $CancelFile
            $row=$line|ConvertFrom-Json
            if(-not $choiceMap.ContainsKey($row.Path) -or $choiceMap[$row.Path]){continue}
            $selected++
            if($mappings.Count -ge $limit){continue}
            $mappings.Add([pscustomobject]@{Source=$row.Path;Action='QuarantineFile';GroupId=$row.GroupId;ExpectedContentHash=$row.GroupId;KeepFile=''})
            $keepers[$row.GroupId]=''
        }
        if(-not $selected){throw 'Все копии отмечены «Оставить». Снимите отметку с ненужных копий.'}
        foreach($line in [IO.File]::ReadLines($full)){
            Test-SCCancel $CancelFile
            $row=$line|ConvertFrom-Json
            if(-not $keepers.ContainsKey($row.GroupId) -or $keepers[$row.GroupId]){continue}
            if($choiceMap.ContainsKey($row.Path) -and -not $choiceMap[$row.Path]){continue}
            if($referenceMap.ContainsKey($row.GroupId) -and $row.Path -ne $referenceMap[$row.GroupId]){continue}
            $keepers[$row.GroupId]=$row.Path
        }
        foreach($mapping in $mappings){
            $mapping.KeepFile=$keepers[$mapping.GroupId]
            if(-not $mapping.KeepFile){throw ('В группе не осталось сохраняемой копии: '+$mapping.GroupId)}
        }
        $omitted=$selected -gt $mappings.Count
        return New-SCFilePlan $Config 'Duplicates' $mappings.ToArray() $CancelFile @('Все невыбранные для изменения копии остаются. Полный состав сверяется перед исполнением.') ([pscustomobject]@{Discovered=$selected;Limited=$omitted;DiscoveryLimited=$false;Errors=@();Skipped=@()})
    }
    $mappings=New-Object 'Collections.Generic.List[object]'
    foreach($group in @($Rows|Group-Object GroupId)){
        $keep=@($group.Group|Where-Object {$_.Keep});$remove=@($group.Group|Where-Object {-not $_.Keep})
        if(-not $remove.Count){continue};if(-not $keep.Count){throw ('В группе '+$group.Name+' не выбрана сохраняемая копия.')}
        foreach($row in $remove){$mappings.Add([pscustomobject]@{Source=$row.Path;Action='QuarantineFile';KeepFile=$keep[0].Path})}
    }
    if(-not $mappings.Count){throw 'Все копии отмечены «Оставить». Снимите отметку с ненужных копий.'}
    New-SCFilePlan $Config 'Duplicates' $mappings.ToArray() $CancelFile @('Убираются только явно неотмеченные копии; хотя бы одна остаётся. Перед действием — полное побайтное сравнение.','Карантин сохраняет возможность восстановления.')
}
function New-SCOrganizationPlan($Config,[string]$Root,[string]$Destination,[string]$CancelFile,[switch]$Relocate) {
    $policy=Get-SCPolicy $Config
    $source=Assert-SCMutablePath $Config $policy $Root;$destination=Assert-SCMutablePath $Config $policy $Destination
    if($destination -eq $source -or $destination.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Назначение должно находиться вне исходной папки.'}
    $item=Get-Item -LiteralPath $source -Force
    $listing=Get-SCWorkflowFiles $Config @($source) $CancelFile
    $mappings=New-Object 'Collections.Generic.List[object]';$planLimited=$false
    foreach($file in [IO.File]::ReadLines($listing.PathFile)){
        Test-SCCancel $CancelFile
        if($mappings.Count -ge $policy.Defaults.MaxPlanFiles){$planLimited=$true;break}
        $relative=if($item.PSIsContainer){$file.Substring($source.Length).TrimStart('\')}else{[IO.Path]::GetFileName($file)}
        if($Relocate){
            $target=if($item.PSIsContainer){Join-Path $destination ([IO.Path]::GetFileName($source)+'\'+$relative)}else{Join-Path $destination $relative}
        }else{
            $category='Прочее';$extension=[IO.Path]::GetExtension($file).ToLowerInvariant()
            foreach($rule in $policy.OrganizationRules){if(@($rule.Extensions) -contains $extension){$category=$rule.Category;break}}
            if($category -eq '..' -or $category -eq '.' -or $category -match '[\\/:*?"<>|]'){throw 'Некорректное имя категории в правилах.'}
            $target=Join-Path $destination ($category+'\'+$relative)
        }
        $mappings.Add([pscustomobject]@{Source=$file;Destination=$target;Action='MoveFile'})
    }
    $notes=@('Перемещаются отдельные обычные файлы с сохранением структуры и проверкой SHA-256; исходные пустые каталоги остаются.','Ссылки, системные и защищённые каталоги пропускаются. Установленные/работающие приложения этим режимом не переносятся.','Никакой перезаписи: конфликты показаны в предупреждениях.')+@($listing.Errors)
    if($listing.Limited){$notes+='Достигнут предел обнаружения файлов: это частичный план.'}
    New-SCFilePlan $Config $(if($Relocate){'Relocate'}else{'Organize'}) $mappings.ToArray() $CancelFile $notes (New-SCPreparation $listing $planLimited)
}
function Get-SCCleanupCandidates($Config) {
    $result=New-Object 'Collections.Generic.List[object]'
    foreach($group in @(Get-SCSnapshots $Config|Where-Object {$_.HasIndex -and $_.HostId -eq $Config.HostId}|Group-Object VolumeId,Root)){
        $m=@($group.Group|Sort-Object StartedUtc -Descending)[0]
        $cache=Join-Path $Config.DataRoot ('reports\'+$m.SnapshotId+'\analysis.json')
        if(Test-Path -LiteralPath $cache){$analysis=Get-Content -LiteralPath $cache -Raw -Encoding UTF8|ConvertFrom-Json}
        else{$analysis=New-SCAnalysis $m;$export=Export-SCAnalysis $Config $analysis}
        foreach($candidate in $analysis.Candidates){$result.Add([pscustomobject]@{Selected=$false;RuleId=$candidate.RuleId;Title=$candidate.Title;Path=$candidate.Path;ObservedBytes=$candidate.ObservedBytes;Consequence=$candidate.Consequence;Review=$candidate.Review;SnapshotUtc=$m.FinishedUtc})}
    }
    return $result.ToArray()
}
function Assert-SCCleanupPrecondition($Config,$Policy,$Operation) {
    $rules=@(Get-SCReviewRules|Where-Object {$_.Id -eq $Operation.RuleId})
    if($rules.Count -ne 1 -or $Operation.RuleVersion -ne 1 -or $Operation.RuleScope -notmatch $rules[0].Pattern){throw 'Правило очистки или его область не совпадает.'}
    if(-not $Operation.Source.StartsWith($Operation.RuleScope.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Файл вне согласованного кэша.'}
    if($Operation.RuleId -eq 'spotify-data'){throw 'Автоматическая очистка офлайн-данных Spotify пока не допускается.'}
    $processNames=@()
    switch($Operation.RuleId){'browser-cache'{$processNames=@('chrome','msedge')};'editor-vsix-cache'{$processNames=@('Code','Kiro')};'pip-cache'{$processNames=@('pip','pip3')};'npm-cache'{$processNames=@('npm')};'user-temp'{
        $age=[DateTime]::UtcNow-(Get-Item -LiteralPath $Operation.Source -Force).LastWriteTimeUtc
        if($age.TotalDays -lt [double]$Policy.Defaults.MinimumTempAgeDays){throw 'Временный файл слишком свежий.'}
        if($Operation.Source -match '\\(?:claude|codex)(?:[-_\\.]|$)'){throw 'Временные данные Claude/Codex исключены.'}
    }}
    foreach($name in $processNames){if(Get-Process -Name $name -ErrorAction SilentlyContinue){throw ('Перед очисткой закройте '+$name+'. Программа автоматически не закрывается.')}}
}
function New-SCCleanupPlan($Config,$Candidates,[string]$CancelFile) {
    $policy=Get-SCPolicy $Config;$mappings=New-Object 'Collections.Generic.List[object]';$work=New-SCWorkspace $Config;$diagnostics=Join-Path $work 'cleanup-diagnostics.jsonl';$log=New-Object IO.StreamWriter($diagnostics,$false,$script:Utf8)
    $prep=[pscustomobject]@{Discovered=0L;Limited=$false;Errors=@();Skipped=@();Diagnostics=@($diagnostics);ErrorCount=0L;SkippedCount=0L}
    try{foreach($candidate in $Candidates){
        if(-not $candidate.Selected){continue};Test-SCCancel $CancelFile
        try{
            $scope=Assert-SCMutablePath $Config $policy $candidate.Path -AllowExactContainer
            $listing=Get-SCWorkflowFiles $Config @($scope) $CancelFile
            $prep.Discovered+=$listing.FileCount;$prep.Limited=$prep.Limited -or $listing.Limited -or $listing.ErrorCount -gt 0;$prep.Diagnostics+=@($listing.Diagnostics);$prep.ErrorCount+=$listing.ErrorCount;$prep.SkippedCount+=$listing.SkippedCount
            foreach($file in [IO.File]::ReadLines($listing.PathFile)){
                Test-SCCancel $CancelFile;$op=[pscustomobject]@{Source=$file;RuleId=$candidate.RuleId;RuleVersion=1;RuleScope=$scope}
                try{
                    Assert-SCCleanupPrecondition $Config $policy $op
                    if($mappings.Count -ge $policy.Defaults.MaxPlanFiles){$prep.Limited=$true;$log.WriteLine((@{Kind='Limit';Path=$file;Reason='Лимит файлов плана; допустимый файл не включён'}|ConvertTo-Json -Compress));continue}
                    $mappings.Add([pscustomobject]@{Source=$file;Action='QuarantineFile';RuleId=$candidate.RuleId;RuleScope=$scope})
                }catch{Test-SCCancel $CancelFile;$prep.SkippedCount++;$log.WriteLine((@{Kind='Skipped';Path=$file;Reason=$_.Exception.Message}|ConvertTo-Json -Compress))}
            }
        }catch{Test-SCCancel $CancelFile;$prep.ErrorCount++;$prep.Limited=$true;$log.WriteLine((@{Kind='Error';Path=$candidate.Path;Reason=$_.Exception.Message}|ConvertTo-Json -Compress))}
    }}finally{$log.Dispose()}
    New-SCFilePlan $Config 'Cleanup' $mappings.ToArray() $CancelFile @('Файлы помещаются в карантин. Причины всех пропусков доступны в диагностике.','Старый замер — справка; в плане актуальные полные отпечатки.') $prep
}
function New-SCPurgePlan($Config,[string]$CancelFile) {
    $vault=Join-Path $Config.DataRoot 'vault'
    if(-not(Test-Path -LiteralPath $vault)){throw 'Карантин пуст.'}
    Import-SCFileOperations
    $listing=[SmartClean.FileOperations]::List(@($vault),@(),@(),10000,$CancelFile)
    $mappings=@($listing.Files|ForEach-Object {[pscustomobject]@{Source=$_;Action='PurgeFile'}})
    New-SCFilePlan $Config 'PurgeVault' $mappings $CancelFile @('БЕЗВОЗВРАТНОЕ удаление выбранного содержимого карантина. Восстановление через SmartClean после этого невозможно.') ([pscustomobject]@{Discovered=$listing.Files.Length;Limited=$listing.Limited;Errors=@($listing.Errors);Skipped=@($listing.Skipped)})
}

function New-SCPreparation($Listing,[bool]$PlanLimited=$false) {
    [pscustomobject]@{Discovered=$Listing.FileCount;Limited=($Listing.Limited -or $PlanLimited -or $Listing.ErrorCount -gt 0);DiscoveryLimited=($Listing.Limited -or $Listing.ErrorCount -gt 0);Errors=@();Skipped=@();Diagnostics=@($Listing.Diagnostics);ErrorCount=$Listing.ErrorCount;SkippedCount=$Listing.SkippedCount}
}
