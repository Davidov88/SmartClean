#requires -Version 5.1
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent;. (Join-Path $project 'modules\Load.ps1')
$root=Join-Path $PSScriptRoot ('features\'+[Guid]::NewGuid().ToString('N'));$input=Join-Path $root 'input';[IO.Directory]::CreateDirectory($input)|Out-Null
for($i=0;$i -lt 100;$i++){[IO.File]::WriteAllText((Join-Path $input ($i.ToString('d3')+'.txt')),('payload-'+($i%50)))}
$c=Get-SCConfig;$job=Join-Path $root 'job';[IO.Directory]::CreateDirectory($job)|Out-Null
$request=Join-Path $job 'request.json';Write-SCJson $request @{Action='Duplicates';Arguments=@{Roots=@($input)};DataRoot=(Join-Path $root 'data');PolicyRoot=(Join-Path $root 'policy');Isolated=$true}
$exe=Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
$args='-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-SCArgument (Join-Path $project 'Worker.ps1'))+' -JobFile '+(ConvertTo-SCArgument $request)
$p=Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden -PassThru;$handle=$p.Handle;$clock=[Diagnostics.Stopwatch]::StartNew();$reads=0
while(-not $p.HasExited){
    if($clock.Elapsed.TotalSeconds -gt 60){$p.Kill();throw 'Worker timeout'}
    $progress=Join-Path $job 'progress.json'
    if(Test-Path -LiteralPath $progress){$text=Get-Content -LiteralPath $progress -Raw -Encoding UTF8;$v=$text|ConvertFrom-Json;$reads++}
    Start-Sleep -Milliseconds 10
}
$p.WaitForExit();$status=Get-Content -LiteralPath (Join-Path $job 'status.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($status.State -ne 'Completed'){throw ($status|ConvertTo-Json)}
$result=Get-Content -LiteralPath (Join-Path $job 'result.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($result.Rows.Count -ne 100 -or $reads -lt 1){throw 'Invalid worker duplicate result / no concurrent progress observations'}
$job2=Join-Path $root 'cancel-job';[IO.Directory]::CreateDirectory($job2)|Out-Null
Write-SCJson (Join-Path $job2 'request.json') @{Action='Duplicates';Arguments=@{Roots=@($input)};DataRoot=(Join-Path $root 'data');PolicyRoot=(Join-Path $root 'policy');Isolated=$true}
[IO.File]::WriteAllText((Join-Path $job2 'cancel.flag'),'cancel')
$args='-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-SCArgument (Join-Path $project 'Worker.ps1'))+' -JobFile '+(ConvertTo-SCArgument (Join-Path $job2 'request.json'))
$p=Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden -PassThru;$handle=$p.Handle
if(-not $p.WaitForExit(30000)){$p.Kill();throw 'Cancel worker timeout'}
$state=Get-Content -LiteralPath (Join-Path $job2 'status.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($state.State -ne 'Cancelled'){throw 'Cancellation was not classified correctly'}
$report=@{Passed=3;Checks=@('Real duplicate worker returns 100 verified matching paths','Progress JSON remains readable during concurrent updates','Cancellation has explicit non-error state');ConcurrentProgressReads=$reads;Utc=[DateTime]::UtcNow.ToString('o')}
Write-SCJson (Join-Path $root 'verification.json') $report;$report|ConvertTo-Json -Depth 6
