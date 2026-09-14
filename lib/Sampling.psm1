Set-StrictMode -Version Latest

function Limit-EOUnit {
    param([double]$Value)
    return [math]::Max(0.0, [math]::Min(1.0, $Value))
}

function Get-EOSamplingDuration {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $SourceProbe)

    $video = $SourceProbe.Video
    $format = $SourceProbe.Format
    $videoDuration = if ($video -and $video.PSObject.Properties['Duration']) { [double]$video.Duration } else { 0.0 }
    $formatDuration = if ($format -and $format.PSObject.Properties['Duration']) { [double]$format.Duration } else { 0.0 }

    if ($videoDuration -gt 0) {
        if ($formatDuration -gt 0) { return [math]::Min($videoDuration, $formatDuration) }
        return $videoDuration
    }

    $frameCount = if ($video -and $video.PSObject.Properties['FrameCount']) { [long]$video.FrameCount } else { 0 }
    $frameRate = if ($video -and $video.PSObject.Properties['FrameRate']) { [double]$video.FrameRate } else { 0.0 }
    if ($frameCount -gt 0 -and $frameRate -gt 0) {
        $frameDuration = $frameCount / $frameRate
        if ($formatDuration -gt 0) { return [math]::Min($frameDuration, $formatDuration) }
        return $frameDuration
    }

    return $formatDuration
}

function Get-EOAnalysisWindows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double] $Duration,
        [double] $WindowDuration = 10.0,
        [int] $WindowCount = 24
    )

    if ($Duration -le 0) { throw 'Duration must be greater than zero.' }
    $WindowDuration = [math]::Min([math]::Max(1.0, $WindowDuration), $Duration)
    $maxStart = [math]::Max(0.0, $Duration - $WindowDuration)
    $count = [math]::Max(1, [math]::Min($WindowCount, [math]::Ceiling($Duration / [math]::Max(1.0, $WindowDuration / 2.0))))

    if ($count -eq 1) { return @([pscustomobject]@{ Start = 0.0; Duration = $WindowDuration }) }

    $step = $maxStart / ($count - 1)
    $result = for ($i = 0; $i -lt $count; $i++) {
        $start = if ($i -eq ($count - 1)) { $maxStart } else { $i * $step }
        [pscustomobject]@{ Start = [math]::Round($start, 3); Duration = $WindowDuration }
    }
    return @($result)
}

