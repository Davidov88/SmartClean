function Initialize-SCJobContext($Config,[string]$CancelFile,[int]$TimeoutSeconds=3600) {
    $script:SCJobContext=[pscustomobject]@{
        Config=$Config;CancelFile=$CancelFile;Started=[DateTimeOffset]::UtcNow;TimeoutSeconds=$TimeoutSeconds
        Root=$Config.DataRoot;StorageRecovery=$false;ExternalProcess=$null;LastBudget=[DateTime]::MinValue
        LastStorageCheck=[DateTime]::MinValue;BaselineBytes=0L;HasStorageBaseline=$false;Writes=@{}
    }
}
function Assert-SCJobBudget {
    if(-not (Get-Variable SCJobContext -Scope Script -ErrorAction SilentlyContinue) -or -not $script:SCJobContext){return}
    $j=$script:SCJobContext
    if($j.CancelFile -and [IO.File]::Exists($j.CancelFile)){throw [OperationCanceledException]::new('Остановка запрошена пользователем.')}
    if(([DateTimeOffset]::UtcNow-$j.Started).TotalSeconds -ge $j.TimeoutSeconds){throw 'Истёк лимит времени задания.'}
    if(([DateTime]::UtcNow-$j.LastBudget).TotalMilliseconds -lt 100){return};$j.LastBudget=[DateTime]::UtcNow
    $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($j.Config.DataRoot))
    if(-not $j.StorageRecovery -and $drive.AvailableFreeSpace -lt [long]$j.Config.MinimumFreeMiB*1MB){throw 'Недостаточно свободного резерва для результатов.'}
    if(-not $j.StorageRecovery -and $j.HasStorageBaseline -and ([DateTime]::UtcNow-$j.LastStorageCheck).TotalSeconds -ge 1){
        $j.LastStorageCheck=[DateTime]::UtcNow
        $bytes=$j.BaselineBytes
        foreach($path in @($j.Writes.Keys)){$bytes+=(Measure-SCStoragePath $path $j.CancelFile).Bytes-[long]$j.Writes[$path]}
        if($bytes -gt [double]$j.Config.MaxStoreGiB*1GB){throw 'Достигнут лимит хранилища по размерам файлов SmartClean.'}
    }
    $memory=[Diagnostics.Process]::GetCurrentProcess().WorkingSet64
    if($j.ExternalProcess -and -not $j.ExternalProcess.HasExited){$j.ExternalProcess.Refresh();$memory+=$j.ExternalProcess.WorkingSet64}
    if($memory -gt ([long]$j.Config.MaxScanMemoryMiB*1MB)){throw 'Достигнут общий лимит памяти задания. Выберите меньшую область.'}
}
function ConvertTo-SCUtc([string]$Value) {
    if($Value -notmatch '(?:Z|[+-]\d{2}:\d{2})$'){throw 'Дата разрешения должна содержать часовой пояс.'}
    $parsed=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)){throw 'Некорректная дата разрешения.'}
    return $parsed.ToUniversalTime()
}
function Test-SCExpiry([string]$Value) {try{return (ConvertTo-SCUtc $Value) -gt [DateTimeOffset]::UtcNow}catch{return $false}}
function Get-SCResultPage($Rows,[int]$Page=0,[int]$PageSize=200) {
    if($Page -lt 0 -or $PageSize -lt 1 -or $PageSize -gt 200){throw 'Некорректная страница результата.'}
    @($Rows|Select-Object -Skip ($Page*$PageSize) -First $PageSize)
}
