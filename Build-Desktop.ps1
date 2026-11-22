#requires -Version 5.1
$ErrorActionPreference='Stop'
$framework=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $framework)){$framework=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
$automation=[System.Management.Automation.PowerShell].Assembly.Location
& $framework /nologo /target:winexe /platform:anycpu ('/out:'+(Join-Path $PSScriptRoot 'SmartClean.exe')) ('/reference:'+$automation) /reference:System.Windows.Forms.dll (Join-Path $PSScriptRoot 'src\DesktopHost.cs')
if($LASTEXITCODE -ne 0){throw 'Не удалось собрать нативный запускатель.'}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'SmartClean.exe.config'),'<configuration><startup useLegacyV2RuntimeActivationPolicy="true"><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.8"/></startup></configuration>')
Write-Host 'SmartClean.exe готов. Браузер и WebView не используются.'
