Set-StrictMode -Version Latest

function Get-EOPropertyValue {
    param(
        [AllowNull()] $Object,
        [Parameter(Mandatory)] [string] $Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function ConvertTo-EODouble {
    param($Value, [double] $Default = 0.0)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value) -or $Value -eq 'N/A') { return $Default }
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $Default
}

function ConvertTo-EOInt64 {
    param($Value, [long] $Default = 0)
    if ($null -eq $Value -or $Value -eq 'N/A') { return $Default }
    $parsed = [long]0
    if ([long]::TryParse([string]$Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $Default
}

function ConvertFrom-EORational {
    param($Value)
    if ($null -eq $Value) { return 0.0 }
    $text = [string]$Value
    if ($text -match '^(-?\d+(?:\.\d+)?)/(-?\d+(?:\.\d+)?)$') {
        $numerator = ConvertTo-EODouble $Matches[1]
        $denominator = ConvertTo-EODouble $Matches[2]
        if ([math]::Abs($denominator) -lt 1e-12) { return 0.0 }
        return $numerator / $denominator
    }
    return ConvertTo-EODouble $text
}

function Get-EOBitDepth {
    param([string] $PixelFormat)
    if (-not $PixelFormat) { return 0 }
    if ($PixelFormat -match 'p0?(9|10|12|14|16)(?:le|be)?$') {
        return [int]$Matches[1]
    }
    if ($PixelFormat -match '(?:gray|gbrp|yuva?\d+p)(9|10|12|14|16)(?:le|be)?$') {
        return [int]$Matches[1]
    }
    return 8
}

function ConvertTo-EODisposition {
    param($Disposition)
    [pscustomobject]@{
        Default         = [int](Get-EOPropertyValue $Disposition 'default' 0)
        Forced          = [int](Get-EOPropertyValue $Disposition 'forced' 0)
        AttachedPic     = [int](Get-EOPropertyValue $Disposition 'attached_pic' 0)
        HearingImpaired = [int](Get-EOPropertyValue $Disposition 'hearing_impaired' 0)
        VisualImpaired  = [int](Get-EOPropertyValue $Disposition 'visual_impaired' 0)
        Original        = [int](Get-EOPropertyValue $Disposition 'original' 0)
        Commentary      = [int](Get-EOPropertyValue $Disposition 'comment' 0)
    }
}

function Get-EORotation {
    param($Stream)
    $tags = Get-EOPropertyValue $Stream 'tags'
    $tagRotate = Get-EOPropertyValue $tags 'rotate'
    if ($null -ne $tagRotate) { return [int](ConvertTo-EODouble $tagRotate) }

    foreach ($side in @(Get-EOPropertyValue $Stream 'side_data_list' @())) {
        $rotation = Get-EOPropertyValue $side 'rotation'
        if ($null -ne $rotation) { return [int](ConvertTo-EODouble $rotation) }
    }
    return 0
}

function Get-EOHdrMetadata {
    param($Stream)

    $maxCll = $null
    $maxFall = $null
    $mastering = $null
    $dolbyVision = $false

    foreach ($side in @(Get-EOPropertyValue $Stream 'side_data_list' @())) {
        $type = [string](Get-EOPropertyValue $side 'side_data_type' '')
        if ($type -match 'Mastering display') { $mastering = $side }
        if ($type -match 'Content light level') {
            $maxCll = [int](ConvertTo-EODouble (Get-EOPropertyValue $side 'max_content' 0))
            $maxFall = [int](ConvertTo-EODouble (Get-EOPropertyValue $side 'max_average' 0))
        }
        if ($type -match 'DOVI|Dolby Vision') { $dolbyVision = $true }
    }

    $tag = [string](Get-EOPropertyValue $Stream 'codec_tag_string' '')
    if ($tag -in @('dvhe','dvh1')) { $dolbyVision = $true }

    $primaries = [string](Get-EOPropertyValue $Stream 'color_primaries' '')
    $transfer = [string](Get-EOPropertyValue $Stream 'color_transfer' '')
    $isHdr = $dolbyVision -or $transfer -in @('smpte2084','arib-std-b67')
    $kind = if ($dolbyVision) {
        'DolbyVision'
    } elseif ($transfer -eq 'arib-std-b67') {
        'HLG'
    } elseif ($transfer -eq 'smpte2084' -and $primaries -eq 'bt2020' -and ($null -ne $mastering -or $null -ne $maxCll)) {
        'HDR10'
    } elseif ($transfer -eq 'smpte2084') {
        'PQ'
    } else {
        'SDR'
    }

    [pscustomobject]@{
        IsHdr        = [bool]$isHdr
        HdrKind      = $kind
        DolbyVision  = [bool]$dolbyVision
        Mastering    = $mastering
        MaxCLL       = $maxCll
        MaxFALL      = $maxFall
    }
}

function Get-EOVideoClassification {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $VideoStream)

    $rFps = ConvertFrom-EORational (Get-EOPropertyValue $VideoStream 'r_frame_rate' '0/0')
    $avgFps = ConvertFrom-EORational (Get-EOPropertyValue $VideoStream 'avg_frame_rate' '0/0')
    $relativeDelta = if ($rFps -gt 0 -and $avgFps -gt 0) { [math]::Abs($rFps - $avgFps) / [math]::Max($rFps, $avgFps) } else { 0.0 }
    $fieldOrder = [string](Get-EOPropertyValue $VideoStream 'field_order' 'unknown')
    $hdr = Get-EOHdrMetadata $VideoStream

    [pscustomobject]@{
        NominalFrameRate = $rFps
        AverageFrameRate = $avgFps
        FrameRate        = if ($avgFps -gt 0) { $avgFps } else { $rFps }
        IsVfr            = $relativeDelta -gt 0.005
        IsInterlaced     = $fieldOrder -notin @('progressive','unknown','')
        FieldOrder       = $fieldOrder
        IsHdr            = $hdr.IsHdr
        HdrKind          = $hdr.HdrKind
        DolbyVision      = $hdr.DolbyVision
    }
}

function ConvertTo-EONormalizedAuxStream {
    param($Stream)
    $tags = Get-EOPropertyValue $Stream 'tags'
    [pscustomobject]@{
        Index        = [int](Get-EOPropertyValue $Stream 'index' -1)
        CodecName    = [string](Get-EOPropertyValue $Stream 'codec_name' '')
        CodecType    = [string](Get-EOPropertyValue $Stream 'codec_type' '')
        Profile      = [string](Get-EOPropertyValue $Stream 'profile' '')
        BitRate      = ConvertTo-EOInt64 (Get-EOPropertyValue $Stream 'bit_rate' 0)
        Language     = [string](Get-EOPropertyValue $tags 'language' '')
        Title        = [string](Get-EOPropertyValue $tags 'title' '')
        Channels     = [int](Get-EOPropertyValue $Stream 'channels' 0)
        ChannelLayout = [string](Get-EOPropertyValue $Stream 'channel_layout' '')
        SampleRate   = [int](ConvertTo-EOInt64 (Get-EOPropertyValue $Stream 'sample_rate' 0))
        Disposition  = ConvertTo-EODisposition (Get-EOPropertyValue $Stream 'disposition')
        Raw          = $Stream
    }
}

function ConvertFrom-EOFFprobeJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Json,
        [string] $Path = ''
    )

    $root = $Json | ConvertFrom-Json -Depth 100
    $streams = @(Get-EOPropertyValue $root 'streams' @())
    $videoRaw = @($streams | Where-Object { (Get-EOPropertyValue $_ 'codec_type' '') -eq 'video' -and [int](Get-EOPropertyValue (Get-EOPropertyValue $_ 'disposition') 'attached_pic' 0) -ne 1 }) | Select-Object -First 1
    if ($videoRaw.Count -eq 0) { throw 'No primary video stream was found.' }
    $videoStream = $videoRaw[0]

    $classification = Get-EOVideoClassification $videoStream
    $hdr = Get-EOHdrMetadata $videoStream
    $pixFmt = [string](Get-EOPropertyValue $videoStream 'pix_fmt' '')
    $tags = Get-EOPropertyValue $videoStream 'tags'

    $video = [pscustomobject]@{
        Index             = [int](Get-EOPropertyValue $videoStream 'index' 0)
        CodecName         = [string](Get-EOPropertyValue $videoStream 'codec_name' '')
        CodecTag          = [string](Get-EOPropertyValue $videoStream 'codec_tag_string' '')
        Profile           = [string](Get-EOPropertyValue $videoStream 'profile' '')
        Level             = [int](Get-EOPropertyValue $videoStream 'level' 0)
        Width             = [int](Get-EOPropertyValue $videoStream 'width' 0)
        Height            = [int](Get-EOPropertyValue $videoStream 'height' 0)
        CodedWidth        = [int](Get-EOPropertyValue $videoStream 'coded_width' (Get-EOPropertyValue $videoStream 'width' 0))
        CodedHeight       = [int](Get-EOPropertyValue $videoStream 'coded_height' (Get-EOPropertyValue $videoStream 'height' 0))
        SampleAspectRatio = [string](Get-EOPropertyValue $videoStream 'sample_aspect_ratio' '')
        DisplayAspectRatio = [string](Get-EOPropertyValue $videoStream 'display_aspect_ratio' '')
        PixelFormat       = $pixFmt
        BitDepth          = Get-EOBitDepth $pixFmt
        NominalFrameRate  = $classification.NominalFrameRate
        AverageFrameRate  = $classification.AverageFrameRate
        FrameRate         = $classification.FrameRate
        IsVfr             = $classification.IsVfr
        TimeBase          = [string](Get-EOPropertyValue $videoStream 'time_base' '')
        FieldOrder        = $classification.FieldOrder
        IsInterlaced      = $classification.IsInterlaced
        Rotation          = Get-EORotation $videoStream
        ColorRange        = [string](Get-EOPropertyValue $videoStream 'color_range' '')
        ColorSpace        = [string](Get-EOPropertyValue $videoStream 'color_space' '')
        ColorTransfer     = [string](Get-EOPropertyValue $videoStream 'color_transfer' '')
        ColorPrimaries    = [string](Get-EOPropertyValue $videoStream 'color_primaries' '')
        IsHdr             = $hdr.IsHdr
        HdrKind           = $hdr.HdrKind
        DolbyVision       = $hdr.DolbyVision
        MasteringDisplay  = $hdr.Mastering
        MaxCLL            = $hdr.MaxCLL
        MaxFALL           = $hdr.MaxFALL
        BitRate           = ConvertTo-EOInt64 (Get-EOPropertyValue $videoStream 'bit_rate' 0)
        Duration          = ConvertTo-EODouble (Get-EOPropertyValue $videoStream 'duration' 0)
        FrameCount        = ConvertTo-EOInt64 (Get-EOPropertyValue $videoStream 'nb_frames' 0)
        Language          = [string](Get-EOPropertyValue $tags 'language' '')
        Disposition       = ConvertTo-EODisposition (Get-EOPropertyValue $videoStream 'disposition')
        Raw               = $videoStream
    }

    $audio = @($streams | Where-Object { (Get-EOPropertyValue $_ 'codec_type' '') -eq 'audio' } | ForEach-Object { ConvertTo-EONormalizedAuxStream $_ })
    $subtitles = @($streams | Where-Object { (Get-EOPropertyValue $_ 'codec_type' '') -eq 'subtitle' } | ForEach-Object { ConvertTo-EONormalizedAuxStream $_ })
    $attachments = @($streams | Where-Object { (Get-EOPropertyValue $_ 'codec_type' '') -eq 'attachment' -or [int](Get-EOPropertyValue (Get-EOPropertyValue $_ 'disposition') 'attached_pic' 0) -eq 1 } | ForEach-Object { ConvertTo-EONormalizedAuxStream $_ })
    $dataStreams = @($streams | Where-Object { (Get-EOPropertyValue $_ 'codec_type' '') -eq 'data' } | ForEach-Object { ConvertTo-EONormalizedAuxStream $_ })

    $formatRaw = Get-EOPropertyValue $root 'format'
    $format = [pscustomobject]@{
        Name        = [string](Get-EOPropertyValue $formatRaw 'format_name' '')
        LongName    = [string](Get-EOPropertyValue $formatRaw 'format_long_name' '')
        Duration    = ConvertTo-EODouble (Get-EOPropertyValue $formatRaw 'duration' 0)
        Size        = ConvertTo-EOInt64 (Get-EOPropertyValue $formatRaw 'size' 0)
        BitRate     = ConvertTo-EOInt64 (Get-EOPropertyValue $formatRaw 'bit_rate' 0)
        StartTime   = ConvertTo-EODouble (Get-EOPropertyValue $formatRaw 'start_time' 0)
        Tags        = Get-EOPropertyValue $formatRaw 'tags'
        Raw         = $formatRaw
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($video.IsVfr) { $warnings.Add('Variable frame rate indicators detected; source timing will be preserved.') }
    if ($video.IsInterlaced) { $warnings.Add("Interlaced field order '$($video.FieldOrder)' detected; no automatic deinterlacing will be applied.") }
    if ($video.DolbyVision) { $warnings.Add('Dolby Vision metadata detected; automatic transcoding requires an explicit preservation-safe path.') }
    if ($video.IsHdr) { $warnings.Add("$($video.HdrKind) source detected; HDR metadata and bit depth must be preserved.") }

    [pscustomobject]@{
        Path        = $Path
        Video       = $video
        Audio       = $audio
        Subtitles   = $subtitles
        Attachments = $attachments
        Data        = $dataStreams
        Chapters    = @(Get-EOPropertyValue $root 'chapters' @())
        Format      = $format
        Warnings    = @($warnings)
        Raw         = $root
    }
}

function Get-EOSourceProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $FFprobePath = 'ffprobe',
        [scriptblock] $CommandRunner
    )

    if ($CommandRunner) {
        $json = & $CommandRunner $FFprobePath @('-v','error','-show_format','-show_streams','-show_chapters','-of','json','--',$Path)
        if ($json -is [array]) { $json = $json -join [Environment]::NewLine }
    } else {
        $resolved = (Get-Command $FFprobePath -CommandType Application -ErrorAction Stop).Source
        $output = & $resolved -v error -show_format -show_streams -show_chapters -of json -- $Path 2>&1
        if ($LASTEXITCODE -ne 0) { throw "ffprobe failed for '$Path': $($output -join [Environment]::NewLine)" }
        $json = $output -join [Environment]::NewLine
    }

    ConvertFrom-EOFFprobeJson -Json ([string]$json) -Path $Path
}

Export-ModuleMember -Function ConvertFrom-EOFFprobeJson, Get-EOSourceProbe, Get-EOVideoClassification
