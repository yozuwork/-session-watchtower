param(
    [string]$SourcePng,
    [string]$OutputIco
)

Add-Type -AssemblyName System.Drawing

$sizes = @(16, 32, 48, 64, 128, 256)

$src = [System.Drawing.Image]::FromFile($SourcePng)
$side = [Math]::Max($src.Width, $src.Height)

# 先貼到一張正方形透明畫布置中,避免長寬比不同造成變形
$square = New-Object System.Drawing.Bitmap($side, $side)
$gSquare = [System.Drawing.Graphics]::FromImage($square)
$gSquare.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$gSquare.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$offsetX = [int](($side - $src.Width) / 2)
$offsetY = [int](($side - $src.Height) / 2)
$gSquare.DrawImage($src, $offsetX, $offsetY, $src.Width, $src.Height)
$gSquare.Dispose()
$src.Dispose()

$pngBytesList = @()
foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.DrawImage($square, 0, 0, $s, $s)
    $g.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngBytesList += , $ms.ToArray()
    $ms.Dispose()
    $bmp.Dispose()
}
$square.Dispose()

# 手動組 .ico:ICONDIR + N 個 ICONDIRENTRY + 每張圖的 PNG bytes(Vista 以後的 icon 都支援直接內嵌 PNG)
$fs = New-Object System.IO.FileStream($OutputIco, [System.IO.FileMode]::Create)
$bw = New-Object System.IO.BinaryWriter($fs)

$count = $sizes.Count
$bw.Write([UInt16]0)      # reserved
$bw.Write([UInt16]1)      # type = icon
$bw.Write([UInt16]$count)

$headerSize = 6 + (16 * $count)
$offset = $headerSize
for ($i = 0; $i -lt $count; $i++) {
    $s = $sizes[$i]
    $b = if ($s -ge 256) { 0 } else { $s }
    $bw.Write([Byte]$b)          # width
    $bw.Write([Byte]$b)          # height
    $bw.Write([Byte]0)           # color count
    $bw.Write([Byte]0)           # reserved
    $bw.Write([UInt16]1)         # planes
    $bw.Write([UInt16]32)        # bit count
    $bw.Write([UInt32]$pngBytesList[$i].Length)
    $bw.Write([UInt32]$offset)
    $offset += $pngBytesList[$i].Length
}
foreach ($bytes in $pngBytesList) {
    $bw.Write($bytes)
}
$bw.Flush()
$bw.Close()
$fs.Close()

Write-Output "Icon written: $OutputIco"
