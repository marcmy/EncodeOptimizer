Set-StrictMode -Version Latest

function Get-EOEncoderConfig {
    param([string] $ProfilePath)
    if (-not $ProfilePath) {
        $ProfilePath = Join-Path $PSScriptRoot '..\config\encoder-profiles.psd1'
    }
    Import-PowerShellDataFile $ProfilePath
}

function Get-EOProfileMaxBitDepth {
    param($Profile)
    $max = 8
    foreach ($fmt in @($Profile.PixelFormats)) {
        if ($fmt -match '(?:p0?|p)(9|10|12|14|16)') {
            $max = [math]::Max($max, [int]$Matches[1])
        } elseif ($fmt -match '(9|10|12|14|16)(?:le|be)$') {
            $max = [math]::Max($max, [int]$Matches[1])
        }
    }
    return $max
}

function Get-EOProfilePixelFormatCharacteristics {
    param([Parameter(Mandatory)][string]$PixelFormat)

    $format = $PixelFormat.ToLowerInvariant()
    if ($format -match '^yuvj?(420|422|444)p(?:(9|10|12|14|16)(?:le|be))?$') {
        return [pscustomobject]@{
            PixelFormat = $format
            ChromaRank = switch ($Matches[1]) { '420' { 1 } '422' { 2 } '444' { 3 } }
            BitDepth = if ($Matches[2]) { [int]$Matches[2] } else { 8 }
        }
    }
    if ($format -in @('nv12','nv21')) { return [pscustomobject]@{ PixelFormat=$format; ChromaRank=1; BitDepth=8 } }
    if ($format -eq 'nv16') { return [pscustomobject]@{ PixelFormat=$format; ChromaRank=2; BitDepth=8 } }
    if ($format -eq 'nv24') { return [pscustomobject]@{ PixelFormat=$format; ChromaRank=3; BitDepth=8 } }
    if ($format -match '^p([024])(10|12|16)(?:le|be)$') {
        return [pscustomobject]@{
            PixelFormat = $format
            ChromaRank = switch ($Matches[1]) { '0' { 1 } '2' { 2 } '4' { 3 } }
            BitDepth = [int]$Matches[2]
        }
    }
    return $null
}

function Test-EOProfilePreservesPixelFormat {
    param($ConfigEntry, $SourceProbe)

    $sourceFormat = ([string]$SourceProbe.Video.PixelFormat).ToLowerInvariant()
    $sourceBitDepth = [int]$SourceProbe.Video.BitDepth
    $formats = @($ConfigEntry.PixelFormats | ForEach-Object { ([string]$_).ToLowerInvariant() })

    if ($formats -contains $sourceFormat) { return $true }

    $sourceInfo = Get-EOProfilePixelFormatCharacteristics -PixelFormat $sourceFormat
    if ($null -eq $sourceInfo) { return $false }

    foreach ($format in $formats) {
        $candidate = Get-EOProfilePixelFormatCharacteristics -PixelFormat $format
        if ($null -eq $candidate) { continue }
        if ([int]$candidate.BitDepth -ge $sourceBitDepth -and [int]$candidate.ChromaRank -ge [int]$sourceInfo.ChromaRank) {
            return $true
        }
    }
    return $false
}

function Test-EOEncoderSupportsSource {
    param($ConfigEntry, $SourceProbe)
    if ($SourceProbe.Video.IsHdr -and -not [bool]$ConfigEntry.SupportsHdr) { return $false }
    if ([int]$SourceProbe.Video.BitDepth -gt (Get-EOProfileMaxBitDepth $ConfigEntry)) { return $false }
    if (-not (Test-EOProfilePreservesPixelFormat $ConfigEntry $SourceProbe)) { return $false }
    return $true
}

function Get-EOCapabilityEncoderOptions {
    param($Capabilities, [string] $Name)
    if ($null -eq $Capabilities.EncoderOptions) { return @() }
    if ($Capabilities.EncoderOptions -is [System.Collections.IDictionary]) {
        if ($Capabilities.EncoderOptions.Contains($Name)) { return @($Capabilities.EncoderOptions[$Name]) }
        if ($Capabilities.EncoderOptions.ContainsKey($Name)) { return @($Capabilities.EncoderOptions[$Name]) }
    }
    $property = $Capabilities.EncoderOptions.PSObject.Properties[$Name]
    if ($property) { return @($property.Value) }
    return @()
}

