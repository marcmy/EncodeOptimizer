Set-StrictMode -Version Latest

function Get-EOSafetyProperty {
    param($Object,[string]$Name,$Default=$null)
    if ($null -eq $Object) { return $Default }
    $property=$Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-EOLowerConfidenceCeiling {
    param([string]$Current,[string]$Candidate)
    $rank=@{ LOW=1; MEDIUM=2; HIGH=3 }
    if (-not $rank.ContainsKey($Current)) { $Current='HIGH' }
    if (-not $rank.ContainsKey($Candidate)) { return $Current }
    if ($rank[$Candidate] -lt $rank[$Current]) { return $Candidate }
    return $Current
}

function Get-EOSafetyGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SourceProbe,
        [Parameter(Mandatory)]$MetricPlan,
        [switch]$AllowHdrAutoEncode,
        [switch]$AllowInterlacedAutoEncode,
        [switch]$AllowSecondaryMetricsAutoEncode
    )

    $video=$SourceProbe.Video
    $reasons=[System.Collections.Generic.List[string]]::new()
    $warnings=[System.Collections.Generic.List[string]]::new()
    $hardBlock=$false
    $autoAllowed=$true
    $confidenceCeiling='HIGH'

    $dolbyVision=[bool](Get-EOSafetyProperty $video 'DolbyVision' $false)
    $isHdr=[bool](Get-EOSafetyProperty $video 'IsHdr' $false)
    $interlaced=[bool](Get-EOSafetyProperty $video 'IsInterlaced' $false)
    $vfr=[bool](Get-EOSafetyProperty $video 'IsVfr' $false)
    $vmafRole=[string](Get-EOSafetyProperty $MetricPlan 'VmafRole' 'Unavailable')
    $metrics=@((Get-EOSafetyProperty $MetricPlan 'Metrics' @()))

    if ($dolbyVision) {
        $hardBlock=$true
        $autoAllowed=$false
        $confidenceCeiling='LOW'
        $reasons.Add('Dolby Vision automatic transcoding is hard-blocked because preservation of the enhancement layer and RPU metadata is not proven safe.')
    }

    if ($isHdr -and -not $dolbyVision) {
        $confidenceCeiling=Get-EOLowerConfidenceCeiling $confidenceCeiling 'MEDIUM'
        if (-not $AllowHdrAutoEncode) {
            $autoAllowed=$false
            $reasons.Add('HDR automatic encoding requires -AllowHdrAutoEncode; analyze-only recommendations remain available.')
        } else {
            $warnings.Add('HDR automatic encoding was explicitly enabled. Native high-bit-depth secondary metrics remain authoritative; SDR-model VMAF is advisory.')
        }
    }

    if ($interlaced) {
        $confidenceCeiling=Get-EOLowerConfidenceCeiling $confidenceCeiling 'MEDIUM'
        if (-not $AllowInterlacedAutoEncode) {
            $autoAllowed=$false
            $reasons.Add('Interlaced input requires -AllowInterlacedAutoEncode because EncodeOptimizer will not silently deinterlace it.')
        } else {
            $warnings.Add('Interlaced automatic encoding was explicitly enabled; field structure will be preserved rather than silently deinterlaced.')
        }
    }

    if ($vfr) {
        $warnings.Add('Variable-frame-rate (VFR) source detected. EncodeOptimizer preserves source timing and does not force CFR.')
    }

    if ($vmafRole -ne 'Primary') {
        $confidenceCeiling=Get-EOLowerConfidenceCeiling $confidenceCeiling 'MEDIUM'
        $secondaryCount=@($metrics | Where-Object { $_ -in @('xpsnr','ssim','psnr') }).Count
        if ($secondaryCount -lt 2) {
            $autoAllowed=$false
            $reasons.Add("Only $secondaryCount usable secondary quality metric(s) are available; at least two are required for automatic encoding without authoritative VMAF.")
        } elseif (-not $AllowSecondaryMetricsAutoEncode -and -not $isHdr) {
            $autoAllowed=$false
            $reasons.Add('Authoritative VMAF is unavailable; automatic encoding requires -AllowSecondaryMetricsAutoEncode.')
        } elseif ($AllowSecondaryMetricsAutoEncode -and -not $isHdr) {
            $warnings.Add('Automatic encoding is using secondary metrics because authoritative VMAF is unavailable.')
        }
    }

    if ($hardBlock) { $autoAllowed=$false }

    return [pscustomobject]@{
        AnalyzeAllowed=$true
        AutoEncodeAllowed=$autoAllowed
        HardBlock=$hardBlock
        ConfidenceCeiling=$confidenceCeiling
        Reasons=@($reasons)
        Warnings=@($warnings)
        VmafRole=$vmafRole
        SecondaryMetricCount=@($metrics | Where-Object { $_ -in @('xpsnr','ssim','psnr') }).Count
    }
}

Export-ModuleMember -Function Get-EOSafetyGate
