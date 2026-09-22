Set-StrictMode -Version Latest

function Get-EOStreamProperty {
    param([AllowNull()] $Object, [Parameter(Mandatory)] [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Test-EOMp4SubtitleCodec {
    param([string] $CodecName)
    return $CodecName -in @('mov_text','webvtt')
}

function Get-EOContainerPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SourceProbe,
        [Parameter(Mandatory)] $EncoderProfile,
        [ValidateSet('mp4','mkv')] [string] $Container
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $sourceFormat = [string](Get-EOStreamProperty $SourceProbe.Format 'Name' '')
    $hasAttachments = @($SourceProbe.Attachments).Count -gt 0
    $hasData = @($SourceProbe.Data).Count -gt 0
    $unsafeMp4Subtitles = @($SourceProbe.Subtitles | Where-Object { -not (Test-EOMp4SubtitleCodec ([string]$_.CodecName)) })

    if ($Container) {
        $chosen = $Container
    } elseif ($sourceFormat -match 'matroska') {
        $chosen = 'mkv'
    } elseif ($sourceFormat -match 'mov|mp4' -and $EncoderProfile.Codec -in @('h264','hevc','av1')) {
        if ($unsafeMp4Subtitles.Count -gt 0 -or $hasAttachments -or $hasData) {
            $chosen = 'mkv'
            if ($unsafeMp4Subtitles.Count -gt 0) { $warnings.Add('Source contains a subtitle codec that cannot be copied safely into MP4; using Matroska instead of dropping or transcoding subtitles.') }
            if ($hasAttachments) { $warnings.Add('Source contains attachments; using Matroska so they can be preserved.') }
            if ($hasData) { $warnings.Add('Source contains data streams that are not guaranteed to round-trip through MP4; using Matroska.') }
        } else {
            $chosen = 'mp4'
        }
    } else {
        $chosen = 'mkv'
    }

    if ($chosen -eq 'mp4' -and ($unsafeMp4Subtitles.Count -gt 0 -or $hasAttachments -or $hasData)) {
        throw 'MP4 was explicitly requested but one or more source streams cannot be copied safely, including subtitles, attachments, or data streams. Choose Matroska or explicitly transform/remove those streams.'
    }

    [pscustomobject]@{
        Container = $chosen
        Extension = if ($chosen -eq 'mp4') { '.mp4' } else { '.mkv' }
        VideoTag  = if ($chosen -eq 'mp4' -and $EncoderProfile.Codec -eq 'hevc') { 'hvc1' } else { $null }
        Warnings  = @($warnings)
    }
}

function Get-EOAnalysisContainerPlan {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Container = 'mkv'
        Extension = '.mkv'
        VideoTag  = $null
        Warnings  = @()
    }
}

function Get-EOStreamPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $SourceProbe, [Parameter(Mandatory)] $ContainerPlan)

    $args = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $args.Add('-map'); $args.Add('0:v:0')

    if (@($SourceProbe.Audio).Count -gt 0) {
        $args.Add('-map'); $args.Add('0:a?'); $args.Add('-c:a'); $args.Add('copy')
    }
    if (@($SourceProbe.Subtitles).Count -gt 0) {
        $args.Add('-map'); $args.Add('0:s?'); $args.Add('-c:s'); $args.Add('copy')
    }
    if (@($SourceProbe.Attachments).Count -gt 0) {
        if ($ContainerPlan.Container -ne 'mkv') { throw 'Attachments are present but the selected output container cannot preserve them safely.' }
        $args.Add('-map'); $args.Add('0:t?'); $args.Add('-c:t'); $args.Add('copy')
    }
    if (@($SourceProbe.Data).Count -gt 0) {
        if ($ContainerPlan.Container -eq 'mkv') {
            $args.Add('-map'); $args.Add('0:d?'); $args.Add('-c:d'); $args.Add('copy')
        } else {
            throw 'Data streams cannot be preserved safely in the selected output container. Choose Matroska or explicitly transform/remove them.'
        }
    }

    $args.Add('-map_metadata'); $args.Add('0')
    $args.Add('-map_chapters'); $args.Add('0')
    [pscustomobject]@{ Arguments = @($args); Warnings = @($warnings) }
}

