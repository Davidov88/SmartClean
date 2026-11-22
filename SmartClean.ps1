#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Menu','Inventory','Scan','Analyze','Overview','Browse','Compare','History','Policy','Duplicates','ResumeDuplicates','Organize','Relocate','Plans','Approve','Execute','Restore','PurgeVault','Gui')][string]$Command='Menu',
    [string]$Path,[string]$DataRoot,[string]$Before,[string]$After,[string]$SnapshotId,
    [string]$CancelFile,[int]$TimeoutSeconds=3600,[switch]$Json,[switch]$Refresh,
    [string[]]$Roots,[string]$Destination,[string]$PlanId,[switch]$ConfirmPlan,[switch]$AcceptPartial
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'modules\Load.ps1')
$config=Get-SCConfig
if($DataRoot){$config.DataRoot=[IO.Path]::GetFullPath($DataRoot)}
$storageWriter=$null
try{
    if($Command -notin @('Menu','Gui','Scan')){Initialize-SCJobContext $config $CancelFile $TimeoutSeconds}
    if($Command -in @('Analyze','Compare','Duplicates','ResumeDuplicates','Organize','Relocate','Restore','PurgeVault')){
        $storageWriter=Enter-SCStorageWriter $config
        $baseline=Get-SCStorageBaseline $config $CancelFile
        $script:SCJobContext.BaselineBytes=$baseline.Bytes
        $script:SCJobContext.HasStorageBaseline=$true
    }
    switch($Command){
        'Menu'{Start-SCMenu $config}
        'Gui'{Start-Process -FilePath (Join-Path $PSScriptRoot 'SmartClean.exe')}
        'Policy'{Get-SCPolicy $config|ConvertTo-Json -Depth 20}
        'ResumeDuplicates'{Find-SCDuplicates $config $Roots $CancelFile -Resume|ConvertTo-Json -Depth 16}
        'Duplicates'{Find-SCDuplicates $config $Roots $CancelFile|ConvertTo-Json -Depth 16}
        'Organize'{New-SCOrganizationPlan $config $Path $Destination $CancelFile|ConvertTo-Json -Depth 16}
        'Relocate'{New-SCOrganizationPlan $config $Path $Destination $CancelFile -Relocate|ConvertTo-Json -Depth 16}
        'Plans'{ConvertTo-Json -InputObject @(Get-SCPlans $config) -Depth 16}
        'Approve'{Approve-SCPlan $config $PlanId -Confirmed:$ConfirmPlan -AcceptPartial:$AcceptPartial|ConvertTo-Json -Depth 16}
        'Execute'{Invoke-SCPlan $config $PlanId $CancelFile|ConvertTo-Json -Depth 16}
        'Restore'{New-SCRollbackPlan $config $PlanId $CancelFile|ConvertTo-Json -Depth 16}
        'PurgeVault'{New-SCPurgePlan $config $CancelFile|ConvertTo-Json -Depth 16}
        'Inventory'{$r=Get-SCInventory;if($Json){$r|ConvertTo-Json -Depth 10}else{Show-SCInventory $r}}
        'Scan'{
            if(-not $Path){throw 'Укажите -Path C:\ или другой путь.'}
            $r=Start-SCScan -Config $config -Path $Path -CancelFile $CancelFile -TimeoutSeconds $TimeoutSeconds
            if($Json){$r|ConvertTo-Json -Depth 12}else{Show-SCSummary $r}
            if($r.Status -eq 'failed'){exit 1};if($r.Status -eq 'cancelled'){exit 2}
        }
        'History'{$r=@(Get-SCSnapshots $config);if($Json){ConvertTo-Json -InputObject $r -Depth 12}else{$r|Select-Object SnapshotId,Status,Root,FinishedUtc|Format-List}}
        'Browse'{$r=@(Get-SCSnapshots $config|Where-Object {$_.SnapshotId -eq $SnapshotId});if($r.Count -ne 1){throw 'Укажите существующий -SnapshotId.'};Show-SCBrowser $r[0]}
        'Analyze'{
            if(-not $SnapshotId){if($Json){throw 'Для -Json укажите -SnapshotId.'};Show-SCAutoReports $config}
            else{
                $r=@(Get-SCSnapshots $config|Where-Object {$_.SnapshotId -eq $SnapshotId});if($r.Count -ne 1){throw 'Укажите существующий -SnapshotId.'}
                if($Json){$a=New-SCAnalysis $r[0];$destination=Export-SCAnalysis $config $a;$a|ConvertTo-Json -Depth 12}
                else{Show-SCAnalysis $config $r[0] -Refresh:$Refresh}
            }
        }
        'Overview'{
            $r=@(Get-SCSnapshots $config|Where-Object {$_.SnapshotId -eq $SnapshotId});if($r.Count -ne 1){throw 'Укажите существующий -SnapshotId.'}
            Show-SCSummary $r[0];$idx=Open-SCIndex $r[0];try{Show-SCTree $idx}finally{$idx.Dispose()}
        }
        'Compare'{
            $all=@(Get-SCSnapshots $config);$a=@($all|Where-Object {$_.SnapshotId -eq $Before});$b=@($all|Where-Object {$_.SnapshotId -eq $After})
            if($a.Count -ne 1 -or $b.Count -ne 1){throw 'Укажите -Before и -After: идентификаторы из History.'}
            $r=Get-SCDiff $a[0] $b[0];if($Json){$r|ConvertTo-Json -Depth 10}else{Show-SCDiff $r}
        }
    }
}catch{Write-Error $_.Exception.Message;exit 1}finally{Exit-SCWorkspaceLease $storageWriter}
