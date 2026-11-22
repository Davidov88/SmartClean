Set-StrictMode -Version 2
$script:AppVersion='0.4.0-preview.3'
# Preview checkpoint: diagnostic and planning commands are available; user-file mutation is not released.
$script:SCReleaseAllowsMutation=$false
$script:ProjectRoot=Split-Path $PSScriptRoot -Parent
$script:Utf8=New-Object Text.UTF8Encoding($false)
function Write-SCJson($Path,$Value) {
    if(-not ('SmartClean.AtomicJson' -as [type])){Add-Type -Path (Join-Path $script:ProjectRoot 'src\AtomicJson.cs')}
    [SmartClean.AtomicJson]::Write($Path,(ConvertTo-Json -InputObject $Value -Depth 32))
}
function Get-SCConfig {
    $configPath=Join-Path $script:ProjectRoot 'settings.json'
    if(Test-Path -LiteralPath $configPath) {
        $c=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($c.SchemaVersion -ne 1){throw 'Unsupported settings schema'}
        $newHost=Get-SCHostId
        if($c.PSObject.Properties['InstallRoot']){
            $oldRoot=([string]$c.InstallRoot).TrimEnd('\')+'\'
            if($c.DataRoot.StartsWith($oldRoot,[StringComparison]::OrdinalIgnoreCase)){
                $c.DataRoot=Join-Path $script:ProjectRoot $c.DataRoot.Substring($oldRoot.Length)
            }
        }
        if($c.HostId -ne $newHost){$c.Configured=$false;$c.DataRoot=Join-Path $script:ProjectRoot 'data'}
        $c.HostId=$newHost
        if(-not $c.PSObject.Properties['MaxScanMemoryMiB']){$c|Add-Member NoteProperty MaxScanMemoryMiB 1536}
        return $c
    }
    [pscustomobject]@{SchemaVersion=1;DataRoot=(Join-Path $script:ProjectRoot 'data');MaxSnapshots=12;MaxStoreGiB=4;MinimumFreeMiB=512;MaxScanMemoryMiB=1536;DefaultDepth=3;HostId=(Get-SCHostId);Configured=$false}
}
function Get-SCHostId {
    $identity=$env:COMPUTERNAME
    try{$identity+='|'+(Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid}catch{}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Save-SCConfig($Config) {
    $Config|Add-Member NoteProperty InstallRoot $script:ProjectRoot -Force
    Write-SCJson (Join-Path $script:ProjectRoot 'settings.json') $Config
}
function Initialize-SCStore($Config) {
    if(-not [IO.Path]::IsPathRooted($Config.DataRoot)){throw 'DataRoot must be an absolute path'}
    [IO.Directory]::CreateDirectory($Config.DataRoot)|Out-Null
    foreach($name in @('snapshots','history','locks')){[IO.Directory]::CreateDirectory((Join-Path $Config.DataRoot $name))|Out-Null}
    if(-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot 'settings.json'))){Save-SCConfig $Config}
}
function Format-SCBytes($Bytes) {
    if($null -eq $Bytes -or [long]$Bytes -lt 0){return '?'}
    foreach($unit in @(@('TiB',1TB),@('GiB',1GB),@('MiB',1MB),@('KiB',1KB))){if([double]$Bytes -ge [double]$unit[1]){return ('{0:N2} {1}' -f ([double]$Bytes/[double]$unit[1]),$unit[0])}}
    return "$Bytes B"
}
function Resolve-SCRoot([string]$Path) {
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if(-not $item.PSIsContainer -or $item.PSProvider.Name -ne 'FileSystem'){throw 'Нужен существующий каталог или корень тома.'}
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Корень является ссылкой. Выберите фактический путь назначения.'}
    return [IO.Path]::GetFullPath($item.FullName).TrimEnd('\')+'\'
}
function Get-SCStorageBytes([string]$Root) {
    $sum=0L
    if(Test-Path -LiteralPath $Root){Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction Stop | ForEach-Object {$sum+=$_.Length}}
    return $sum
}
function Add-SCHistory($Config,$Event) {
    $entry=[ordered]@{Utc=[DateTime]::UtcNow.ToString('o');AppVersion=$script:AppVersion;Event=$Event}
    [IO.File]::AppendAllText((Join-Path $Config.DataRoot 'history\events.jsonl'),($entry|ConvertTo-Json -Depth 8 -Compress)+[Environment]::NewLine,$script:Utf8)
}
function Assert-SCSpace($Config,$Baseline=$null) {
    $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Config.DataRoot))
    if($drive.IsReady -and $drive.AvailableFreeSpace -lt ([long]$Config.MinimumFreeMiB*1MB)){throw 'Недостаточно свободного места для записи результатов. Выберите другой каталог данных.'}
    if(-not $Baseline){$Baseline=Get-SCStorageBaseline $Config}
    $used=$Baseline.Bytes
    if($used -gt ([double]$Config.MaxStoreGiB*1GB)){throw 'Достигнут лимит хранилища SmartClean. Удалите ненужные замеры через историю или выберите другое хранилище.'}
    $count=@(Get-ChildItem -LiteralPath (Join-Path $Config.DataRoot 'snapshots') -Directory).Count
    if($count -ge $Config.MaxSnapshots){throw 'Достигнут лимит количества замеров. Просмотрите историю и удалите ненужные замеры SmartClean.'}
}
function Get-SCSnapshots($Config) {
    $base=Join-Path $Config.DataRoot 'snapshots'
    if(-not (Test-Path -LiteralPath $base)){return}
    Get-ChildItem -LiteralPath $base -Directory | Sort-Object Name -Descending | ForEach-Object {
        $file=Join-Path $_.FullName 'manifest.json'
        if(Test-Path -LiteralPath $file){try{$m=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json;$m|Add-Member NoteProperty SnapshotDirectory $_.FullName -Force;$m}catch{Write-Warning "Повреждён манифест: $file"}}
    }
}
function Import-SCIndexType {
    if(-not ('SmartClean.SnapshotIndex' -as [type])){Add-Type -Path @((Join-Path $script:ProjectRoot 'src\DiskData.cs'),(Join-Path $script:ProjectRoot 'src\SnapshotIndex.cs'))}
}
function Open-SCIndex($Manifest) {
    if($Manifest.SchemaVersion -ne 1){throw 'Неподдерживаемая схема замера'}
    if(-not $Manifest.HasIndex){throw 'У этого запуска нет готового индекса. Посмотрите его статус и причину.'}
    Import-SCIndexType
    [SmartClean.SnapshotIndex]::Checkpoint=[Action]{Assert-SCJobBudget}
    return New-Object SmartClean.SnapshotIndex($Manifest.SnapshotDirectory)
}
