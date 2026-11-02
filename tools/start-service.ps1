param(
    [Parameter(Mandatory=$true)][string]$PythonExe,
    [Parameter(Mandatory=$true)][string]$DataDir,
    [int]$Port = 8765,
    [string]$BrowserExe = ''
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) { throw 'Python executable not found' }
if ($DataDir.Contains('"')) { throw 'Invalid data directory' }
$workspaceDir = Split-Path -Parent $PSScriptRoot
$sha = [Security.Cryptography.SHA256]::Create()
$suffix = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($DataDir.ToLowerInvariant())))).Replace('-','').Substring(0,12)
$taskName = $(if ($BrowserExe) { 'SmartClean-Window-' } else { 'SmartClean-Service-' }) + $suffix
$scheduler = New-Object -ComObject 'Schedule.Service'
$scheduler.Connect()
$folder = $scheduler.GetFolder('\')
$definition = $scheduler.NewTask(0)
$definition.RegistrationInfo.Description = 'SmartClean component. On-demand only; no time or logon triggers. Independent of the launcher and Codex.'
$definition.Principal.UserId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$definition.Principal.LogonType = 3
$definition.Principal.RunLevel = 0
$definition.Settings.Enabled = $true
$definition.Settings.AllowDemandStart = $true
$definition.Settings.DisallowStartIfOnBatteries = $false
$definition.Settings.StopIfGoingOnBatteries = $false
$definition.Settings.ExecutionTimeLimit = 'PT0S'
$definition.Settings.MultipleInstances = 2
$action = $definition.Actions.Create(0)
if ($BrowserExe) {
    if (-not (Test-Path -LiteralPath $BrowserExe -PathType Leaf)) { throw 'Browser executable not found' }
    $action.Path = $BrowserExe
    $action.Arguments = '--app=http://127.0.0.1:' + $Port + ' --user-data-dir="' + $DataDir + '\desktop-profile" --no-first-run --no-default-browser-check --window-size=1440,1000'
} else {
    $action.Path = $PythonExe
    $action.Arguments = '-m smartclean --data-dir "' + $DataDir + '" --port ' + $Port
}
$action.WorkingDirectory = $workspaceDir
$task = $folder.RegisterTaskDefinition($taskName, $definition, 6, $definition.Principal.UserId, $null, 3)
$null = $task.Run($null)
Write-Output $taskName
