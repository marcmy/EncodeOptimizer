Set-StrictMode -Version Latest

function Get-EOPropertyValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-EOPercentile {
    param([double[]]$Values, [double]$Percentile)
    if ($Values.Count -eq 0) { return [double]::NaN }
    $sorted = @($Values | Sort-Object)
    $rank = [math]::Ceiling([math]::Max(0.0, [math]::Min(1.0, $Percentile)) * $sorted.Count)
    $index = [math]::Max(0, [math]::Min($sorted.Count - 1, $rank - 1))
    return [double]$sorted[$index]
}

function Get-EOAverageMetric {
    param([object[]]$Frames, [string]$Name)
    $values = @($Frames | ForEach-Object {
        $value = Get-EOPropertyValue $_ $Name
        if ($null -ne $value -and -not [double]::IsNaN([double]$value)) { [double]$value }
    })
    if ($values.Count -eq 0) { return $null }
    return [double](($values | Measure-Object -Average).Average)
}

function Join-EOFilterChain {
    param([string[]]$Parts)
    return (@($Parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ',')
}

function ConvertTo-EOFilterPath {
    param([Parameter(Mandatory)][string]$Path)
    $normalized = [IO.Path]::GetFullPath($Path).Replace('\','/')
    $normalized = $normalized -replace ':', '\:'
    $normalized = $normalized.Replace("'", "\'")
    return $normalized
}

function Get-EOMetricPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SourceProbe,
        [Parameter(Mandatory)] $Capabilities,
        [string] $VideoFilter
    )

    $video = $SourceProbe.Video
    $isHdr = [bool](Get-EOPropertyValue $video 'IsHdr' $false)
    $sourcePixelFormat = [string](Get-EOPropertyValue $video 'PixelFormat' 'yuv420p')
    $bitDepth = [int](Get-EOPropertyValue $video 'BitDepth' 8)
    $filters = @((Get-EOPropertyValue $Capabilities 'Filters' @()))

    $comparisonPixelFormat = if ($isHdr) {
        if ($bitDepth -gt 8) { $sourcePixelFormat } else { 'yuv420p10le' }
    } else {
        'yuv420p10le'
    }

    $metrics = [System.Collections.Generic.List[string]]::new()
    if ($filters -contains 'libvmaf') { $metrics.Add('vmaf') }
    if ($filters -contains 'xpsnr') { $metrics.Add('xpsnr') }
    if ($filters -contains 'ssim') { $metrics.Add('ssim') }
    if ($filters -contains 'psnr') { $metrics.Add('psnr') }

    $vmafRole = if ($filters -notcontains 'libvmaf') {
        'Unavailable'
    } elseif ($isHdr) {
        'Advisory'
    } else {
        'Primary'
    }

    $canonical = "format=$comparisonPixelFormat,setpts=PTS-STARTPTS"
    $referenceFilter = Join-EOFilterChain @($VideoFilter, $canonical)
    $candidateFilter = $canonical

    $toneMapAvailable = $filters -contains 'zscale' -and $filters -contains 'tonemap'
    $advisoryToneMap = $null
    if ($isHdr -and $toneMapAvailable -and $filters -contains 'libvmaf') {
        # Deterministic SDR projection used only to make SDR-model VMAF directionally useful.
        # Native high-bit-depth secondary metrics remain authoritative for HDR.
        $advisoryToneMap = 'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p10le'
    }

    $width = [int](Get-EOPropertyValue $video 'Width' 0)
    $height = [int](Get-EOPropertyValue $video 'Height' 0)
    $fps = [double](Get-EOPropertyValue $video 'FrameRate' 0.0)
    $modelClass = if ($width -ge 3000 -or $height -ge 1700) { if ($fps -ge 48) { '4K-HFR' } else { '4K' } } else { if ($fps -ge 48) { 'HD-HFR' } else { 'HD' } }

    return [pscustomobject]@{
        ReferenceUserTransform     = $VideoFilter
        EncodeUserTransform        = $VideoFilter
        ReferenceMetricFilter      = $referenceFilter
        CandidateMetricFilter      = $candidateFilter
        ComparisonPixelFormat      = $comparisonPixelFormat
        Metrics                    = @($metrics)
        VmafRole                   = $vmafRole
        VmafModelClass             = $modelClass
        PreserveHdrNativeMetrics   = $isHdr
        AdvisoryToneMapFilter      = $advisoryToneMap
        ConfidencePenalty          = if ($isHdr) { 0.25 } else { 0.0 }
        Warnings                   = @(
            if ($isHdr) { 'HDR quality uses native high-bit-depth diagnostics; SDR-model VMAF is advisory only.' }
            if ($isHdr -and -not $toneMapAvailable -and $filters -contains 'libvmaf') { 'HDR VMAF tone-map prerequisites are unavailable; VMAF should be omitted.' }
            if ($filters -notcontains 'libvmaf') { 'libvmaf is unavailable; recommendation confidence must be reduced.' }
        )
    }
}

