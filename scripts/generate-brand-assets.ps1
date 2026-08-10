param(
    [string]$SourceLogo,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SourceLogo)) {
    $LogoCandidates = @(Get-ChildItem -LiteralPath $Root -Filter 'logo.png' -File -Recurse | Where-Object {
        $_.FullName -notmatch '[\\/]build[\\/]' -and
        $_.FullName -notmatch '[\\/]brand-assets[\\/]'
    })
    if ($LogoCandidates.Count -eq 0) {
        throw "No logo.png was found under project root: $Root"
    }
    $SourceLogo = $LogoCandidates[0].FullName
}
$SourceLogo = (Resolve-Path -LiteralPath $SourceLogo).Path

Add-Type -AssemblyName System.Drawing

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function New-SquarePng {
    param(
        [Parameter(Mandatory = $true)][System.Drawing.Image]$Source,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Size,
        [double]$Scale = 0.82,
        [System.Drawing.Color]$Background = [System.Drawing.Color]::Transparent
    )

    Ensure-Directory (Split-Path -Parent $Path)
    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear($Background)
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

            $box = [Math]::Max(1, [int][Math]::Round($Size * $Scale))
            $ratio = [Math]::Min($box / [double]$Source.Width, $box / [double]$Source.Height)
            $width = [Math]::Max(1, [int][Math]::Round($Source.Width * $ratio))
            $height = [Math]::Max(1, [int][Math]::Round($Source.Height * $ratio))
            $x = [int](($Size - $width) / 2)
            $y = [int](($Size - $height) / 2)
            $target = New-Object System.Drawing.Rectangle($x, $y, $width, $height)
            $graphics.DrawImage($Source, $target)
        }
        finally {
            $graphics.Dispose()
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
}

function New-PngBytes {
    param(
        [Parameter(Mandatory = $true)][System.Drawing.Image]$Source,
        [Parameter(Mandatory = $true)][int]$Size,
        [double]$Scale = 0.86
    )

    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $box = [Math]::Max(1, [int][Math]::Round($Size * $Scale))
            $ratio = [Math]::Min($box / [double]$Source.Width, $box / [double]$Source.Height)
            $width = [Math]::Max(1, [int][Math]::Round($Source.Width * $ratio))
            $height = [Math]::Max(1, [int][Math]::Round($Source.Height * $ratio))
            $graphics.DrawImage(
                $Source,
                (New-Object System.Drawing.Rectangle(
                    [int](($Size - $width) / 2),
                    [int](($Size - $height) / 2),
                    $width,
                    $height
                ))
            )
        }
        finally {
            $graphics.Dispose()
        }
        $stream = New-Object System.IO.MemoryStream
        try {
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            return $stream.ToArray()
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $bitmap.Dispose()
    }
}