function Get-EOPixelFormatCharacteristics {
    param([Parameter(Mandatory)][string]$PixelFormat)

    $format = $PixelFormat.ToLowerInvariant()
    $chroma = 0
    $depth = 0

    if ($format -match '^yuvj?(420|422|444)p(?:(9|10|12|14|16)(?:le|be))?$') {
        $chroma = switch ($Matches[1]) { '420' { 1 } '422' { 2 } '444' { 3 } }
        $depth = if ($Matches[2]) { [int]$Matches[2] } else { 8 }
    } elseif ($format -in @('nv12','nv21')) {
        $chroma = 1; $depth = 8
    } elseif ($format -eq 'nv16') {
        $chroma = 2; $depth = 8
    } elseif ($format -eq 'nv24') {
        $chroma = 3; $depth = 8
    } elseif ($format -match '^p([024])(10|12|16)(?:le|be)$') {
        $chroma = switch ($Matches[1]) { '0' { 1 } '2' { 2 } '4' { 3 } }
        $depth = [int]$Matches[2]
    } else {
        return $null
    }

    return [pscustomobject]@{
        PixelFormat = $format
        BitDepth = $depth
        ChromaRank = $chroma
    }
}

function Get-EOOutputPixelFormat {
    param([Parameter(Mandatory)] $SourceProbe, [Parameter(Mandatory)] $EncoderProfile)

    $sourceFormat = ([string]$SourceProbe.Video.PixelFormat).ToLowerInvariant()
    $sourceBitDepth = [int]$SourceProbe.Video.BitDepth
    $available = @($EncoderProfile.PixelFormats | ForEach-Object { ([string]$_).ToLowerInvariant() })

    # Exact format support is always the least surprising and preserves both depth and chroma.
    if ($available -contains $sourceFormat) { return $sourceFormat }

    $sourceInfo = Get-EOPixelFormatCharacteristics -PixelFormat $sourceFormat
    if ($null -eq $sourceInfo) {
        throw "Encoder '$($EncoderProfile.Name)' cannot safely convert unknown source pixel format '$sourceFormat' without an exact supported match."
    }

    $knownCandidates = [System.Collections.Generic.List[object]]::new()
    foreach ($candidateFormat in $available) {
        $info = Get-EOPixelFormatCharacteristics -PixelFormat $candidateFormat
        if ($null -ne $info) { $knownCandidates.Add($info) }
    }

    $depthCapable = @($knownCandidates | Where-Object { [int]$_.BitDepth -ge $sourceBitDepth })
    $chromaCapable = @($knownCandidates | Where-Object { [int]$_.ChromaRank -ge [int]$sourceInfo.ChromaRank })
    $safe = @($knownCandidates | Where-Object {
        [int]$_.BitDepth -ge $sourceBitDepth -and [int]$_.ChromaRank -ge [int]$sourceInfo.ChromaRank
    })

    if ($safe.Count -gt 0) {
        # Prefer the smallest non-lossy representation: same chroma first, then closest bit depth.
        $chosen = $safe | Sort-Object `
            @{ Expression = { [int]$_.ChromaRank - [int]$sourceInfo.ChromaRank }; Ascending = $true }, `
            @{ Expression = { [int]$_.BitDepth - $sourceBitDepth }; Ascending = $true }, `
            @{ Expression = { [string]$_.PixelFormat }; Ascending = $true } | Select-Object -First 1
        return [string]$chosen.PixelFormat
    }

    if ($depthCapable.Count -gt 0 -and @($depthCapable | Where-Object { [int]$_.ChromaRank -lt [int]$sourceInfo.ChromaRank }).Count -eq $depthCapable.Count) {
        throw "Encoder '$($EncoderProfile.Name)' cannot preserve source chroma sampling for '$sourceFormat'; refusing a silent chroma reduction."
    }
    if ($chromaCapable.Count -gt 0 -and @($chromaCapable | Where-Object { [int]$_.BitDepth -lt $sourceBitDepth }).Count -eq $chromaCapable.Count) {
        throw "Encoder '$($EncoderProfile.Name)' cannot preserve source bit depth $sourceBitDepth for '$sourceFormat'; refusing a bit depth reduction."
    }

    throw "Encoder '$($EncoderProfile.Name)' cannot preserve source bit depth and chroma sampling for '$sourceFormat'."
}

function Add-EOColorArguments {
    param([System.Collections.Generic.List[string]] $Arguments, $Video)
    $pairs = @(
        @('-color_range', [string](Get-EOStreamProperty $Video 'ColorRange' '')),
        @('-colorspace', [string](Get-EOStreamProperty $Video 'ColorSpace' '')),
        @('-color_trc', [string](Get-EOStreamProperty $Video 'ColorTransfer' '')),
        @('-color_primaries', [string](Get-EOStreamProperty $Video 'ColorPrimaries' ''))
    )
    foreach ($pair in $pairs) {
        if (-not [string]::IsNullOrWhiteSpace($pair[1])) { $Arguments.Add($pair[0]); $Arguments.Add($pair[1]) }
    }
}

function New-EOFinalEncodeArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InputPath,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] $SourceProbe,
        [Parameter(Mandatory)] $EncoderProfile,
        [Parameter(Mandatory)] $ContainerPlan,
        [Parameter(Mandatory)] $StreamPlan,
        [Parameter(Mandatory)] [int] $Quality,
        [string] $VideoFilter,
        [switch] $Analysis
    )

    if ([IO.Path]::GetFullPath($InputPath) -eq [IO.Path]::GetFullPath($OutputPath)) { throw 'Output path must not overwrite the input file.' }

    $args = [System.Collections.Generic.List[string]]::new()
    $args.Add('-hide_banner'); $args.Add('-nostdin'); $args.Add('-i'); $args.Add($InputPath)
    foreach ($arg in @($StreamPlan.Arguments)) { $args.Add([string]$arg) }
    if ($VideoFilter) { $args.Add('-vf'); $args.Add($VideoFilter) }

    $args.Add('-c:v'); $args.Add([string]$EncoderProfile.Name)
    $args.Add([string]$EncoderProfile.QualityOption); $args.Add([string]$Quality)
    $profileArguments = if ($Analysis -and $EncoderProfile.PSObject.Properties['AnalysisArguments']) {
        @($EncoderProfile.AnalysisArguments)
    } else {
        @($EncoderProfile.Arguments)
    }
    foreach ($arg in $profileArguments) { $args.Add([string]$arg) }

    $pixelFormat = Get-EOOutputPixelFormat -SourceProbe $SourceProbe -EncoderProfile $EncoderProfile
    $args.Add('-pix_fmt'); $args.Add($pixelFormat)
    Add-EOColorArguments -Arguments $args -Video $SourceProbe.Video
    if ($ContainerPlan.VideoTag) { $args.Add('-tag:v'); $args.Add([string]$ContainerPlan.VideoTag) }

    # Preserve decoded frame timestamps instead of allowing FFmpeg's automatic output-vsync
    # policy to retime fractional-rate/VFR material during candidate and final encodes.
    $args.Add('-fps_mode'); $args.Add('passthrough')

    # Never add -r, CFR forcing, automatic deinterlacing, tone mapping, or unconditional overwrite.
    $args.Add($OutputPath)
    return @($args)
}

function New-EOReferenceSampleArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InputPath,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [double] $Start,
        [Parameter(Mandatory)] [double] $Duration,
        [string] $VideoFilter
    )

    if ($Start -lt 0) { throw 'Reference sample start must not be negative.' }
    if ($Duration -le 0) { throw 'Reference sample duration must be greater than zero.' }
    if ([IO.Path]::GetFullPath($InputPath) -eq [IO.Path]::GetFullPath($OutputPath)) { throw 'Reference sample output path must not overwrite the input file.' }

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $args = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @('-hide_banner','-nostdin','-ss',$Start.ToString($culture),'-i',$InputPath,'-t',$Duration.ToString($culture),'-map','0:v:0','-an','-sn','-dn')) {
        $args.Add([string]$item)
    }
    $referenceFilters = [System.Collections.Generic.List[string]]::new()
    if ($VideoFilter) { $referenceFilters.Add($VideoFilter) }
    # Analysis references must start at a deterministic zero timestamp. Without this,
    # a non-zero source/sample start can be rounded differently by the lossless and
    # candidate containers, producing a frame-shifted metric comparison.
    $referenceFilters.Add('setpts=PTS-STARTPTS')
    $args.Add('-vf'); $args.Add(($referenceFilters -join ','))
    foreach ($item in @('-c:v','ffv1','-level','3','-g','1','-fps_mode','passthrough',$OutputPath)) {
        $args.Add([string]$item)
    }
    return $args.ToArray()
}

function Add-EOSampleWindowArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][double]$Start,
        [Parameter(Mandatory)][double]$Duration
    )

    $inputIndex = [Array]::IndexOf($Arguments, '-i')
    if ($inputIndex -lt 0) { throw 'Generated FFmpeg arguments do not contain an input marker.' }

    $result = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $inputIndex; $i++) { $result.Add([string]$Arguments[$i]) }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $result.Add('-ss'); $result.Add($Start.ToString($culture))
    $result.Add('-t'); $result.Add($Duration.ToString($culture))
    for ($i = $inputIndex; $i -lt $Arguments.Count; $i++) { $result.Add([string]$Arguments[$i]) }
    return $result.ToArray()
}

Export-ModuleMember -Function Get-EOContainerPlan, Get-EOAnalysisContainerPlan, Get-EOStreamPlan, New-EOFinalEncodeArguments, New-EOReferenceSampleArguments, Add-EOSampleWindowArguments
