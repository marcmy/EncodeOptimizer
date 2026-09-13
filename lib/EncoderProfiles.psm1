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

function Test-EOEncoderSupportsSource {
    param($ConfigEntry, $SourceProbe)
    if ($SourceProbe.Video.IsHdr -and -not [bool]$ConfigEntry.SupportsHdr) { return $false }
    if ([int]$SourceProbe.Video.BitDepth -gt (Get-EOProfileMaxBitDepth $ConfigEntry)) { return $false }
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
    $preferred = @($ConfigEntry.PreferredArgs)
    for ($i = 0; $i -lt $preferred.Count; $i += 2) {
        $option = [string]$preferred[$i]
        $value = if (($i + 1) -lt $preferred.Count) { [string]$preferred[$i + 1] } else { $null }
        if (-not $option.StartsWith('-')) { continue }

        $optionName = $option.TrimStart('-')
        if (-not [bool]$ConfigEntry.Hardware -or $AvailableOptions -contains $optionName) {
            $result.Add($option)
            if ($null -ne $value) { $result.Add($value) }
        }
    }
    return @($result)
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
        throw "Encoder '$Name' cannot safely preserve this source's bit depth/HDR characteristics."
    }

    $options = Get-EOCapabilityEncoderOptions $Capabilities $Name
    $qualityName = ([string]$entry.QualityOption).TrimStart('-')
    if ([bool]$entry.Hardware -and $options.Count -gt 0 -and $options -notcontains $qualityName) {
        throw "Encoder '$Name' does not expose required quality option '$($entry.QualityOption)'."
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
        Arguments       = @(Resolve-EOPreferredArguments $entry $options)
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

Export-ModuleMember -Function Get-EOEncoderCandidates, Resolve-EOEncoderProfile
