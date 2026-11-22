function Get-SCEngine {
    $arch=$env:PROCESSOR_ARCHITECTURE
    $folder=if($arch -eq 'ARM64'){'arm64'}elseif([Environment]::Is64BitOperatingSystem){'x64'}else{'x86'}
    $exe=Join-Path $script:ProjectRoot ('tools\windirstat\'+$folder+'\WinDirStat.exe')
    if(-not(Test-Path -LiteralPath $exe)){throw 'Сканер не установлен. Запустите Install-Tools.ps1 в папке SmartClean.'}
    $lock=Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'tools.lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $lock.windirstat.binarySha256.$folder){throw 'Контрольная сумма сканера не совпала. Переустановите через Install-Tools.ps1.'}
    $version=(Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    if($version -ne '2.9.3'){throw "Непроверенная версия WinDirStat: $version. Требуется 2.9.3."}
    [pscustomobject]@{Id='windirstat';Version=$version;Path=$exe;Schema='windirstat-en-csv-2.9.3';Capabilities=@{Allocated=$true;HardlinkIds=$true;ErrorTelemetry=$false;PartialExportOnCancel=$false;Resume=$false}}
}
function Write-SCEngineSettings($Engine,$Config) {
    # A private portable copy avoids altering the user's installed WinDirStat settings.
    # English is neutral LANGID=9 (1033 is not present in the packaged resource list).
    $paths=@($Config.DataRoot.TrimEnd('\'))
    if(Get-Command Get-SCPolicy -ErrorAction SilentlyContinue){$policy=Get-SCPolicy $Config;$paths+=@($policy.ScanExclusions|ForEach-Object {$_.Path})}
    foreach($path in $paths){if($path -match '[\r\n]'){throw 'Переводы строк в пути исключения недопустимы.'}}
    # std::wregex ECMAScript requires closing ]/} escaped too; .NET Regex.Escape is insufficient.
    $patterns=@($paths|Sort-Object -Unique|ForEach-Object {
        $escaped=New-Object Text.StringBuilder
        foreach($character in $_.ToCharArray()){if('\.^$|?*+()[]{}'.Contains([string]$character)){[void]$escaped.Append('\')};[void]$escaped.Append($character)}
        $escaped.ToString()
    })
    $excluded='(?:'+($patterns -join '|')+')'
    $ini=@"
[Options]
LanguageId=9
ExcludeJunctions=1
ExcludeSymbolicLinksDirectory=1
ExcludeVolumeMountPoints=1
ExcludeSymbolicLinksFile=1
ExcludeHiddenDirectory=0
ExcludeProtectedDirectory=0
ExcludeHiddenFile=0
ExcludeProtectedFile=0
ExcludeDropboxIgnored=0
FollowVolumeMountPoints=0
UseFastScanEngine=1
ScanningThreads=1
FilteringUseRegex=1
FilteringSizeMinimum=0
FilteringMaxAgeDays=0
[DriveSelect]
FilteringExcludeDirs=$excluded
FilteringExcludeFiles=
FilteringIncludeDirs=
FilteringIncludeFiles=
"@
    [IO.File]::WriteAllText([IO.Path]::ChangeExtension($Engine.Path,'ini'),$ini,[Text.Encoding]::Unicode)
}
function Start-SCScan {
    [CmdletBinding()]
    param($Config,[string]$Path,[string]$CancelFile,[int]$TimeoutSeconds=3600)
    Initialize-SCJobContext $Config $CancelFile $TimeoutSeconds
    $root=Resolve-SCRoot $Path
    $data=[IO.Path]::GetFullPath($Config.DataRoot).TrimEnd('\')+'\'
    if($root.StartsWith($data,[StringComparison]::OrdinalIgnoreCase)){throw 'Нельзя сканировать собственное хранилище SmartClean.'}
    Initialize-SCStore $Config
    $writer=Enter-SCStorageWriter $Config
    try{
    $baseline=Get-SCStorageBaseline $Config $CancelFile
    Assert-SCSpace $Config $baseline
    $script:SCJobContext.BaselineBytes=[long]$baseline.Bytes
    $script:SCJobContext.HasStorageBaseline=$true
    $engine=Get-SCEngine
    # Keep a single scan across this portable installation: settings are shared by its engine.
    $lockPath=Join-Path $script:ProjectRoot 'scan.lock'
    $lock=$null;$process=$null;$manifest=$null;$directory=$null
    try {
        $lock=New-Object IO.FileStream($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        Write-SCEngineSettings $engine $Config
        $inventory=Get-SCInventory
        $id=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
        $directory=Join-Path $Config.DataRoot ('snapshots\'+$id)
        Register-SCStorageWrite $directory
        [IO.Directory]::CreateDirectory($directory)|Out-Null
        Write-SCJson (Join-Path $directory 'inventory.json') $inventory
        $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $elevated=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $manifest=[ordered]@{SchemaVersion=1;AppVersion=$script:AppVersion;SnapshotId=$id;HostId=$Config.HostId;Root=$root;VolumeId=(Get-SCVolumeIdentity $root $inventory);Elevated=$elevated;StartedUtc=[DateTime]::UtcNow.ToString('o');FinishedUtc=$null;Status='running';HasIndex=$false;Engine=$engine.Id;EngineVersion=$engine.Version;EngineSchema=$engine.Schema;Metric='logical-and-allocated-per-path';LinkPolicy='exclude-directory-links;file-id-dedup-for-unique';ExcludedRoots=@($data);Coverage='unverified';Warnings=@('Движок не экспортирует список ошибок доступа: полнота обхода не подтверждена.','Суммы файлов не включают все системные метаданные тома.');Failure=$null;Totals=$null;Measurements=$null}
        if(Get-Command Get-SCPolicy -ErrorAction SilentlyContinue){$policy=Get-SCPolicy $Config;$manifest.PolicyHash=$policy.Hash;$manifest.ExcludedRoots=@($data)+@($policy.ScanExclusions|ForEach-Object {$_.Path.TrimEnd('\')+'\'});$manifest.ExclusionReasons=$policy.ScanExclusions}
        Write-SCJson (Join-Path $directory 'manifest.json') $manifest
        $raw=Join-Path $directory 'engine.csv'
        $watch=[Diagnostics.Stopwatch]::StartNew()
        # Proper Windows argument escaping matters for root paths ending in a backslash.
        $arguments='/SaveTo '+(ConvertTo-SCArgument $raw)+' '+(ConvertTo-SCArgument $root)
        $process=Start-Process -FilePath $engine.Path -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $handle=$process.Handle;$script:SCJobContext.ExternalProcess=$process
        $cancelled=$false;$peak=0L;$lastCheck=0
        while(-not $process.HasExited){
            Test-SCCancel $CancelFile
            Write-SCWorkProgress 'Сканирование файловой системы'
            $process.Refresh();$peak=[Math]::Max($peak,$process.WorkingSet64)
            if($process.WorkingSet64 -gt ([long]$Config.MaxScanMemoryMiB*1MB)){throw 'Сканер превысил лимит памяти. Выберите меньшую область или измените лимит в настройках.'}
            $elapsed=[int]$watch.Elapsed.TotalSeconds
            if($elapsed -ge 2 -and $process.MainWindowHandle -ne [IntPtr]::Zero){throw 'Сканер открыл диалог вместо консольного экспорта. Запуск остановлен; проверьте фильтры и журнал.'}
            Write-Progress -Activity 'SmartClean: сканирование' -Status ("{0} | {1} с | память {2} | Esc — остановить" -f $root,$elapsed,(Format-SCBytes $process.WorkingSet64))
            $keyCancel=$false
            try{if(-not [Console]::IsInputRedirected -and [Console]::KeyAvailable){$keyCancel=([Console]::ReadKey($true).Key -eq 'Escape')}}catch{}
            if($keyCancel -or ($CancelFile -and (Test-Path -LiteralPath $CancelFile))){$cancelled=$true;break}
            if($elapsed -ge $TimeoutSeconds){throw 'Истёк лимит времени сканирования.'}
            if($elapsed-$lastCheck -ge 3){
                $lastCheck=$elapsed
                if(([long]$baseline.Bytes+$(if(Test-Path -LiteralPath $raw){(Get-Item -LiteralPath $raw).Length}else{0})) -gt ([double]$Config.MaxStoreGiB*1GB)){throw 'Сканирование остановлено: достигнут лимит размера хранилища.'}
                $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Config.DataRoot))
                if($drive.AvailableFreeSpace -lt ([long]$Config.MinimumFreeMiB*1MB)){throw 'Сканирование остановлено: мало места для отчёта.'}
            }
            Start-Sleep -Milliseconds 100
        }
        if($cancelled){
            if(-not $process.HasExited){$process.Kill();$process.WaitForExit()}
            $manifest.Status='cancelled';$manifest.Warnings+= 'Остановлен процесс. Этот адаптер не сохраняет частичный индекс и не поддерживает продолжение.'
        }else{
            $process.WaitForExit()
            $engineSeconds=$watch.Elapsed.TotalSeconds
            if($process.ExitCode -ne 0){throw "Сканер завершился с кодом $($process.ExitCode)."}
            if(-not(Test-Path -LiteralPath $raw)){throw 'Сканер не создал CSV.'}
            $rawBytes=(Get-Item -LiteralPath $raw).Length
            if(([long]$baseline.Bytes+$(if(Test-Path -LiteralPath $raw){(Get-Item -LiteralPath $raw).Length}else{0}))+2*$rawBytes -gt ([double]$Config.MaxStoreGiB*1GB)){throw 'Недостаточно лимита хранилища для индекса. Увеличьте лимит или выберите меньшую область.'}
            $outputDrive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Config.DataRoot))
            if($outputDrive.AvailableFreeSpace -lt (2*$rawBytes+[long]$Config.MinimumFreeMiB*1MB)){throw 'Недостаточно свободного места для индекса.'}
            Write-Progress -Activity 'SmartClean: сканирование' -Status 'Подготовка индекса из CSV'
            Import-SCIndexType
            $progress=[Action[long]]{
                param($count)
                if([Diagnostics.Process]::GetCurrentProcess().WorkingSet64 -gt ([long]$Config.MaxScanMemoryMiB*1MB)){throw 'Превышен лимит памяти при подготовке индекса.'}
                Test-SCCancel $CancelFile;Write-SCWorkProgress 'Подготовка индекса: чтение, агрегация и запись' $count
            }
            $cancel=[Func[bool]]{
                if($CancelFile -and (Test-Path -LiteralPath $CancelFile)){return $true}
                if($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds){return $true}
                try{if(-not [Console]::IsInputRedirected -and [Console]::KeyAvailable){return [Console]::ReadKey($true).Key -eq 'Escape'}}catch{}
                return $false
            }
            [SmartClean.SnapshotIndex]::Checkpoint=[Action]{Assert-SCJobBudget}
            [SmartClean.DiskData]::Checkpoint=[Action]{Assert-SCJobBudget}
            $totals=[SmartClean.SnapshotIndex]::ImportWinDirStat($raw,$directory,$root,$progress,$cancel)
            $importSeconds=$watch.Elapsed.TotalSeconds-$engineSeconds
            $manifest.Totals=$totals
            $manifest.HasIndex=$true;$manifest.Status='partial'
            $manifest.Warnings+='Обход завершён. Partial означает отсутствие гарантии полного доступа, а не незавершённый процесс.'
        }
        $watch.Stop()
        $manifest.Measurements=@{Seconds=[Math]::Round($watch.Elapsed.TotalSeconds,3);PeakSampledMiB=[Math]::Round($peak/1MB,2);RawBytes=$(if(Test-Path -LiteralPath $raw){(Get-Item -LiteralPath $raw).Length}else{0})}
        if(-not $cancelled){$manifest.Measurements.EngineSeconds=[Math]::Round($engineSeconds,3);$manifest.Measurements.ImportSeconds=[Math]::Round($importSeconds,3)}
    }catch{
        if($manifest){
            if($_.Exception -is [OperationCanceledException] -or $_.Exception.InnerException -is [OperationCanceledException]){$manifest.Status='cancelled';$manifest.Warnings+='Подготовка индекса остановлена; готового дерева нет.'}
            else{$manifest.Status='failed';$manifest.Failure=$_.Exception.Message}
        }else{throw}
    }finally{
        $script:SCJobContext.ExternalProcess=$null
        if($process){try{if(-not $process.HasExited){$process.Kill();$process.WaitForExit()}}finally{$process.Dispose()}}
        Write-Progress -Activity 'SmartClean: сканирование' -Completed
        if($manifest){
            if($manifest.Status -eq 'running'){$manifest.Status='cancelled';$manifest.Warnings+='Прервано до завершения индекса.'}
            $manifest.FinishedUtc=[DateTime]::UtcNow.ToString('o')
            Write-SCJson (Join-Path $directory 'manifest.json') $manifest
            Add-SCHistory $Config @{Type='scan';SnapshotId=$manifest.SnapshotId;Status=$manifest.Status;Root=$root;Failure=$manifest.Failure}
        }
        if($lock){$lock.Dispose()}
    }
    $result=[pscustomobject]$manifest
    $result|Add-Member NoteProperty SnapshotDirectory $directory
    return $result
    }finally{Exit-SCWorkspaceLease $writer}
}
function ConvertTo-SCArgument([string]$Value) {
    # CommandLineToArgvW quoting, including trailing backslashes before the closing quote.
    if($Value.Contains('"')){throw 'Недопустимая кавычка в пути.'}
    return '"'+[regex]::Replace($Value,'(\\+)$','$1$1')+'"'
}
