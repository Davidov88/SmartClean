#requires -Version 5.1
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
foreach($module in @('Core','Inventory','Scanner','Reports')){. (Join-Path $project ('modules\'+$module+'.ps1'))}
$config=Get-SCConfig
$text=New-Object Text.StringBuilder
[void]$text.AppendLine('# Первые замеры SmartClean: C: и D:')
[void]$text.AppendLine('')
[void]$text.AppendLine('4 ноября 2026. Только чтение. Полнота доступа не подтверждена движком; ссылки не раскрывались. Размеры ниже — allocation по путям, вложенные строки нельзя складывать. Источник — сохранённые индексы, повторного обхода нет.')
$stats=New-Object 'Collections.Generic.List[object]'
foreach($root in @('C:\','D:\')){
    $m=@(Get-SCSnapshots $config | Where-Object {$_.Root -eq $root -and $_.HasIndex})[0]
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $idx=Open-SCIndex $m
    try{
        $top=$idx.Children(0,10,'allocated');$timer.Stop()
        [void]$text.AppendLine('')
        [void]$text.AppendLine('## '+$root)
        [void]$text.AppendLine(('Замер {0}: {1:N0} записей; {2} с; sampled peak сканера {3} MiB. Загрузка индекса и top-10: {4:N1} ms.' -f $m.SnapshotId,$m.Totals.Nodes,$m.Measurements.Seconds,$m.Measurements.PeakSampledMiB,$timer.Elapsed.TotalMilliseconds))
        [void]$text.AppendLine(('Сумма allocation по путям: {0}; без повторов ID: {1}.' -f (Format-SCBytes $m.Totals.AllocatedBytes),(Format-SCBytes $m.Totals.UniqueAllocatedBytes)))
        [void]$text.AppendLine('')
        foreach($n in $top){
            [void]$text.AppendLine(('- {0}: {1}' -f $n.Path,(Format-SCBytes $n.AllocatedBytes)))
            if($n.Kind -eq 1){foreach($child in $idx.Children($n.Id,4,'allocated')){[void]$text.AppendLine(('  - {0}: {1}' -f $child.Path,(Format-SCBytes $child.AllocatedBytes)))}}
        }
        $stats.Add([pscustomobject]@{Root=$root;Id=$m.SnapshotId;LoadAndTopMilliseconds=$timer.Elapsed.TotalMilliseconds;Top=$top})
    }finally{$idx.Dispose()}
}
[void]$text.AppendLine('')
[void]$text.AppendLine('Это карта объёма, не список мусора. Кандидаты на очистку требуют отдельного правила и объяснения. Для анализа роста нужен следующий сопоставимый замер.')
[IO.File]::WriteAllText((Join-Path $project 'data\BASELINE.md'),$text.ToString(),$script:Utf8)
Write-SCJson (Join-Path $project 'data\baseline-top.json') $stats.ToArray()
$text.ToString()
