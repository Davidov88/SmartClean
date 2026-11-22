function Get-SCPolicyRoot($Config) {
    if($Config.PSObject.Properties['PolicyRoot'] -and $Config.PolicyRoot){return [IO.Path]::GetFullPath($Config.PolicyRoot)}
    return Join-Path $script:ProjectRoot 'policy'
}
function Get-SCAliases($Config) {
    $x86=[Environment]::GetFolderPath('ProgramFilesX86');if(-not $x86){$x86=[Environment]::GetFolderPath('ProgramFiles')}
    @{Windows=[Environment]::GetFolderPath('Windows');ProgramFiles=[Environment]::GetFolderPath('ProgramFiles');ProgramFilesX86=$x86;LocalAppData=[Environment]::GetFolderPath('LocalApplicationData');RoamingAppData=[Environment]::GetFolderPath('ApplicationData');UserProfile=[Environment]::GetFolderPath('UserProfile');ResultsRoot=$Config.DataRoot;ProjectRoot=$script:ProjectRoot}
}
function Expand-SCPolicyPath($Config,[string]$Path) {
    if($Path -match '^\{([^{}]+)\}(?=\\|/|$)'){
        $alias=$Matches[1];$aliases=Get-SCAliases $Config
        if(-not $aliases.ContainsKey($alias)){throw "Неизвестный алиас: $alias"}
        $Path=[string]$aliases[$alias]+$Path.Substring($Matches[0].Length)
    }
    if(-not [IO.Path]::IsPathRooted($Path)){throw 'Нужен абсолютный путь или известный начальный алиас.'}
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}
function Get-SCTextHash([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Initialize-SCPolicy($Config) {
    $root=Get-SCPolicyRoot $Config
    foreach($part in @('','hosts','decisions')){[IO.Directory]::CreateDirectory((Join-Path $root $part))|Out-Null}
    $default=Join-Path $root 'defaults.json'
    if(-not(Test-Path -LiteralPath $default)){Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'config\default-policy.json') -Destination $default}
    $preset=Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'config\default-policy.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $current=Get-Content -LiteralPath $default -Raw -Encoding UTF8|ConvertFrom-Json
    if($current.Revision -lt $preset.Revision){
        $paths=@($current.ProtectedPaths|ForEach-Object {$_.Path})
        foreach($rule in $preset.ProtectedPaths){if($paths -notcontains $rule.Path){$current.ProtectedPaths=@($current.ProtectedPaths)+@($rule)}}
        if(-not $current.PSObject.Properties['MaxDiscoveryFiles']){$current|Add-Member NoteProperty MaxDiscoveryFiles $preset.MaxDiscoveryFiles}
        $current.Revision=$preset.Revision;Write-SCJson $default $current
    }
    $hostFile=Join-Path $root ('hosts\'+$Config.HostId+'.json')
    if(-not(Test-Path -LiteralPath $hostFile)){
        Write-SCJson $hostFile ([ordered]@{SchemaVersion=1;Revision=1;HostId=$Config.HostId;ProtectedPaths=@();ScanExclusions=@();CleanupPermissions=@();OrganizationRules=@();Observations=@()})
    }
}
function Get-SCPolicy($Config) {
    Initialize-SCPolicy $Config
    $root=Get-SCPolicyRoot $Config
    $defaultsText=[IO.File]::ReadAllText((Join-Path $root 'defaults.json'))
    $hostText=[IO.File]::ReadAllText((Join-Path $root ('hosts\'+$Config.HostId+'.json')))
    $defaults=$defaultsText|ConvertFrom-Json;$hostPolicy=$hostText|ConvertFrom-Json
    if($defaults.SchemaVersion -ne 1 -or $hostPolicy.SchemaVersion -ne 1 -or $hostPolicy.HostId -ne $Config.HostId){throw 'Неподдерживаемая схема политики или чужой компьютер.'}
    foreach($r in @($defaults.ProtectedPaths)+@($hostPolicy.ProtectedPaths)){if($r.Scope -notin @('Tree','Exact') -or -not $r.Reason){throw 'У защиты должны быть Scope=Tree/Exact и причина.'}}
    foreach($field in @('ProtectedPaths','ScanExclusions','CleanupPermissions','OrganizationRules')){if(-not $defaults.PSObject.Properties[$field] -or -not $hostPolicy.PSObject.Properties[$field]){throw "Политика не содержит $field"}}
    if(-not ('SmartClean.NativeLinks' -as [type])){Add-Type -Path (Join-Path $script:ProjectRoot 'src\NativeLinks.cs')}
    $protected=@(@($defaults.ProtectedPaths)+@($hostPolicy.ProtectedPaths)|ForEach-Object {
        $path=Expand-SCPolicyPath $Config $_.Path
        [pscustomobject]@{Path=$path;Scope=$_.Scope;Reason=$_.Reason}
        if(Test-Path -LiteralPath $path){$link=[SmartClean.NativeLinks]::Read($path);if($link.ResolvedTarget -and [IO.Path]::IsPathRooted($link.ResolvedTarget)){[pscustomobject]@{Path=$link.ResolvedTarget.TrimEnd('\');Scope=$_.Scope;Reason=($_.Reason+' (назначение ссылки)')}}}
    })
    $exclusions=@(@($defaults.ScanExclusions)+@($hostPolicy.ScanExclusions)|ForEach-Object {
        if(-not $_.Reason){throw 'У исключения сканирования должна быть причина.'}
        [pscustomobject]@{Path=(Expand-SCPolicyPath $Config $_.Path);Reason=$_.Reason}
    })
    [pscustomobject]@{SchemaVersion=1;Hash=(Get-SCTextHash ($defaultsText+"`n"+$hostText+"`ncontracts-v2|"+$Config.DataRoot+'|'+(Get-SCPolicyRoot $Config)));Revision=$hostPolicy.Revision;Root=$root;Defaults=$defaults;Host=$hostPolicy;ProtectedPaths=$protected;ScanExclusions=$exclusions;CleanupPermissions=@($hostPolicy.CleanupPermissions);OrganizationRules=@($hostPolicy.OrganizationRules)+@($defaults.OrganizationRules)}
}
function Save-SCHostPolicy($Config,$Value,[int]$ExpectedRevision) {
    Initialize-SCPolicy $Config;$root=Get-SCPolicyRoot $Config
    $lock=New-Object IO.FileStream((Join-Path $root 'policy.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{
        $file=Join-Path $root ('hosts\'+$Config.HostId+'.json')
        $existing=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json
        if($existing.Revision -ne $ExpectedRevision){throw 'Другой чат изменил правила. Обновите их перед сохранением.'}
        if($Value.HostId -ne $Config.HostId -or $Value.SchemaVersion -ne 1){throw 'Некорректный профиль политики.'}
        foreach($key in @('ProtectedPaths','ScanExclusions','CleanupPermissions','OrganizationRules','Observations')){if(-not $Value.PSObject.Properties[$key]){throw ('Не хватает поля политики: '+$key)}}
        foreach($r in $Value.ProtectedPaths){if($r.Scope -notin @('Tree','Exact') -or -not $r.Reason){throw 'Некорректная защита пути.'};$expanded=Expand-SCPolicyPath $Config $r.Path}
        foreach($r in $Value.ScanExclusions){if(-not $r.Reason){throw 'Не указана причина исключения.'};$expanded=Expand-SCPolicyPath $Config $r.Path}
        foreach($r in $Value.OrganizationRules){if(-not $r.Category -or $r.Category -in @('.','..') -or $r.Category -match '[\\/:*?"<>|]'){throw 'Некорректная категория.'};foreach($extension in $r.Extensions){if($extension -notmatch '^\.[a-zA-Z0-9]+$'){throw 'Расширение должно иметь вид .pdf'}}}
        $Value.Revision=$ExpectedRevision+1
        Write-SCJson $file $Value
    }finally{$lock.Dispose()}
    return Get-SCPolicy $Config
}
function Add-SCProtection($Config,[string]$Path,[string]$Reason,[ValidateSet('Tree','Exact')][string]$Scope='Tree') {
    $p=Get-SCPolicy $Config;$full=Expand-SCPolicyPath $Config $Path
    if(-not $Reason){throw 'Укажите причину защиты.'}
    $p.Host.ProtectedPaths=@($p.Host.ProtectedPaths)+@([pscustomobject]@{Path=$full;Scope=$Scope;Reason=$Reason})
    Save-SCHostPolicy $Config $p.Host $p.Revision
}
function Add-SCScanExclusion($Config,[string]$Path,[string]$Reason) {
    $p=Get-SCPolicy $Config;$full=Expand-SCPolicyPath $Config $Path
    if(-not $Reason){throw 'Укажите причину исключения.'}
    $p.Host.ScanExclusions=@($p.Host.ScanExclusions)+@([pscustomobject]@{Path=$full;Reason=$Reason})
    Save-SCHostPolicy $Config $p.Host $p.Revision
}
function Test-SCRepeatPermission($Policy,$Operations) {
    if(-not @($Operations).Count){return $false}
    foreach($op in $Operations){
        if($op.Action -ne 'QuarantineFile' -or -not $op.RuleId){return $false}
        $matches=@($Policy.CleanupPermissions|Where-Object {$_.RuleId -eq $op.RuleId -and $_.RuleVersion -eq $op.RuleVersion -and $_.Scope.TrimEnd('\') -eq $op.RuleScope.TrimEnd('\') -and $_.Repeat -eq $true -and (Test-SCExpiry $_.ExpiresUtc)})
        if(-not $matches.Count){return $false}
    }
    return $true
}
function Grant-SCRepeatPermission($Config,$Candidates,[switch]$Confirmed) {
    if(-not $Confirmed){throw 'Нужно явное согласие на конкретные правила и пути.'}
    $policy=Get-SCPolicy $Config;$permissions=@($policy.Host.CleanupPermissions);$count=0
    foreach($candidate in $Candidates){
        if(-not $candidate.Selected){continue}
        $rule=@(Get-SCReviewRules|Where-Object {$_.Id -eq $candidate.RuleId})
        if($rule.Count -ne 1 -or $candidate.RuleId -eq 'spotify-data' -or $candidate.Path -notmatch $rule[0].Pattern){throw 'Для этой категории повторное разрешение не поддерживается.'}
        $scope=Assert-SCMutablePath $Config $policy $candidate.Path -AllowExactContainer
        $permissions=@($permissions|Where-Object {-not($_.RuleId -eq $candidate.RuleId -and $_.Scope -eq $scope)})
        $permissions+=@([pscustomobject]@{RuleId=$candidate.RuleId;RuleVersion=1;Scope=$scope;Repeat=$true;GrantedUtc=[DateTime]::UtcNow.ToString('o');ExpiresUtc=[DateTime]::UtcNow.AddDays(30).ToString('o');Source='Explicit UI/CLI confirmation';Consequence=$rule[0].Consequence})
        $count++
    }
    if(-not $count){throw 'Отметьте конкретные категории.'}
    $policy.Host.CleanupPermissions=$permissions
    Save-SCHostPolicy $Config $policy.Host $policy.Revision
}
function Assert-SCMutablePath($Config,$Policy,[string]$Path,[switch]$AllowExactContainer) {
    if($Path -notmatch '^[A-Za-z]:\\'){throw 'Изменения поддерживаются только на локальных томах с буквой.'}
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    if($full.Length -le 3){throw 'Изменение корня тома запрещено.'}
    foreach($protected in $Policy.ProtectedPaths){
        if(($full -eq $protected.Path -and -not ($AllowExactContainer -and $protected.Scope -eq 'Exact')) -or ($protected.Scope -eq 'Tree' -and $full.StartsWith($protected.Path+'\',[StringComparison]::OrdinalIgnoreCase))){throw ('Защищённый путь: '+$full+'. '+$protected.Reason)}
    }
    $ancestor=$full
    while($ancestor){
        if(Test-Path -LiteralPath $ancestor){$item=Get-Item -LiteralPath $ancestor -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw ('Ссылка в пути изменения: '+$ancestor+'. Выберите фактический путь.')}}
        $parent=[IO.Path]::GetDirectoryName($ancestor);if($parent -eq $ancestor){break};$ancestor=$parent
    }
    return $full
}

function Get-SCRepeatBindings($Policy,$Operations) {
    if(-not (Test-SCRepeatPermission $Policy $Operations)){return @()}
    foreach($op in $Operations){
        $match=@($Policy.CleanupPermissions|Where-Object {$_.RuleId -eq $op.RuleId -and $_.RuleVersion -eq $op.RuleVersion -and $_.Scope.TrimEnd('\') -eq $op.RuleScope.TrimEnd('\') -and $_.Repeat -and (Test-SCExpiry $_.ExpiresUtc)}|Sort-Object ExpiresUtc|Select-Object -First 1)
        $match[0]
    }
}