function Resolve-EOPreferredArguments {
    param($ConfigEntry, [string[]] $AvailableOptions)

    $result = [System.Collections.Generic.List[string]]::new()
    $genericFfmpegOptions = @('b:v')
    $preferred = @($ConfigEntry.PreferredArgs)
    for ($i = 0; $i -lt $preferred.Count; $i += 2) {
        $option = [string]$preferred[$i]
        $value = if (($i + 1) -lt $preferred.Count) { [string]$preferred[$i + 1] } else { $null }
        if (-not $option.StartsWith('-')) { continue }

        $optionName = $option.TrimStart('-')
        if (-not [bool]$ConfigEntry.Hardware -or $genericFfmpegOptions -contains $optionName -or $AvailableOptions -contains $optionName) {
            $result.Add($option)
            if ($null -ne $value) { $result.Add($value) }
        }
    }
    return @($result)
}

function Get-EOHevcNvencOutputLevel {
    param(
        [Parameter(Mandatory)] $SourceProbe,
        [Parameter(Mandatory)] [double] $RequiredVideoKbps
    )

    $width = [int]$SourceProbe.Video.Width
    $height = [int]$SourceProbe.Video.Height
    $frameRate = [double]$SourceProbe.Video.FrameRate

    if ($width -le 0 -or $height -le 0 -or $frameRate -le 0) {
        return '6.2'
    }

    $pictureSamples = [double]$width * [double]$height
    $sampleRate = $pictureSamples * $frameRate

    # NVENC CQ/VBR can be silently constrained by the selected HEVC level. These
    # effective Main-tier ceilings are conservative relative to the nominal HEVC
    # maxima and match the plateaus observed from NVENC at 4.1, 5.1, 5.2 and 6.0.
    # Reserve 20% for full-file scenes harder than the sampled windows.
    $requiredMbps = ([math]::Max(0.0, $RequiredVideoKbps) * 1.20) / 1000.0

    $levels = @(
        [pscustomobject]@{ Name='3';   MaxPicture=552960;   MaxSampleRate=33177600;   EffectiveMainMbps=4.8  }
        [pscustomobject]@{ Name='3.1'; MaxPicture=983040;   MaxSampleRate=66846720;   EffectiveMainMbps=8.0  }
        [pscustomobject]@{ Name='4';   MaxPicture=2228224;  MaxSampleRate=133693440;  EffectiveMainMbps=9.6  }
        [pscustomobject]@{ Name='4.1'; MaxPicture=2228224;  MaxSampleRate=133693440;  EffectiveMainMbps=16.0 }
        [pscustomobject]@{ Name='5';   MaxPicture=8912896;  MaxSampleRate=267386880;  EffectiveMainMbps=20.0 }
        [pscustomobject]@{ Name='5.1'; MaxPicture=8912896;  MaxSampleRate=534773760;  EffectiveMainMbps=32.0 }
        [pscustomobject]@{ Name='5.2'; MaxPicture=8912896;  MaxSampleRate=1069547520; EffectiveMainMbps=48.0 }
        [pscustomobject]@{ Name='6';   MaxPicture=35651584; MaxSampleRate=1069547520; EffectiveMainMbps=48.0 }
        [pscustomobject]@{ Name='6.1'; MaxPicture=35651584; MaxSampleRate=2139095040; EffectiveMainMbps=96.0 }
        [pscustomobject]@{ Name='6.2'; MaxPicture=35651584; MaxSampleRate=4278190080; EffectiveMainMbps=192.0 }
    )

    foreach ($level in $levels) {
        if ($pictureSamples -le [double]$level.MaxPicture -and
            $sampleRate -le [double]$level.MaxSampleRate -and
            $requiredMbps -le [double]$level.EffectiveMainMbps) {
            return [string]$level.Name
        }
    }

    return '6.2'
}

function Resolve-EOFinalEncoderProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $EncoderProfile,
        [Parameter(Mandatory)] $SourceProbe,
        [Parameter(Mandatory)] [double] $RequiredVideoKbps
    )

    if ([string]$EncoderProfile.Name -ne 'hevc_nvenc' -or @($EncoderProfile.AvailableOptions) -notcontains 'level') {
        return $EncoderProfile
    }

    $level = Get-EOHevcNvencOutputLevel -SourceProbe $SourceProbe -RequiredVideoKbps $RequiredVideoKbps
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @($EncoderProfile.Arguments)) { $arguments.Add([string]$argument) }
    $arguments.Add('-level'); $arguments.Add($level)

    if ($level -eq '6.2' -and @($EncoderProfile.AvailableOptions) -contains 'tier' -and (($RequiredVideoKbps * 1.20) -gt 192000.0)) {
        $arguments.Add('-tier'); $arguments.Add('high')
    }

    $copy = [ordered]@{}
    foreach ($property in $EncoderProfile.PSObject.Properties) { $copy[$property.Name] = $property.Value }
    $copy['Arguments'] = @($arguments)
    return [pscustomobject]$copy
}