function Measure-EOMetricAggregate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Samples,
        [string] $VmafRole = 'Primary'
    )

    $allFrames = [System.Collections.Generic.List[object]]::new()
    $sampleAggregates = [System.Collections.Generic.List[object]]::new()

    foreach ($sample in $Samples) {
        $frames = @((Get-EOPropertyValue $sample 'Frames' @()))
        foreach ($frame in $frames) { $allFrames.Add($frame) }
        $mean = Get-EOAverageMetric $frames 'Vmaf'
        $sampleAggregates.Add([pscustomobject]@{
            Name       = [string](Get-EOPropertyValue $sample 'Name' '')
            Start      = Get-EOPropertyValue $sample 'Start'
            FrameCount = $frames.Count
            MeanVmaf   = $mean
            MeanXpsnr  = Get-EOAverageMetric $frames 'Xpsnr'
            MeanSsim   = Get-EOAverageMetric $frames 'Ssim'
            MeanPsnr   = Get-EOAverageMetric $frames 'Psnr'
        })
    }

    $vmaf = @($allFrames | ForEach-Object {
        $value = Get-EOPropertyValue $_ 'Vmaf'
        if ($null -ne $value) { [double]$value }
    })

    $validSamples = @($sampleAggregates | Where-Object { $null -ne $_.MeanVmaf })
    $worst = if ($validSamples.Count) { $validSamples | Sort-Object MeanVmaf, Name | Select-Object -First 1 } else { $null }

    $meanVmaf = if ($vmaf.Count) { [double](($vmaf | Measure-Object -Average).Average) } else { $null }
    $minimumVmaf = if ($vmaf.Count) { [double](($vmaf | Measure-Object -Minimum).Minimum) } else { $null }

    return [pscustomobject]@{
        VmafRole        = $VmafRole
        FrameCount      = $allFrames.Count
        SampleCount     = $Samples.Count
        MeanVmaf        = $meanVmaf
        MinimumVmaf     = $minimumVmaf
        P01Vmaf         = if ($vmaf.Count) { Get-EOPercentile $vmaf 0.01 } else { $null }
        P05Vmaf         = if ($vmaf.Count) { Get-EOPercentile $vmaf 0.05 } else { $null }
        P10Vmaf         = if ($vmaf.Count) { Get-EOPercentile $vmaf 0.10 } else { $null }
        WorstSampleVmaf = if ($worst) { [double]$worst.MeanVmaf } else { $null }
        WorstSampleName = if ($worst) { [string]$worst.Name } else { $null }
        MeanXpsnr       = Get-EOAverageMetric @($allFrames) 'Xpsnr'
        MeanSsim        = Get-EOAverageMetric @($allFrames) 'Ssim'
        MeanPsnr        = Get-EOAverageMetric @($allFrames) 'Psnr'
        Samples         = @($sampleAggregates)
    }
}