function Get-EOValuesFromScan {
    param([string]$Text, [string]$Key)
    $values = [System.Collections.Generic.List[double]]::new()
    foreach ($match in [regex]::Matches($Text, "(?m)^$([regex]::Escape($Key))=([-+0-9.eE]+)\s*$")) {
        $parsed = 0.0
        if ([double]::TryParse($match.Groups[1].Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { $values.Add($parsed) }
    }
    return @($values)
}

function Get-EOAverage {
    param([double[]]$Values, [double]$Default = 0.0)
    if ($Values.Count -eq 0) { return $Default }
    return ($Values | Measure-Object -Average).Average
}

function Get-EOStdDev {
    param([double[]]$Values)
    if ($Values.Count -lt 2) { return 0.0 }
    $avg = Get-EOAverage $Values
    $variance = (($Values | ForEach-Object { [math]::Pow($_ - $avg, 2) }) | Measure-Object -Average).Average
    return [math]::Sqrt($variance)
}

function Get-EOContentFeatures {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object[]] $AnalysisWindows,
        [string] $FFmpegPath = 'ffmpeg',
        [scriptblock] $CommandRunner
    )

    $features = [System.Collections.Generic.List[object]]::new()
    foreach ($window in $AnalysisWindows) {
        $arguments = @(
            '-hide_banner','-nostdin','-ss',[string]$window.Start,'-t',[string]$window.Duration,'-i',$Path,
            '-an','-sn','-dn','-vf','fps=2,scale=320:-2:flags=area,scdet=t=10,signalstats,bitplanenoise=bitplane=1,metadata=print:file=-',
            '-f','null','-'
        )
        if ($CommandRunner) {
            $raw = & $CommandRunner $FFmpegPath $arguments
            if ($raw -is [array]) { $raw = $raw -join "`n" }
        } else {
            $resolved = (Get-Command $FFmpegPath -CommandType Application -ErrorAction Stop).Source
            $raw = (& $resolved @arguments 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0) { throw "FFmpeg content scan failed at $($window.Start)s.`n$raw" }
        }
        $raw = [string]$raw

        $yAvg = @(Get-EOValuesFromScan $raw 'lavfi.signalstats.YAVG')
        $yLow = @(Get-EOValuesFromScan $raw 'lavfi.signalstats.YLOW')
        $yHigh = @(Get-EOValuesFromScan $raw 'lavfi.signalstats.YHIGH')
        $yDif = @(Get-EOValuesFromScan $raw 'lavfi.signalstats.YDIF')
        $bitPlaneNoise = @(Get-EOValuesFromScan $raw 'lavfi.bitplanenoise.0.1')
        $sceneScores = @(Get-EOValuesFromScan $raw 'lavfi.scd.score')

        $meanY = Get-EOAverage $yAvg 128
        $meanDif = Get-EOAverage $yDif 0
        $rangeValues = for ($i = 0; $i -lt [math]::Min($yLow.Count, $yHigh.Count); $i++) { [math]::Max(0, $yHigh[$i] - $yLow[$i]) }
        $meanRange = Get-EOAverage @($rangeValues) 64
        $scenePeak = if ($sceneScores.Count) { ($sceneScores | Measure-Object -Maximum).Maximum } else { 0 }
        $blackFraction = if ($yAvg.Count) { @($yAvg | Where-Object { $_ -lt 20 }).Count / $yAvg.Count } else { 0 }

        $motion = Limit-EOUnit ($meanDif / 28.0)
        $detail = Limit-EOUnit ($meanRange / 180.0)
        $dark = Limit-EOUnit ((72.0 - $meanY) / 64.0)
        $scene = Limit-EOUnit ($scenePeak / 30.0)
        # bitplanenoise reports a direct 0..1 noisy-pixel ratio for the selected
        # bit plane. YDIF variance is temporal activity and must not be reused as
        # a grain/noise proxy because fast motion and cuts make it saturate.
        $noise = Limit-EOUnit (Get-EOAverage $bitPlaneNoise 0.0)
        $gradient = Limit-EOUnit ((1.0 - $detail) * (1.0 - $dark) * 0.9)
        $static = Limit-EOUnit (1.0 - ($motion * 4.0))

        $features.Add([pscustomobject]@{
            Start = [double]$window.Start; Duration = [double]$window.Duration
            Motion = $motion; Detail = $detail; Noise = $noise; Dark = $dark
            Gradient = $gradient; Scene = $scene; Static = $static; Black = Limit-EOUnit $blackFraction
        })
    }
    return @($features)
}

function Get-EOFeatureValue {
    param($Window, [string]$Name)
    $property = $Window.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) { return 0.0 }
    return [double]$property.Value
}

function Get-EOSampleScore {
    param($Window)
    $hard = 0.24*(Get-EOFeatureValue $Window 'Motion') + 0.22*(Get-EOFeatureValue $Window 'Detail') +
            0.17*(Get-EOFeatureValue $Window 'Noise') + 0.12*(Get-EOFeatureValue $Window 'Dark') +
            0.10*(Get-EOFeatureValue $Window 'Gradient') + 0.15*(Get-EOFeatureValue $Window 'Scene')
    return $hard - 1.5*(Get-EOFeatureValue $Window 'Black') - 1.0*(Get-EOFeatureValue $Window 'Static')
}

function New-EOSampleObject {
    param($Window, [double]$Duration, [string[]]$Reasons)
    $actualDuration = [math]::Max(0.25, [math]::Min([double]$Window.Duration, $Duration - [double]$Window.Start))
    [pscustomobject]@{
        Start = [double]$Window.Start; Duration = $actualDuration
        Reasons = @($Reasons | Select-Object -Unique); Score = Get-EOSampleScore $Window; Features = $Window
    }
}

function Test-EOWindowOverlapsSamples {
    param([Parameter(Mandatory)]$Window,[Parameter(Mandatory)][object[]]$Samples)
    $windowStart=[double]$Window.Start
    $windowEnd=$windowStart+[double]$Window.Duration
    foreach($sample in $Samples) {
        $sampleStart=[double]$sample.Start
        $sampleEnd=$sampleStart+[double]$sample.Duration
        if($windowStart -lt $sampleEnd -and $sampleStart -lt $windowEnd) { return $true }
    }
    return $false
}