function Resolve-EOEncoderProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $Capabilities,
        [Parameter(Mandatory)] $SourceProbe,
        [string] $ProfilePath
    )

    $config = Get-EOEncoderConfig $ProfilePath
    if (-not $config.ContainsKey($Name)) { throw "Unknown encoder profile '$Name'." }
    if (@($Capabilities.Encoders) -notcontains $Name) { throw "Encoder '$Name' is not available in this FFmpeg build." }

    $entry = $config[$Name]
    if (-not (Test-EOEncoderSupportsSource $entry $SourceProbe)) {
        throw "Encoder '$Name' cannot safely preserve this source's bit depth, chroma sampling, or HDR characteristics."
    }

    $options = Get-EOCapabilityEncoderOptions $Capabilities $Name
    $qualityName = ([string]$entry.QualityOption).TrimStart('-')
    if ([bool]$entry.Hardware -and $options.Count -gt 0 -and $options -notcontains $qualityName) {
        throw "Encoder '$Name' does not expose required quality option '$($entry.QualityOption)'."
    }

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @(Resolve-EOPreferredArguments $entry $options)) {
        $arguments.Add([string]$argument)
    }

    $analysisArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @($arguments)) { $analysisArguments.Add([string]$argument) }
    if ($Name -eq 'hevc_nvenc' -and $options -contains 'level') {
        $analysisArguments.Add('-level'); $analysisArguments.Add('6.2')
        if ($options -contains 'tier') { $analysisArguments.Add('-tier'); $analysisArguments.Add('high') }
    }

    [pscustomobject]@{
        Name            = $Name
        Codec           = [string]$entry.Codec
        QualityControl  = [string]$entry.QualityControl
        QualityOption   = [string]$entry.QualityOption
        SearchMinimum   = [int]$entry.SearchMinimum
        SearchMaximum   = [int]$entry.SearchMaximum
        DefaultStart    = [int]$entry.DefaultStart
        BetterDirection = [string]$entry.BetterDirection
        Hardware        = [bool]$entry.Hardware
        SupportsHdr     = [bool]$entry.SupportsHdr
        PixelFormats    = @($entry.PixelFormats)
        Arguments       = @($arguments)
        AnalysisArguments = @($analysisArguments)
        AvailableOptions = @($options)
    }
}

function Get-EOEncoderCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SourceProbe,
        [Parameter(Mandatory)] $Capabilities,
        [string] $Encoder,
        [string] $Codec,
        [string] $ProfilePath
    )

    $config = Get-EOEncoderConfig $ProfilePath
    $available = @($Capabilities.Encoders)

    if ($Encoder) {
        if ($available -notcontains $Encoder) { throw "Requested encoder '$Encoder' is not available." }
        if (-not $config.ContainsKey($Encoder)) { throw "Requested encoder '$Encoder' has no EncodeOptimizer profile." }
        if (-not (Test-EOEncoderSupportsSource $config[$Encoder] $SourceProbe)) {
            throw "Requested encoder '$Encoder' cannot safely preserve this source."
        }
        return @($Encoder)
    }

    $sourceCodec = ([string]$SourceProbe.Video.CodecName).ToLowerInvariant()
    $ordered = switch ($sourceCodec) {
        'hevc' { @('hevc_nvenc','libx265') }
        'h265' { @('hevc_nvenc','libx265') }
        'h264' { @('hevc_nvenc','libx265','h264_nvenc','libx264') }
        'av1'  { @('av1_nvenc','libsvtav1') }
        'vp9'  { @('av1_nvenc','libsvtav1','hevc_nvenc','libx265') }
        default { @('hevc_nvenc','libx265','av1_nvenc','libsvtav1') }
    }

    $safe = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $ordered) {
        if ($available -notcontains $name -or -not $config.ContainsKey($name)) { continue }
        $entry = $config[$name]
        if ($Codec -and ([string]$entry.Codec).ToLowerInvariant() -ne $Codec.ToLowerInvariant()) { continue }
        if (-not (Test-EOEncoderSupportsSource $entry $SourceProbe)) { continue }
        $safe.Add($name)
    }

    if ($safe.Count -eq 0) { return @('KEEP_SOURCE') }
    return @($safe)
}

Export-ModuleMember -Function Get-EOEncoderCandidates, Resolve-EOEncoderProfile, Resolve-EOFinalEncoderProfile