function Test-EOQualityPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Aggregate,
        [Parameter(Mandatory)] $Policy
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $margins = [ordered]@{}
    $role = [string](Get-EOPropertyValue $Aggregate 'VmafRole' 'Primary')
    $authoritativeMetric = if ($role -eq 'Primary') { 'VMAF' } else { 'Secondary' }

    if ($role -eq 'Primary') {
        foreach ($check in @(
            @{ Name='MeanVmaf'; Label='Mean VMAF'; Threshold=[double]$Policy.MeanVmaf; Scale=1.0 },
            @{ Name='WorstSampleVmaf'; Label='Worst-sample VMAF'; Threshold=[double]$Policy.WorstSampleVmaf; Scale=1.0 },
            @{ Name='P05Vmaf'; Label='P05 VMAF'; Threshold=[double]$Policy.P05Vmaf; Scale=1.0 }
        )) {
            $value = Get-EOPropertyValue $Aggregate $check.Name
            if ($null -eq $value) {
                $failures.Add("$($check.Label) unavailable")
                $margins[$check.Name] = $null
                continue
            }
            $rawMargin = [double]$value - $check.Threshold
            $margins[$check.Name] = $rawMargin * $check.Scale
            if ($rawMargin -lt 0) { $failures.Add("$($check.Label) below policy by $([math]::Round(-$rawMargin,3))") }
        }
    } else {
        $secondaryChecks = @(
            @{ Name='MeanXpsnr'; Label='XPSNR'; Threshold=[double](Get-EOPropertyValue $Policy 'MinimumXpsnr' 45.0); Scale=1.0 },
            @{ Name='MeanSsim'; Label='SSIM'; Threshold=[double](Get-EOPropertyValue $Policy 'MinimumSsim' 0.990); Scale=100.0 },
            @{ Name='MeanPsnr'; Label='PSNR'; Threshold=[double](Get-EOPropertyValue $Policy 'MinimumPsnr' 45.0); Scale=1.0 }
        )
        $availableCount = 0
        foreach ($check in $secondaryChecks) {
            $value = Get-EOPropertyValue $Aggregate $check.Name
            if ($null -eq $value) {
                $margins[$check.Name] = $null
                continue
            }
            $availableCount++
            $rawMargin = [double]$value - $check.Threshold
            $margins[$check.Name] = $rawMargin * $check.Scale
            if ($rawMargin -lt 0) { $failures.Add("$($check.Label) below policy by $([math]::Round(-$rawMargin,4))") }
        }
        $minimumRequired = [int](Get-EOPropertyValue $Policy 'MinimumSecondaryMetrics' 2)
        if ($availableCount -lt $minimumRequired) {
            $failures.Add("Only $availableCount secondary quality metric(s) available; policy requires $minimumRequired.")
        }
    }

    $secondaryAnomaly = [bool](Get-EOPropertyValue $Aggregate 'SeriousSecondaryAnomaly' $false)
    if ($secondaryAnomaly) { $failures.Add('Serious secondary-metric anomaly') }

    $marginValues = @($margins.Values | Where-Object { $null -ne $_ })
    $minimumMargin = if ($marginValues.Count) { [double](($marginValues | Measure-Object -Minimum).Minimum) } else { $null }
    $comfortableMargin = [double](Get-EOPropertyValue $Policy 'ComfortableMargin' 0.5)

    return [pscustomobject]@{
        Passed              = ($failures.Count -eq 0)
        Failures            = @($failures)
        Margins             = [pscustomobject]$margins
        MinimumMargin       = $minimumMargin
        Comfortable         = ($failures.Count -eq 0 -and $null -ne $minimumMargin -and $minimumMargin -ge $comfortableMargin)
        Authoritative       = ($failures.Count -eq 0)
        AuthoritativeMetric = $authoritativeMetric
        VmafRole            = $role
    }
}