function Select-EOSamples {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $FeatureWindows,
        [Parameter(Mandatory)] [double] $Duration,
        [int] $SearchCount = 8,
        [int] $VerificationCount = 3,
        [double] $SampleDuration = 10.0
    )

    if ($Duration -le 0) { throw 'Duration must be greater than zero.' }
    $windows = @($FeatureWindows | Where-Object { [double]$_.Start -lt $Duration } | Sort-Object Start)
    if ($windows.Count -eq 0) { throw 'No usable analysis windows were supplied.' }
    foreach ($window in $windows) { $window.Duration = [math]::Min($SampleDuration, [math]::Max(0.25, $Duration - [double]$window.Start)) }

    $targetVerify = [math]::Min($VerificationCount, [math]::Max(0, $windows.Count - 1))
    $targetSearch = [math]::Min($SearchCount, $windows.Count - $targetVerify)
    if ($targetSearch -lt 1) { $targetSearch = 1; $targetVerify = [math]::Max(0, $windows.Count - 1) }

    $usable = @($windows | Where-Object { (Get-EOFeatureValue $_ 'Black') -lt 0.8 -and (Get-EOFeatureValue $_ 'Static') -lt 0.8 })
    if ($usable.Count -lt $targetSearch) { $usable = $windows }

    $selected = [ordered]@{}
    $reasonMap = @{}
    function Add-SearchWindow([object]$Window, [string]$Reason) {
        if ($selected.Count -ge $targetSearch -or $null -eq $Window) { return }
        $key = [string][double]$Window.Start
        if (-not $selected.Contains($key)) { $selected[$key] = $Window; $reasonMap[$key] = [System.Collections.Generic.List[string]]::new() }
        if (-not $reasonMap[$key].Contains($Reason)) { $reasonMap[$key].Add($Reason) }
    }

    foreach ($feature in @('Motion','Detail','Noise','Dark','Gradient','Scene')) {
        $candidate = $usable | Sort-Object @{ Expression = { Get-EOFeatureValue $_ $feature }; Descending = $true }, @{ Expression = { Get-EOSampleScore $_ }; Descending = $true }, Start | Select-Object -First 1
        if ($candidate -and (Get-EOFeatureValue $candidate $feature) -ge 0.5) { Add-SearchWindow $candidate $feature.ToLowerInvariant() }
    }

    Add-SearchWindow ($usable | Select-Object -First 1) 'temporal'
    Add-SearchWindow ($usable | Select-Object -Last 1) 'temporal'

    $remainingByScore = @($usable | Where-Object { -not $selected.Contains([string][double]$_.Start) } | Sort-Object @{ Expression = { Get-EOSampleScore $_ }; Descending = $true }, Start)
    foreach ($candidate in $remainingByScore) { if ($selected.Count -ge $targetSearch) { break }; Add-SearchWindow $candidate 'representative' }
    foreach ($candidate in $windows) { if ($selected.Count -ge $targetSearch) { break }; Add-SearchWindow $candidate 'fallback' }

    $searchSamples = @($selected.GetEnumerator() | ForEach-Object { New-EOSampleObject -Window $_.Value -Duration $Duration -Reasons @($reasonMap[$_.Key]) } | Sort-Object Start)
    $searchStarts = @($searchSamples.Start)
    $remaining = @($windows | Where-Object { $searchStarts -notcontains [double]$_.Start })
    $verifyRanked = @($remaining | Sort-Object @{ Expression = { (Get-EOSampleScore $_) - 1.5*(Get-EOFeatureValue $_ 'Black') - 0.8*(Get-EOFeatureValue $_ 'Static') }; Descending = $true }, Start)

    # Independent verification should not share frames with adaptive-search clips when
    # the timeline offers enough alternatives. Short/dense sources may have no such
    # windows, so overlap is retained only as a last-resort fallback rather than
    # silently reducing verification count to zero.
    $independent = @($verifyRanked | Where-Object { -not (Test-EOWindowOverlapsSamples -Window $_ -Samples $searchSamples) })
    $overlapping = @($verifyRanked | Where-Object { Test-EOWindowOverlapsSamples -Window $_ -Samples $searchSamples })
    $verificationSamples = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in @($independent + $overlapping)) {
        if ($verificationSamples.Count -ge $targetVerify) { break }
        $verificationSamples.Add((New-EOSampleObject -Window $candidate -Duration $Duration -Reasons @('verification')))
    }

    [pscustomobject]@{ SearchSamples = @($searchSamples); VerificationSamples = @($verificationSamples); AnalysisWindowCount = $windows.Count }
}

Export-ModuleMember -Function Get-EOSamplingDuration, Get-EOAnalysisWindows, Get-EOContentFeatures, Select-EOSamples
