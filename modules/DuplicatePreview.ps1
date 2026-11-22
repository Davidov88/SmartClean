function Get-SCDuplicatePreview($Config,$Request) {
    $page=Get-SCDuplicateCopies $Config $Request.RowsFile $Request.GroupId ([long]$Request.Offset) ([int]$Request.Page)
    $copy=@($page.Rows|Where-Object {$_.Path -eq $Request.Path}|Select-Object -First 1)
    if(-not $copy.Count){throw 'Выберите копию из открытой страницы группы.'}
    $path=[IO.Path]::GetFullPath($copy[0].Path)
    if([IO.Path]::GetExtension($path) -notin @('.jpg','.jpeg','.png','.bmp','.gif','.tif','.tiff')){
        throw 'Предпросмотр доступен для JPEG, PNG, BMP, GIF и TIFF.'
    }
    Assert-SCOwnPath $path $path
    $item=Get-Item -LiteralPath $path -Force
    if($item.PSIsContainer -or (([uint32]$item.Attributes -band 0x00441400) -ne 0) -or $item.Length -gt 16MB){
        throw 'Нужен доступный локальный файл размером до 16 MiB.'
    }
    Add-Type -AssemblyName WindowsBase,PresentationCore
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if($stream.Length -gt 16MB){throw 'Файл изменился и превышает лимит предпросмотра.'}
        $decoder=[Windows.Media.Imaging.BitmapDecoder]::Create($stream,[Windows.Media.Imaging.BitmapCreateOptions]::DelayCreation,[Windows.Media.Imaging.BitmapCacheOption]::OnDemand)
        $frame=$decoder.Frames[0]
        $width=$frame.PixelWidth;$height=$frame.PixelHeight
        if($width -lt 1 -or $height -lt 1 -or [long]$width*$height -gt 24000000){throw 'Изображение превышает лимит в 24 мегапикселя.'}
        Test-SCCancel ''
        $stream.Position=0
        $bitmap=New-Object Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.StreamSource=$stream
        if($width -ge $height){$bitmap.DecodePixelWidth=[Math]::Min(480,$width)}
        else{$bitmap.DecodePixelHeight=[Math]::Min(480,$height)}
        $bitmap.EndInit()
        Test-SCCancel ''
        $encoder=New-Object Windows.Media.Imaging.JpegBitmapEncoder
        $encoder.QualityLevel=82
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $output=New-Object IO.MemoryStream
        try{
            $encoder.Save($output)
            [pscustomobject]@{Path=$path;Width=$width;Height=$height;Jpeg=[Convert]::ToBase64String($output.ToArray())}
        }finally{$output.Dispose()}
    }finally{$stream.Dispose()}
}