function New-PngIco {
    param(
        [Parameter(Mandatory = $true)][System.Drawing.Image]$Source,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Ensure-Directory (Split-Path -Parent $Path)
    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $images = @()
    foreach ($size in $sizes) {
        $images += ,(New-PngBytes -Source $Source -Size $size -Scale 0.88)
    }

    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($stream)
    try {
        $writer.Write([UInt16]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]$sizes.Count)
        $offset = 6 + (16 * $sizes.Count)
        for ($index = 0; $index -lt $sizes.Count; $index++) {
            $size = $sizes[$index]
            $bytes = [byte[]]$images[$index]
            $writer.Write([byte]$(if ($size -ge 256) { 0 } else { $size }))
            $writer.Write([byte]$(if ($size -ge 256) { 0 } else { $size }))
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]32)
            $writer.Write([UInt32]$bytes.Length)
            $writer.Write([UInt32]$offset)
            $offset += $bytes.Length
        }
        foreach ($bytes in $images) {
            $writer.Write([byte[]]$bytes)
        }
        $writer.Flush()
        [System.IO.File]::WriteAllBytes($Path, $stream.ToArray())
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function New-BrandPreview {
    param(
        [Parameter(Mandatory = $true)][System.Drawing.Image]$Source,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Ensure-Directory (Split-Path -Parent $Path)
    $bitmap = New-Object System.Drawing.Bitmap(1200, 760, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $g.Clear([System.Drawing.Color]::FromArgb(245, 246, 248))
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $titleFont = New-Object System.Drawing.Font('Segoe UI', 34, [System.Drawing.FontStyle]::Bold)
            $labelFont = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Regular)
            try {
                $g.DrawString('DD Brand Asset Baseline', $titleFont, [System.Drawing.Brushes]::Black, 64, 48)
                $g.DrawString('Generated from the project logo.png source of truth', $labelFont, [System.Drawing.Brushes]::DimGray, 66, 100)
                foreach ($entry in @(
                    @{ X = 70;  Y = 180; S = 220; Label = 'Launcher / desktop' },
                    @{ X = 390; Y = 205; S = 170; Label = 'Compact' },
                    @{ X = 685; Y = 235; S = 110; Label = 'Notification / favicon' }
                )) {
                    $x = [int]$entry.X
                    $y = [int]$entry.Y
                    $s = [int]$entry.S
                    $card = [System.Drawing.Rectangle]::new(($x - 24), ($y - 24), ($s + 48), ($s + 92))
                    $imageRect = [System.Drawing.Rectangle]::new($x, $y, $s, $s)
                    $g.FillRectangle([System.Drawing.Brushes]::White, $card)
                    $g.DrawImage($Source, $imageRect)
                    $g.DrawString([string]$entry.Label, $labelFont, [System.Drawing.Brushes]::DimGray, [single]($x - 8), [single]($y + $s + 22))
                }
                $g.DrawString('Android · Windows · Web · Splash', $labelFont, [System.Drawing.Brushes]::DimGray, 70, 650)
            }
            finally {
                $titleFont.Dispose()
                $labelFont.Dispose()
            }
        }
        finally {
            $g.Dispose()
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
}

$source = [System.Drawing.Image]::FromFile($SourceLogo)
try {
    $androidRes = Join-Path $Root 'clients\app\android\app\src\main\res'
    $launcher = @{
        'mipmap-mdpi' = 48
        'mipmap-hdpi' = 72
        'mipmap-xhdpi' = 96
        'mipmap-xxhdpi' = 144
        'mipmap-xxxhdpi' = 192
    }
    foreach ($entry in $launcher.GetEnumerator()) {
        $dir = Join-Path $androidRes $entry.Key
        New-SquarePng -Source $source -Path (Join-Path $dir 'ic_launcher.png') -Size $entry.Value -Scale 0.82 -Background ([System.Drawing.Color]::White)
        New-SquarePng -Source $source -Path (Join-Path $dir 'ic_launcher_round.png') -Size $entry.Value -Scale 0.80 -Background ([System.Drawing.Color]::White)
    }

    $splash = @{
        'drawable-mdpi' = 96
        'drawable-hdpi' = 144
        'drawable-xhdpi' = 192
        'drawable-xxhdpi' = 288
        'drawable-xxxhdpi' = 384
    }
    foreach ($entry in $splash.GetEnumerator()) {
        New-SquarePng -Source $source -Path (Join-Path (Join-Path $androidRes $entry.Key) 'dd_splash_logo.png') -Size $entry.Value -Scale 0.92
    }
    New-SquarePng -Source $source -Path (Join-Path $androidRes 'drawable-nodpi\dd_launcher_foreground.png') -Size 432 -Scale 0.62

    $windowsIco = Join-Path $Root 'clients\app\windows\runner\resources\app_icon.ico'
    New-PngIco -Source $source -Path $windowsIco

    $webRoot = Join-Path $Root 'clients\app\web'
    New-SquarePng -Source $source -Path (Join-Path $webRoot 'icons\Icon-192.png') -Size 192 -Scale 0.86 -Background ([System.Drawing.Color]::White)
    New-SquarePng -Source $source -Path (Join-Path $webRoot 'icons\Icon-512.png') -Size 512 -Scale 0.86 -Background ([System.Drawing.Color]::White)
    New-SquarePng -Source $source -Path (Join-Path $webRoot 'favicon.png') -Size 64 -Scale 0.90
    New-PngIco -Source $source -Path (Join-Path $webRoot 'favicon.ico')

    $designDir = Split-Path -Parent $SourceLogo
    $brandDir = Join-Path $designDir 'brand-assets'
    Ensure-Directory $brandDir
    Copy-Item -LiteralPath $SourceLogo -Destination (Join-Path $brandDir 'DD-logo-master.png') -Force
    New-SquarePng -Source $source -Path (Join-Path $brandDir 'DD-icon-1024.png') -Size 1024 -Scale 0.86 -Background ([System.Drawing.Color]::White)
    New-SquarePng -Source $source -Path (Join-Path $brandDir 'DD-icon-transparent-1024.png') -Size 1024 -Scale 0.86
    New-PngIco -Source $source -Path (Join-Path $brandDir 'DD-icon.ico')
    New-BrandPreview -Source $source -Path (Join-Path $brandDir 'DD-brand-preview.png')

    Write-Host 'DD brand assets generated from:' $SourceLogo
}
finally {
    $source.Dispose()
}
