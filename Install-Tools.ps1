#requires -Version 5.1
[CmdletBinding()]
param([switch]$IncludeBenchmarkTools)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$lock=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'tools.lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$download=Join-Path $PSScriptRoot 'tools\downloads'
[IO.Directory]::CreateDirectory($download)|Out-Null
$names=@('windirstat');if($IncludeBenchmarkTools){$names+='gdu'}
foreach($name in $names){
    $tool=$lock.$name;$archive=Join-Path $download ($name+'.zip')
    $valid=(Test-Path -LiteralPath $archive) -and ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -eq $tool.archiveSha256)
    if(-not $valid){Invoke-WebRequest -UseBasicParsing -Uri $tool.archiveUrl -OutFile $archive}
    if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $tool.archiveSha256){throw "SHA-256 mismatch: $name"}
    $destination=Join-Path $PSScriptRoot ('tools\'+$name)
    Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force
    $licenseUrl=if($name -eq 'windirstat'){'https://raw.githubusercontent.com/windirstat/windirstat/release/v2.9.3/windirstat/res/license.txt'}else{'https://raw.githubusercontent.com/dundee/gdu/v5.38.0/LICENSE.md'}
    Invoke-WebRequest -UseBasicParsing -Uri $licenseUrl -OutFile (Join-Path $destination 'LICENSE.txt')
    [IO.File]::WriteAllText((Join-Path $destination 'SOURCE.txt'),$tool.sourceUrl,[Text.Encoding]::UTF8)
    Write-Host ("Готово: $name $($tool.version), архив SHA-256 проверен.")
}
Write-Host 'Запуск: Start-SmartClean.cmd. Системная установка и изменение PATH не требуются.'
