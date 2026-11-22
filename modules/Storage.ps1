function Measure-SCStoragePath([string]$Path,[string]$CancelFile) {
    $bytes=0L;$count=0L
    if(-not (Test-Path -LiteralPath $Path)){return [pscustomobject]@{Bytes=$bytes;Files=$count}}
    $pending=New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Path)
    while($pending.Count){
        if($CancelFile -and [IO.File]::Exists($CancelFile)){throw [OperationCanceledException]::new('Сверка хранилища остановлена.')}
        $item=Get-Item -LiteralPath $pending.Pop() -Force -ErrorAction Stop
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Ссылка в хранилище: '+$item.FullName)}
        if($item.PSIsContainer){
            foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($item.FullName)){$pending.Push($entry)}
        }else{$bytes+=$item.Length;$count++}
    }
    [pscustomobject]@{Bytes=$bytes;Files=$count}
}
function Get-SCStorageInventory($Config,[string]$CancelFile) {
    $root=[IO.Path]::GetFullPath($Config.DataRoot).TrimEnd('\')+'\'
    Assert-SCOwnPath $root $root
    $items=@()
    if(Test-Path -LiteralPath $root){$items=@(Get-ChildItem -LiteralPath $root -Force)}
    $rows=@(foreach($item in $items){
        if($item.Name -eq 'storage-catalog.json'){continue}
        $size=Measure-SCStoragePath $item.FullName $CancelFile
        [pscustomobject]@{Category=$item.Name;Path=$item.FullName;Bytes=$size.Bytes;Files=$size.Files;Protected=($item.Name -notin @('snapshots','reports','jobs','work'))}
    })
    $catalog=[pscustomobject]@{SchemaVersion=2;Root=$Config.DataRoot;MeasuredUtc=[DateTimeOffset]::UtcNow.ToString('o');Known=$true;Rows=$rows;Bytes=[long]($rows|Measure-Object Bytes -Sum).Sum}
    if(Test-Path -LiteralPath $root){Write-SCJson (Join-Path $root 'storage-catalog.json') $catalog}
    return $catalog
}
function Get-SCStorageBaseline($Config,[string]$CancelFile='') {
    Get-SCStorageInventory $Config $CancelFile
}
function Register-SCStorageWrite([string]$Path) {
    if(-not (Get-Variable SCJobContext -Scope Script -ErrorAction SilentlyContinue) -or -not $script:SCJobContext){return}
    $job=$script:SCJobContext
    $root=[IO.Path]::GetFullPath($job.Root).TrimEnd('\')+'\'
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){return}
    foreach($existing in @($job.Writes.Keys)){
        if($full -eq $existing -or $full.StartsWith($existing+'\',[StringComparison]::OrdinalIgnoreCase)){return}
        if($existing.StartsWith($full+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Вложенные области учёта записи.'}
    }
    $job.Writes[$full]=(Measure-SCStoragePath $full $job.CancelFile).Bytes
}
function Get-SCMaintenanceCandidates($Config) {
    $jobs=Join-Path $Config.DataRoot 'jobs';$index=0
    if(Test-Path -LiteralPath $jobs){foreach($dir in @(Get-ChildItem -LiteralPath $jobs -Directory|Sort-Object LastWriteTimeUtc -Descending)){
        Test-SCCancel '';if($dir.Name -notmatch '^[a-f0-9]{32}$' -or ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)){continue}
        $state=Get-SCJobRetentionState $Config $dir.FullName
        if($state -notin @('Completed','Cancelled','Failed','Interrupted')){continue}
        $index++
        if($index -gt 100 -or $dir.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-30)){
            $reason=if($state -eq 'Interrupted'){'Прерванное задание; процесс завершился'}else{'Завершённое задание: старше 30 дней или сверх последних 100'}
            [pscustomobject]@{Path=$dir.FullName;Kind='job';Reason=$reason;ModifiedUtc=$dir.LastWriteTimeUtc.ToString('o')}
        }
    }}
    $work=Join-Path $Config.DataRoot 'work'
    if(Test-Path -LiteralPath $work){
        foreach($dir in Get-ChildItem -LiteralPath $work -Directory){
            Test-SCCancel ''
            if(Test-SCExpiredWorkspace $Config $dir.FullName){
                [pscustomobject]@{Path=$dir.FullName;Kind='work';Reason='Рабочие файлы завершённого или прерванного процесса, старше 30 дней';ModifiedUtc=$dir.LastWriteTimeUtc.ToString('o')}
            }
        }
    }
    $reports=Join-Path $Config.DataRoot 'reports'
    if(Test-Path -LiteralPath $reports){foreach($dir in Get-ChildItem -LiteralPath $reports -Directory){
        if(($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $dir.LastWriteTimeUtc -ge [DateTime]::UtcNow.AddDays(-30)){continue}
        if($dir.Name -match '^\d{8}-\d{6}-[a-f0-9]{8}$' -and -not(Test-Path -LiteralPath (Join-Path $Config.DataRoot ('snapshots\'+$dir.Name)))){
            [pscustomobject]@{Path=$dir.FullName;Kind='report';Reason='Производный отчёт без снимка, старше 30 дней';ModifiedUtc=$dir.LastWriteTimeUtc.ToString('o')}
        }
    }}
}
function Remove-SCOwnArtifactCore($Config,[string]$Path,[ValidateSet('job','report','snapshot','work')][string]$Kind,[switch]$Confirmed) {
    if(-not $Confirmed){throw 'Требуется подтверждение списка собственных артефактов.'}
    $part=@{job='jobs';report='reports';snapshot='snapshots';work='work'}[$Kind]
    $root=[IO.Path]::GetFullPath((Join-Path $Config.DataRoot $part)).TrimEnd('\')+'\';$full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    if(-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($full) -ne $root.TrimEnd('\')){throw 'Удаление разрешено только для собственного артефакта первого уровня.'}
    $name=[IO.Path]::GetFileName($full)
    if(($Kind -in @('job','work') -and $name -notmatch '^[a-f0-9]{32}$') -or ($Kind -in @('report','snapshot') -and $name -notmatch '^\d{8}-\d{6}-[a-f0-9]{8}$')){throw 'Имя не соответствует собственному артефакту SmartClean.'}
    if($Kind -eq 'job' -and (Get-SCJobRetentionState $Config $full) -notin @('Completed','Failed','Cancelled','Interrupted')){throw 'Задание активно или его происхождение не подтверждено.'}
    if($Kind -eq 'snapshot'){$manifest=Get-Content -LiteralPath (Join-Path $full 'manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json;if($manifest.Status -eq 'running'){throw 'Активный снимок не удаляется.'}}
    Assert-SCOwnPath $root $full
    if($Kind -eq 'work' -and -not (Test-SCExpiredWorkspace $Config $full)){throw 'Рабочая папка активна или срок хранения не истёк.'}
    # Resolve every path before deletion and never traverse a reparse point.
    $stack=New-Object 'Collections.Generic.Stack[string]';$stack.Push($full);$dirs=New-Object 'Collections.Generic.List[string]';$files=New-Object 'Collections.Generic.List[string]'
    while($stack.Count){$dir=$stack.Pop();$item=Get-Item -LiteralPath $dir -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Ссылка внутри артефакта: удаление остановлено.'};$dirs.Add($dir)
        foreach($entry in Get-ChildItem -LiteralPath $dir -Force){if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Ссылка внутри артефакта: удаление остановлено.'};if($entry.PSIsContainer){$stack.Push($entry.FullName)}else{$files.Add($entry.FullName)}}
    }
    foreach($file in $files){Assert-SCOwnPath $root $file;Remove-Item -LiteralPath $file -ErrorAction Stop};for($i=$dirs.Count-1;$i -ge 0;$i--){Assert-SCOwnPath $root $dirs[$i];Remove-Item -LiteralPath $dirs[$i] -ErrorAction Stop}
    Add-SCHistory $Config @{Type='own-artifact-removed';Path=$full;Kind=$Kind}
    if($Kind -eq 'snapshot'){$report=Join-Path $Config.DataRoot ('reports\'+$name);if(Test-Path -LiteralPath $report){Remove-SCOwnArtifact $Config $report 'report' -Confirmed}}
}
function Save-SCStorageSettings($Config,[string]$Root,[int]$MaxSnapshots,[double]$MaxStoreGiB,[int]$MinimumFreeMiB,[bool]$MaintenanceEnabled=$false) {
    if($MaxSnapshots -lt 1 -or $MaxStoreGiB -le 0 -or $MinimumFreeMiB -lt 512){throw 'Некорректные лимиты: снимки ≥1, хранилище >0, резерв ≥512 MiB.'}
    if($Root -notmatch '^[A-Za-z]:\\'){throw 'Для хранилища нужен абсолютный локальный путь.'}
    $full=[IO.Path]::GetFullPath($Root).TrimEnd('\');if($full.Length -le 3){throw 'Выберите отдельную папку результатов, а не корень тома.'};$drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($full))
    if(-not $drive.IsReady -or $drive.AvailableFreeSpace -lt $MinimumFreeMiB*1MB){throw 'Том недоступен или не имеет свободного резерва.'}
    if($Config.DataRoot -ne $full){$roots=@(Get-SCField $Config 'PreviousDataRoots' @())+@($Config.DataRoot);$Config|Add-Member NoteProperty PreviousDataRoots @($roots|Sort-Object -Unique) -Force}
    Assert-SCOwnPath ($full+'\') ($full+'\')
    $Config.DataRoot=$full;$Config.MaxSnapshots=$MaxSnapshots;$Config.MaxStoreGiB=$MaxStoreGiB;$Config.MinimumFreeMiB=$MinimumFreeMiB;$Config.Configured=$true
    $Config|Add-Member NoteProperty MaintenanceEnabled $MaintenanceEnabled -Force
    Save-SCConfig $Config;Initialize-SCStore $Config;return $Config
}

function Assert-SCOwnPath([string]$Root,[string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.StartsWith($Root,[StringComparison]::OrdinalIgnoreCase)){throw 'Путь вышел за границы собственных артефактов.'}
    $current=$full
    while($current){if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Ссылка в пути собственного артефакта: действие остановлено.'}};$current=[IO.Path]::GetDirectoryName($current)}
}
function Remove-SCOwnArtifact($Config,[string]$Path,[ValidateSet('job','report','snapshot','work')][string]$Kind,[switch]$Confirmed) {
    $mutex=New-Object Threading.Mutex($false,('Local\SmartClean-Mutation-'+$Config.HostId));$held=$false
    try{try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(-not $held){throw 'Другая операция меняет файлы.'};if($Kind -eq 'work'){
        $lease=Enter-SCWorkspaceLease $Path
        try{Remove-SCOwnArtifactCore $Config $Path $Kind -Confirmed:$Confirmed}finally{Exit-SCWorkspaceLease $lease}
    }else{Remove-SCOwnArtifactCore $Config $Path $Kind -Confirmed:$Confirmed}}finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}

function Test-SCExpiredWorkspace($Config,[string]$Path) {
    try{
        $root=[IO.Path]::GetFullPath((Join-Path $Config.DataRoot 'work')).TrimEnd('\')+'\'
        Assert-SCOwnPath $root $Path
        if([IO.Path]::GetFileName($Path) -notmatch '^[a-f0-9]{32}$'){return $false}
        $markerPath=Join-Path $Path 'workspace.json'
        Assert-SCOwnPath $root $markerPath
        if(-not [IO.File]::Exists($markerPath)){return $false}
        $marker=[IO.File]::ReadAllText($markerPath)|ConvertFrom-Json
        if($marker.SchemaVersion -ne 1 -or $marker.HostId -ne $Config.HostId){return $false}
        if((ConvertTo-SCUtc $marker.CreatedUtc) -ge [DateTimeOffset]::UtcNow.AddDays(-30)){return $false}
        $owner=Get-Process -Id ([int]$marker.OwnerPid) -ErrorAction SilentlyContinue
        if($owner -and $owner.StartTime.ToUniversalTime() -eq (ConvertTo-SCUtc $marker.OwnerStartedUtc).UtcDateTime){return $false}
        return $true
    }catch{return $false}
}
function Enter-SCWorkspaceLease([string]$Path) {
    $id=[IO.Path]::GetFileName($Path.TrimEnd('\'))
    if($id -notmatch '^[a-f0-9]{32}$'){throw 'Некорректный идентификатор рабочей папки.'}
    $mutex=New-Object Threading.Mutex($false,('Local\SmartClean-Workspace-'+$id))
    try{try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'Рабочая папка занята. Повторите запрос после окончания задания.'}
    }catch{$mutex.Dispose();throw}
    return $mutex
}
function Exit-SCWorkspaceLease($Lease) {if($Lease){$Lease.ReleaseMutex();$Lease.Dispose()}}


function Get-SCJobRetentionState($Config,[string]$Path) {
    try{
        $root=[IO.Path]::GetFullPath((Join-Path $Config.DataRoot 'jobs')).TrimEnd('\')+'\'
        $requestPath=Join-Path $Path 'request.json';$statusPath=Join-Path $Path 'status.json'
        Assert-SCOwnPath $root $requestPath;Assert-SCOwnPath $root $statusPath
        $request=[IO.File]::ReadAllText($requestPath)|ConvertFrom-Json
        if($request.SchemaVersion -ne 1 -or $request.DataRoot -ne $Config.DataRoot){return 'Unknown'}
        $status=[IO.File]::ReadAllText($statusPath)|ConvertFrom-Json
        if($status.State -ne 'Running'){return $status.State}
        if((ConvertTo-SCUtc $status.Utc) -ge [DateTimeOffset]::UtcNow.AddDays(-30)){return 'Running'}
        $owner=Get-Process -Id ([int]$status.OwnerPid) -ErrorAction SilentlyContinue
        if($owner -and $owner.StartTime.ToUniversalTime() -eq (ConvertTo-SCUtc $status.OwnerStartedUtc).UtcDateTime){return 'Running'}
        return 'Interrupted'
    }catch{return 'Unknown'}
}

function Enter-SCStorageWriter($Config) {
    $key=Get-SCTextHash ([IO.Path]::GetFullPath($Config.DataRoot).TrimEnd('\').ToUpperInvariant())
    $mutex=New-Object Threading.Mutex($false,('Local\SmartClean-Storage-'+$key))
    try{
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'Другое задание записывает данные в это хранилище. Повторите после его завершения.'}
    }catch{$mutex.Dispose();throw}
    return $mutex
}
