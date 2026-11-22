function Get-SCInventory {
    $warnings=New-Object 'Collections.Generic.List[string]'
    $disks=@();$partitions=@();$volumes=@();$media=@{}
    try {
        foreach($pd in @(Get-PhysicalDisk -ErrorAction Stop)){
            # Match by stable unique id when the storage provider exposes one.
            if($pd.UniqueId){$media[[string]$pd.UniqueId]=[string]$pd.MediaType}
        }
    }catch{$warnings.Add('Storage provider не сообщил типы физических носителей.')}
    try {
        $disks=@(Get-Disk -ErrorAction Stop | ForEach-Object {
            $type='Unknown';if($media.ContainsKey([string]$_.UniqueId)){$type=$media[[string]$_.UniqueId]}
            [pscustomobject]@{Number=$_.Number;Name=$_.FriendlyName;UniqueId=$_.UniqueId;BusType=[string]$_.BusType;MediaType=$type;SizeBytes=$_.Size;PartitionStyle=[string]$_.PartitionStyle;OperationalStatus=[string]$_.OperationalStatus}
        })
        $partitions=@(Get-Partition -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{DiskNumber=$_.DiskNumber;PartitionNumber=$_.PartitionNumber;DriveLetter=([string]$_.DriveLetter).Trim([char]0);AccessPaths=@($_.AccessPaths|Where-Object {$_});SizeBytes=$_.Size;Type=[string]$_.Type;Offset=$_.Offset}
        })
        $volumes=@(Get-Volume -ErrorAction Stop | ForEach-Object {
            $letter=([string]$_.DriveLetter).Trim([char]0);$volumePath=$_.Path
            $p=@($partitions|Where-Object {($letter -and $_.DriveLetter -eq $letter) -or ($volumePath -and $_.AccessPaths -contains $volumePath)})
            [pscustomobject]@{Id=[string]$_.UniqueId;DriveLetter=$letter;Path=$_.Path;Label=$_.FileSystemLabel;FileSystem=[string]$_.FileSystem;DriveType=[string]$_.DriveType;SizeBytes=[long]$_.Size;FreeBytes=[long]$_.SizeRemaining;DiskNumbers=@($p|ForEach-Object {$_.DiskNumber});PartitionNumbers=@($p|ForEach-Object {$_.PartitionNumber})}
        })
    }catch{
        $warnings.Add('Полная карта Storage API недоступна; показаны доступные логические диски. Связи разделов могут отсутствовать.')
        $volumes=@([IO.DriveInfo]::GetDrives()|Where-Object {$_.IsReady}|ForEach-Object {
            [pscustomobject]@{Id=$null;DriveLetter=$_.Name.Substring(0,1);Path=$_.Name;Label=$_.VolumeLabel;FileSystem=$_.DriveFormat;DriveType=[string]$_.DriveType;SizeBytes=$_.TotalSize;FreeBytes=$_.AvailableFreeSpace;DiskNumbers=@();PartitionNumbers=@()}
        })
    }
    [pscustomobject]@{SchemaVersion=1;ObservedUtc=[DateTime]::UtcNow.ToString('o');Disks=$disks;Partitions=$partitions;Volumes=$volumes;Warnings=@($warnings)}
}
function Show-SCInventory($Inventory) {
    Write-Host "`nНакопители и разделы" -ForegroundColor Cyan
    foreach($disk in $Inventory.Disks){
        Write-Host ('Диск {0}: {1} | {2} | {3} | {4} | {5}' -f $disk.Number,$disk.Name,$disk.MediaType,$disk.BusType,$disk.PartitionStyle,(Format-SCBytes $disk.SizeBytes))
        foreach($p in @($Inventory.Partitions|Where-Object {$_.DiskNumber -eq $disk.Number})){
            Write-Host ('  Раздел {0}: {1} {2} | {3}' -f $p.PartitionNumber,$p.DriveLetter,$p.Type,(Format-SCBytes $p.SizeBytes))
        }
    }
    Write-Host "`nТома"
    foreach($v in $Inventory.Volumes){
        Write-Host ('{0} {1} | {2} | свободно {3} из {4} | физические диски: {5}' -f $(if($v.DriveLetter){$v.DriveLetter+':'}else{$v.Path}),$v.Label,$v.FileSystem,(Format-SCBytes $v.FreeBytes),(Format-SCBytes $v.SizeBytes),($v.DiskNumbers -join ','))
    }
    foreach($warning in $Inventory.Warnings){Write-Warning $warning}
}
function Get-SCVolumeIdentity([string]$Root,$Inventory) {
    $drive=[IO.Path]::GetPathRoot($Root)
    $v=@($Inventory.Volumes|Where-Object {($_.DriveLetter+':\') -eq $drive})
    if($v.Count -eq 1 -and $v[0].Id){return [string]$v[0].Id}
    # No stable identity: keep null; diffs must not infer drive identity from its letter.
    return $null
}
