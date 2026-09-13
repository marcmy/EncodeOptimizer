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

    if ($chosen -eq 'mp4' -and ($unsafeMp4Subtitles.Count -gt 0 -or $hasAttachments)) {
        throw 'MP4 was explicitly requested but one or more source streams cannot be copied safely. Choose Matroska or explicitly transform/remove those streams.'
    }

    [pscustomobject]@{
        Container = $chosen
        Extension = if ($chosen -eq 'mp4') { '.mp4' } else { '.mkv' }
        VideoTag  = if ($chosen -eq 'mp4' -and $EncoderProfile.Codec -eq 'hevc') { 'hvc1' } else { $null }
        Warnings  = @($warnings)
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
            $warnings.Add('Data streams require explicit compatibility validation before MP4 output.')
        }
    }

    $args.Add('-map_metadata'); $args.Add('0')
    $args.Add('-map_chapters'); $args.Add('0')
    [pscustomobject]@{ Arguments = @($args); Warnings = @($warnings) }
}

function Get-EOOutputPixelFormat {
    param([Parameter(Mandatory)] $SourceProbe, [Parameter(Mandatory)] $EncoderProfile)

    $sourceFormat = [string]$SourceProbe.Video.PixelFormat
    $bitDepth = [int]$SourceProbe.Video.BitDepth
    if ($bitDepth -gt 8) {
        if ($EncoderProfile.Hardware) {
            if (@($EncoderProfile.PixelFormats) -contains 'p010le') { return 'p010le' }
            if (@($EncoderProfile.PixelFormats) -contains 'p016le') { return 'p016le' }
        }
        if (@($EncoderProfile.PixelFormats) -contains $sourceFormat) { return $sourceFormat }
        if (@($EncoderProfile.PixelFormats) -contains 'yuv420p10le') { return 'yuv420p10le' }
        throw "Encoder '$($EncoderProfile.Name)' cannot preserve the source bit depth/pixel format."
    }

    if (@($EncoderProfile.PixelFormats) -contains $sourceFormat) { return $sourceFormat }
    if (@($EncoderProfile.PixelFormats) -contains 'yuv420p') { return 'yuv420p' }
    throw "Encoder '$($EncoderProfile.Name)' cannot safely represent source pixel format '$sourceFormat'."
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
        [string] $VideoFilter
    )

    if ([IO.Path]::GetFullPath($InputPath) -eq [IO.Path]::GetFullPath($OutputPath)) { throw 'Output path must not overwrite the input file.' }

    $args = [System.Collections.Generic.List[string]]::new()
    $args.Add('-hide_banner'); $args.Add('-i'); $args.Add($InputPath)
    foreach ($arg in @($StreamPlan.Arguments)) { $args.Add([string]$arg) }
    if ($VideoFilter) { $args.Add('-vf'); $args.Add($VideoFilter) }

    $args.Add('-c:v'); $args.Add([string]$EncoderProfile.Name)
    $args.Add([string]$EncoderProfile.QualityOption); $args.Add([string]$Quality)
    foreach ($arg in @($EncoderProfile.Arguments)) { $args.Add([string]$arg) }

    $pixelFormat = Get-EOOutputPixelFormat -SourceProbe $SourceProbe -EncoderProfile $EncoderProfile
    $args.Add('-pix_fmt'); $args.Add($pixelFormat)
    Add-EOColorArguments -Arguments $args -Video $SourceProbe.Video
    if ($ContainerPlan.VideoTag) { $args.Add('-tag:v'); $args.Add([string]$ContainerPlan.VideoTag) }

    # Never add -r, CFR forcing, automatic deinterlacing, tone mapping, or unconditional overwrite.
    $args.Add($OutputPath)
    return @($args)
}

Export-ModuleMember -Function Get-EOContainerPlan, Get-EOStreamPlan, New-EOFinalEncodeArguments
