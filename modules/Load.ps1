foreach($module in @('Core','Jobs','Storage','Inventory','Policy','Scanner','Reports','Analysis','Operations','Workflows','Menu')){. (Join-Path $PSScriptRoot ($module+'.ps1'))}