function Read-EOVmafJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20
    $result = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($frame in @($json.frames)) {
        $value = Get-EOPropertyValue $frame.metrics 'vmaf'
        if ($null -ne $value) {
            $result.Add([pscustomobject]@{ Index=$index; Vmaf=[double]$value })
        }
        $index++
    }
    return @($result)
}

function Read-EOStatsFile {
    param([string]$Path, [ValidateSet('xpsnr','ssim','psnr')] [string]$Metric)
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    $map = @{}
    $index = 0
    foreach ($line in Get-Content -LiteralPath $Path) {
        $value = $null
        switch ($Metric) {
            'ssim' {
                if ($line -match 'All:([0-9.+-Ee]+)') { $value = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
            }
            'psnr' {
                if ($line -match 'psnr_avg:([0-9.+-Ee]+|inf)') {
                    $value = if ($Matches[1] -eq 'inf') { 100.0 } else { [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
                }
            }
            'xpsnr' {
                if ($line -match 'XPSNR[^:]*:([0-9.+-Ee]+)') { $value = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
                elseif ($line -match 'xpsnr_avg:([0-9.+-Ee]+)') { $value = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
            }
        }
        if ($null -ne $value) { $map[$index] = [double]$value }
        $index++
    }
    return $map
}

function Invoke-EOMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ReferencePath,
        [Parameter(Mandatory)] [string] $CandidatePath,
        [Parameter(Mandatory)] $MetricPlan,
        [double] $ReferenceStart = 0.0,
        [double] $Duration = 0.0,
        [string] $SampleName = 'sample',
        [string] $FFmpegPath = 'ffmpeg',
        [string] $WorkDirectory,
        [scriptblock] $CommandRunner
    )

    if ([string]::IsNullOrWhiteSpace($WorkDirectory)) {
        $WorkDirectory = Join-Path ([IO.Path]::GetTempPath()) ('EncodeOptimizer-metrics-' + [guid]::NewGuid().ToString('N'))
    }
    New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null

    $vmafPath = Join-Path $WorkDirectory 'vmaf.json'
    $xpsnrPath = Join-Path $WorkDirectory 'xpsnr.log'
    $ssimPath = Join-Path $WorkDirectory 'ssim.log'
    $psnrPath = Join-Path $WorkDirectory 'psnr.log'

    $metrics = @($MetricPlan.Metrics)
    if ([string]$MetricPlan.VmafRole -eq 'Advisory' -and [string]::IsNullOrWhiteSpace([string]$MetricPlan.AdvisoryToneMapFilter)) {
        $metrics = @($metrics | Where-Object { $_ -ne 'vmaf' })
    }
    if ($metrics.Count -eq 0) { throw 'No supported quality metrics are available.' }

    $referenceFilter = [string]$MetricPlan.ReferenceMetricFilter
    $candidateFilter = [string]$MetricPlan.CandidateMetricFilter
    $pairCount = $metrics.Count

    $graph = [System.Collections.Generic.List[string]]::new()
    $graph.Add("[0:v]$referenceFilter,split=$pairCount" + (@(0..($pairCount-1) | ForEach-Object { "[r$_]" }) -join ''))
    $graph.Add("[1:v]$candidateFilter,split=$pairCount" + (@(0..($pairCount-1) | ForEach-Object { "[d$_]" }) -join ''))

    for ($i = 0; $i -lt $metrics.Count; $i++) {
        switch ($metrics[$i]) {
            'vmaf' {
                $ref = "[r$i]"; $dist = "[d$i]"
                if ([string]$MetricPlan.VmafRole -eq 'Advisory' -and $MetricPlan.AdvisoryToneMapFilter) {
                    $graph.Add("$ref$($MetricPlan.AdvisoryToneMapFilter)[rv$i]")
                    $graph.Add("$dist$($MetricPlan.AdvisoryToneMapFilter)[dv$i]")
                    $ref = "[rv$i]"; $dist = "[dv$i]"
                }
                $graph.Add("$dist$ref" + "libvmaf=log_fmt=json:log_path='$(ConvertTo-EOFilterPath $vmafPath)'[m$i]")
                $graph.Add("[m$i]nullsink")
            }
            'xpsnr' {
                $graph.Add("[d$i][r$i]xpsnr=stats_file='$(ConvertTo-EOFilterPath $xpsnrPath)'[m$i]")
                $graph.Add("[m$i]nullsink")
            }
            'ssim' {
                $graph.Add("[d$i][r$i]ssim=stats_file='$(ConvertTo-EOFilterPath $ssimPath)'[m$i]")
                $graph.Add("[m$i]nullsink")
            }
            'psnr' {
                $graph.Add("[d$i][r$i]psnr=stats_file='$(ConvertTo-EOFilterPath $psnrPath)'[m$i]")
                $graph.Add("[m$i]nullsink")
            }
        }
    }

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @('-hide_banner','-nostdin')) { $arguments.Add($item) }
    if ($ReferenceStart -gt 0) { $arguments.Add('-ss'); $arguments.Add($ReferenceStart.ToString([Globalization.CultureInfo]::InvariantCulture)) }
    $arguments.Add('-i'); $arguments.Add($ReferencePath)
    $arguments.Add('-i'); $arguments.Add($CandidatePath)
    if ($Duration -gt 0) { $arguments.Add('-t'); $arguments.Add($Duration.ToString([Globalization.CultureInfo]::InvariantCulture)) }
    $arguments.Add('-filter_complex'); $arguments.Add(($graph -join ';'))
    $arguments.Add('-f'); $arguments.Add('null'); $arguments.Add('-')

    if ($CommandRunner) {
        $raw = & $CommandRunner $FFmpegPath @($arguments)
    } else {
        $resolved = (Get-Command $FFmpegPath -CommandType Application -ErrorAction Stop).Source
        $raw = (& $resolved @arguments 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "FFmpeg metric comparison failed.`n$raw" }
    }

    $vmafFrames = @(Read-EOVmafJson $vmafPath)
    $xpsnr = Read-EOStatsFile $xpsnrPath 'xpsnr'
    $ssim = Read-EOStatsFile $ssimPath 'ssim'
    $psnr = Read-EOStatsFile $psnrPath 'psnr'
    $frameCount = @($vmafFrames.Count, $xpsnr.Count, $ssim.Count, $psnr.Count | Measure-Object -Maximum).Maximum
    $frames = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $frameCount; $i++) {
        $vf = if ($i -lt $vmafFrames.Count) { $vmafFrames[$i].Vmaf } else { $null }
        $frames.Add([pscustomobject]@{
            Index = $i
            Vmaf = $vf
            Xpsnr = if ($xpsnr.ContainsKey($i)) { $xpsnr[$i] } else { $null }
            Ssim = if ($ssim.ContainsKey($i)) { $ssim[$i] } else { $null }
            Psnr = if ($psnr.ContainsKey($i)) { $psnr[$i] } else { $null }
        })
    }

    $candidateBytes = if (Test-Path -LiteralPath $CandidatePath) { (Get-Item -LiteralPath $CandidatePath).Length } else { $null }
    $candidateKbps = if ($null -ne $candidateBytes -and $Duration -gt 0) { ($candidateBytes * 8.0 / $Duration) / 1000.0 } else { $null }

    return [pscustomobject]@{
        Name = $SampleName
        Start = $ReferenceStart
        Duration = $Duration
        Frames = @($frames)
        CandidateBytes = $candidateBytes
        CandidateKbps = $candidateKbps
        VmafRole = $MetricPlan.VmafRole
        RawOutput = [string]($raw -join "`n")
        WorkDirectory = $WorkDirectory
    }
}

Export-ModuleMember -Function Get-EOMetricPlan, Invoke-EOMetrics, Measure-EOMetricAggregate, Test-EOQualityPolicy
