#requires -Version 5.1
[CmdletBinding()]
param([int]$SmallFiles=12000)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$runRoot=Join-Path $PSScriptRoot ('runs\'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
$fixture=Join-Path $runRoot 'fixture'
$outside=Join-Path $runRoot 'outside'
New-Item -ItemType Directory -Path $fixture,$outside -Force | Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
$block=New-Object byte[] 4096
for($i=0;$i -lt $SmallFiles;$i++) {
    $dir=Join-Path $fixture ('small\{0:d3}' -f ($i % 80))
    if(-not [IO.Directory]::Exists($dir)){[IO.Directory]::CreateDirectory($dir)|Out-Null}
    [IO.File]::WriteAllBytes((Join-Path $dir ('{0:d6}.bin' -f $i)),$block)
}
$deep=Join-Path $fixture 'Русские имена и пробелы\a\b\c\d'
[IO.Directory]::CreateDirectory($deep)|Out-Null
[IO.File]::WriteAllBytes((Join-Path $deep 'данные.bin'),(New-Object byte[] 7777))
[IO.Directory]::CreateDirectory((Join-Path $fixture 'empty'))|Out-Null
[IO.File]::WriteAllBytes((Join-Path $fixture 'original.bin'),(New-Object byte[] 1048576))
New-Item -ItemType HardLink -Path (Join-Path $fixture 'hardlink.bin') -Target (Join-Path $fixture 'original.bin') | Out-Null
$sparse=Join-Path $fixture 'sparse.bin'
[IO.File]::WriteAllBytes($sparse,(New-Object byte[] 0))
& fsutil.exe sparse setflag $sparse | Out-Null
$stream=[IO.File]::OpenWrite($sparse)
try{$stream.SetLength(67108864)}finally{$stream.Dispose()}
[IO.File]::WriteAllBytes((Join-Path $outside 'must-not-count.bin'),(New-Object byte[] 2097152))
New-Item -ItemType Junction -Path (Join-Path $fixture 'junction-outside') -Target $outside | Out-Null
New-Item -ItemType Junction -Path (Join-Path $fixture 'junction-cycle') -Target $fixture | Out-Null
[IO.File]::WriteAllText((Join-Path $runRoot 'gdu.yaml'),'{}',$utf8)
$ini=@'
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
UseFastScanEngine=1
ScanningThreads=4
'@
$wds=Join-Path $project 'tools\windirstat\x64\WinDirStat.exe'
[IO.File]::WriteAllText([IO.Path]::ChangeExtension($wds,'ini'),$ini,[Text.Encoding]::Unicode)
function Measure-Engine($name,$exe,$arguments,$output,$cancel) {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $p=Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runRoot ($name+'.stdout.log')) -RedirectStandardError (Join-Path $runRoot ($name+'.stderr.log'))
    $handle=$p.Handle
    $peak=0L;$hadWindow=$false;$cancelMs=$null;$cancelled=$false
    while(-not $p.HasExited){
        $p.Refresh();$peak=[Math]::Max($peak,$p.WorkingSet64)
        if($p.MainWindowHandle -ne [IntPtr]::Zero){$hadWindow=$true}
        if(($cancel -and $clock.ElapsedMilliseconds -ge 100) -or $clock.Elapsed.TotalSeconds -gt 90){
            $cancelClock=[Diagnostics.Stopwatch]::StartNew();$p.Kill();$p.WaitForExit();$cancelMs=$cancelClock.Elapsed.TotalMilliseconds;$cancelled=$true;break
        }
        Start-Sleep -Milliseconds 10
    }
    $p.WaitForExit();$clock.Stop()
    [pscustomobject]@{Engine=$name;Seconds=[Math]::Round($clock.Elapsed.TotalSeconds,3);PeakSampledMiB=[Math]::Round($peak/1MB,2);ExitCode=$p.ExitCode;WindowObserved=$hadWindow;Cancelled=$cancelled;CancelMilliseconds=$cancelMs;OutputExists=(Test-Path -LiteralPath $output);OutputBytes=$(if(Test-Path -LiteralPath $output){(Get-Item -LiteralPath $output).Length}else{0})}
}
$gdu=Join-Path $project 'tools\gdu\gdu_windows_amd64.exe'
$results=@()
foreach($round in 1,2){
    $out=Join-Path $runRoot "gdu-$round.json"
    $args='--config-file "{0}" --no-delete --no-spawn-shell --no-view-file --no-progress --no-color --sequential -o "{1}" -- "{2}"' -f (Join-Path $runRoot 'gdu.yaml'),$out,$fixture
    $results+=Measure-Engine "gdu-$round" $gdu $args $out $false
    $out=Join-Path $runRoot "windirstat-$round.json"
    $args='/SaveTo "{0}" "{1}"' -f $out,$fixture
    $results+=Measure-Engine "windirstat-$round" $wds $args $out $false
}
foreach($name in @('gdu','windirstat')){
    $out=Join-Path $runRoot ($name+'-cancel.json')
    if($name -eq 'gdu'){$exe=$gdu;$args='--config-file "{0}" --no-delete --no-spawn-shell --no-view-file --no-progress --sequential -o "{1}" -- "{2}"' -f (Join-Path $runRoot 'gdu.yaml'),$out,$fixture}
    else{$exe=$wds;$args='/SaveTo "{0}" "{1}"' -f $out,$fixture}
    $results+=Measure-Engine ($name+'-cancel') $exe $args $out $true
}
$report=[pscustomobject]@{CreatedUtc=[DateTime]::UtcNow.ToString('o');Fixture=$fixture;SmallFiles=$SmallFiles;ExpectedPathLogicalBytes=($SmallFiles*4096L+7777L+2097152L+67108864L);ExpectedUniqueFileLogicalBytes=($SmallFiles*4096L+7777L+1048576L+67108864L);Notes=@('First vs repeat, not cold-cache benchmark; no cache flush.','Peak is sampled working set, not an exact OS peak.','Cancellation uses process termination; no promise of partial export/resume.');Measurements=$results}
[IO.File]::WriteAllText((Join-Path $runRoot 'benchmark.json'),($report|ConvertTo-Json -Depth 8),$utf8)
$report | ConvertTo-Json -Depth 8
