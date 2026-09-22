[CmdletBinding()]
param(
    [Parameter(Mandatory,Position=0)] [string] $Path,
    [ValidateSet('Conservative','Balanced','Aggressive')] [string] $Profile = 'Conservative',
    [string] $Encoder,
    [ValidateSet('h264','hevc','av1')] [string] $Codec,
    [string] $VideoFilter,
    [switch] $AutoEncode,
    [switch] $ForceEncode,
    [switch] $KeepSamples,
    [switch] $AllowHdrAutoEncode,
    [switch] $AllowInterlacedAutoEncode,
    [switch] $AllowSecondaryMetricsAutoEncode,
    [switch] $BatchMode,
    [string] $OutputPath,
    [string] $FFmpegPath,
    [string] $FFprobePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleNames = @('Capability','Probe','EncoderProfiles','Streams','Sampling','Metrics','Search','Cache','Reporting','Safety')
foreach ($moduleName in $moduleNames) {
    Import-Module (Join-Path $PSScriptRoot "lib\$moduleName.psm1") -Force -DisableNameChecking
}

function Invoke-EOExternalCommand {
    param([Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string[]]$Arguments,[string]$Description='external command')
    $output = & $Executable @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "$Description failed with exit code $exitCode.`n$($output -join [Environment]::NewLine)" }
    return @($output)
}

$progressState = [pscustomobject]@{
    StartedAt = [DateTimeOffset]::Now
    CompletedUnits = 0
    TotalUnits = 1
    LiveActive = $false
    LastLiveLength = 0
}

function Write-EOProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Action,
        [string]$Detail = '',
        [int]$Advance = 0,
        [switch]$Complete,
        [switch]$Live
    )

    if ($Complete) {
        $progressState.CompletedUnits = $progressState.TotalUnits
    } elseif ($Advance -gt 0) {
        $progressState.CompletedUnits = [math]::Min($progressState.TotalUnits, $progressState.CompletedUnits + $Advance)
    }

    $percent = if ($progressState.TotalUnits -gt 0) {
        100.0 * $progressState.CompletedUnits / $progressState.TotalUnits
    } else {
        0.0
    }
    $elapsed = [DateTimeOffset]::Now - $progressState.StartedAt
    $elapsedText = $elapsed.ToString('hh\:mm\:ss')
    $message = if ([string]::IsNullOrWhiteSpace($Detail)) { $Action } else { "$Action | $Detail" }
    $line = "[{0,6:0.0}%] {1,-9} {2} | {3} | elapsed {4}" -f $percent, $Phase.ToUpperInvariant(), $message, "$($progressState.CompletedUnits)/$($progressState.TotalUnits) units", $elapsedText
    if ($Live) {
        $padding = [math]::Max(0, [int]$progressState.LastLiveLength - $line.Length)
        Write-Host -NoNewline ("`r" + $line + (' ' * $padding))
        $progressState.LiveActive = $true
        $progressState.LastLiveLength = $line.Length
        return
    }
    if ($progressState.LiveActive) {
        Write-Host
        $progressState.LiveActive = $false
        $progressState.LastLiveLength = 0
    }
    Write-Host $line
}

function Get-EOProgressMetricSummary {
    param([Parameter(Mandatory)]$Aggregate)

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($definition in @(
        @{ Name = 'MeanVmaf'; Label = 'VMAF'; Digits = 2 },
        @{ Name = 'P05Vmaf'; Label = 'P05'; Digits = 2 },
        @{ Name = 'MeanXpsnr'; Label = 'XPSNR'; Digits = 2 },
        @{ Name = 'MeanSsim'; Label = 'SSIM'; Digits = 4 },
        @{ Name = 'MeanPsnr'; Label = 'PSNR'; Digits = 2 }
    )) {
        $property = $Aggregate.PSObject.Properties[$definition.Name]
        if ($property -and $null -ne $property.Value) {
            $parts.Add("$($definition.Label)=$([math]::Round([double]$property.Value, [int]$definition.Digits))")
        }
    }
    if ($parts.Count -eq 0) { return 'metrics unavailable' }
    return ($parts -join ' ')
}

function Get-EODefaultCacheRoot {
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'EncodeOptimizer') }
    if ($HOME) { return (Join-Path $HOME '.cache\EncodeOptimizer') }
    return (Join-Path ([IO.Path]::GetTempPath()) 'EncodeOptimizer')
}

function Get-EOResolutionClass {
    param($Video)
    $height = [int]$Video.Height
    if ($height -le 576) { return 'SD' }
    if ($height -le 720) { return '720p' }
    if ($height -le 1080) { return '1080p' }
    if ($height -le 1440) { return '1440p' }
    return '4K+'
}

function Get-EOFpsClass {
    param([double]$Fps)
    foreach ($common in 24,25,30,50,60,120) {
        if ([math]::Abs($Fps - $common) -lt 0.75 -or [math]::Abs($Fps - ($common * 1000.0/1001.0)) -lt 0.20) { return [string]$common }
    }
    if ($Fps -ge 48) { return 'HFR' }
    return [string][math]::Round($Fps,0)
}

function Get-EOAuxiliaryBitrateKbps {
    param($Probe)
    $known = 0.0
    foreach ($audio in @($Probe.Audio)) {
        if ([long]$audio.BitRate -gt 0) { $known += [long]$audio.BitRate / 1000.0 }
    }
    $formatRate = [long]$Probe.Format.BitRate
    $videoRate = [long]$Probe.Video.BitRate
    if ($formatRate -gt 0 -and $videoRate -gt 0) {
        $remainder = [math]::Max(0.0, ($formatRate - $videoRate) / 1000.0)
        $known = [math]::Max($known, $remainder)
    }
    return $known
}

function Get-EOSampleComplexity {
    param($Sample)
    $values = [System.Collections.Generic.List[double]]::new()
    if ($Sample.PSObject.Properties['Features'] -and $Sample.Features) {
        foreach ($name in 'Motion','Detail','Noise','Dark','Gradient','Scene') {
            $property = $Sample.Features.PSObject.Properties[$name]
            if ($property -and $null -ne $property.Value) { $values.Add([double]$property.Value) }
        }
    }
    if ($values.Count -eq 0) { return 0.5 }
    return [math]::Max(0.0,[math]::Min(1.0,($values | Measure-Object -Maximum).Maximum))
}

function Get-EOSafeOutputPath {
    param([string]$InputPath,[string]$RequestedPath,[string]$Extension)
    $inputFull = [IO.Path]::GetFullPath($InputPath)
    if ($RequestedPath) {
        $full = [IO.Path]::GetFullPath($RequestedPath)
        if ($full -eq $inputFull) { throw 'OutputPath must not overwrite the source file.' }
        if (Test-Path -LiteralPath $full) { throw "OutputPath already exists: '$full'. EncodeOptimizer never overwrites output files implicitly." }
        return $full
    }
    $directory = Split-Path -Parent $inputFull
    $stem = [IO.Path]::GetFileNameWithoutExtension($inputFull)
    $candidate = Join-Path $directory ($stem + '.optimized' + $Extension)
    $suffix = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $directory ($stem + ".optimized.$suffix" + $Extension)
        $suffix++
    }
    return $candidate
}

function Test-EOOutputValidation {
    param($SourceProbe,$OutputProbe,$EncoderProfile)
    $failures = [System.Collections.Generic.List[string]]::new()
    $expectedCodec = [string]$EncoderProfile.Codec
    $actualCodec = ([string]$OutputProbe.Video.CodecName).ToLowerInvariant()
    if ($expectedCodec -eq 'hevc' -and $actualCodec -notin @('hevc','h265')) { $failures.Add("Expected HEVC output, found '$actualCodec'.") }
    elseif ($expectedCodec -eq 'h264' -and $actualCodec -notin @('h264','avc1')) { $failures.Add("Expected H.264 output, found '$actualCodec'.") }
    elseif ($expectedCodec -eq 'av1' -and $actualCodec -ne 'av1') { $failures.Add("Expected AV1 output, found '$actualCodec'.") }

    if ([int]$OutputProbe.Video.BitDepth -lt [int]$SourceProbe.Video.BitDepth) { $failures.Add('Output bit depth is lower than the source.') }
    if ([bool]$SourceProbe.Video.IsHdr -and -not [bool]$OutputProbe.Video.IsHdr) { $failures.Add('HDR source became non-HDR output.') }
    if ([bool]$SourceProbe.Video.IsHdr -and [string]$SourceProbe.Video.ColorTransfer -and [string]$OutputProbe.Video.ColorTransfer -ne [string]$SourceProbe.Video.ColorTransfer) { $failures.Add('HDR transfer characteristic changed.') }
    if (@($OutputProbe.Audio).Count -lt @($SourceProbe.Audio).Count) { $failures.Add('One or more audio streams are missing.') }
    if (@($OutputProbe.Subtitles).Count -lt @($SourceProbe.Subtitles).Count) { $failures.Add('One or more subtitle streams are missing.') }
    if (@($OutputProbe.Attachments).Count -lt @($SourceProbe.Attachments).Count) { $failures.Add('One or more attachments are missing.') }

    $sourceDuration = [double]$SourceProbe.Format.Duration
    $outputDuration = [double]$OutputProbe.Format.Duration
    if ($sourceDuration -gt 0 -and $outputDuration -gt 0) {
        $tolerance = [math]::Max(1.0,$sourceDuration * 0.005)
        if ([math]::Abs($sourceDuration-$outputDuration) -gt $tolerance) { $failures.Add("Output duration differs from source by more than $([math]::Round($tolerance,2)) seconds.") }
    }
    return [pscustomobject]@{ Passed=($failures.Count -eq 0); Failures=@($failures) }
}

function Test-EOConfidenceRequirement {
    param([string]$Actual,[string]$Required)
    $rank = @{ LOW=1; MEDIUM=2; HIGH=3 }
    return [int]$rank[$Actual] -ge [int]$rank[$Required]
}

function Set-EOConfidenceCeiling {
    param($Confidence,[string]$Ceiling)
    $rank=@{ LOW=1; MEDIUM=2; HIGH=3 }
    if ($rank.ContainsKey([string]$Ceiling) -and $rank[[string]$Confidence.Label] -gt $rank[[string]$Ceiling]) {
        $Confidence.Label=[string]$Ceiling
        $Confidence.Reasons=@($Confidence.Reasons) + "Safety policy caps confidence at $Ceiling."
    }
    return $Confidence
}

$inputItem = Get-Item -LiteralPath $Path -ErrorAction Stop
if ($inputItem.PSIsContainer) { throw "Path must name a video file, not a directory. Use Optimize-Videos.ps1 for directories." }
$inputPath = $inputItem.FullName

$qualityProfiles = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'config\quality-profiles.psd1')
$policy = $qualityProfiles[$Profile]
if ($null -eq $policy) { throw "Unknown quality profile '$Profile'." }

$resolvedFFmpeg = Get-EOExecutable -Name 'ffmpeg' -ExplicitPath $FFmpegPath
$resolvedFFprobe = Get-EOExecutable -Name 'ffprobe' -ExplicitPath $FFprobePath
$capabilities = Get-EOCapabilities -FFmpegPath $resolvedFFmpeg
$sourceProbe = Get-EOSourceProbe -Path $inputPath -FFprobePath $resolvedFFprobe
$warnings = [System.Collections.Generic.List[string]]::new()
foreach ($warning in @($sourceProbe.Warnings)) { $warnings.Add([string]$warning) }

$candidateNames = @(Get-EOEncoderCandidates -SourceProbe $sourceProbe -Capabilities $capabilities -Encoder $Encoder -Codec $Codec)
$transformationRequired = -not [string]::IsNullOrWhiteSpace($VideoFilter)
if ($candidateNames.Count -eq 0 -or $candidateNames[0] -eq 'KEEP_SOURCE') {
    if ($transformationRequired) { throw 'No safe encoder is available for the requested transformation.' }
    if ($AutoEncode) { throw 'AutoEncode refused because no safe automatic encoder candidate is available for this source.' }
    $emptySamples = [pscustomobject]@{ SearchSamples=@(); VerificationSamples=@() }
    $keepResult = [pscustomobject]@{ Decision='KEEP_SOURCE'; SelectedQuality=$null; SavingsRatio=$null; EstimatedBytes=$null; Rationale=@('No safe automatic encoder candidate is available for this source.'); AllEvaluations=@(); FinalEvaluation=$null }
    $confidence = [pscustomobject]@{ Label='HIGH'; Score=1.0; Reasons=@() }
    $report = New-EOReport -SourceProbe $sourceProbe -ProfileName $Profile -EncoderName '' -SamplePlan $emptySamples -SearchResult $keepResult -Confidence $confidence -Warnings @($warnings)
    Write-Host (Format-EOHumanReport -Report $report)
    return $report
}

$encoderName = $candidateNames[0]
$encoderProfile = Resolve-EOEncoderProfile -Name $encoderName -Capabilities $capabilities -SourceProbe $sourceProbe
$encoderRationale = @("Selected the first safe Auto-but-conservative candidate '$encoderName' for source codec '$($sourceProbe.Video.CodecName)'.")
if ($encoderProfile.Hardware) { $encoderRationale += 'Hardware encoder selected to avoid unnecessary CPU saturation.' }

$containerPlan = Get-EOContainerPlan -SourceProbe $sourceProbe -EncoderProfile $encoderProfile
$analysisContainerPlan = Get-EOAnalysisContainerPlan
$streamPlan = Get-EOStreamPlan -SourceProbe $sourceProbe -ContainerPlan $containerPlan
foreach ($warning in @($containerPlan.Warnings) + @($streamPlan.Warnings)) { $warnings.Add([string]$warning) }
$metricPlan = Get-EOMetricPlan -SourceProbe $sourceProbe -Capabilities $capabilities -VideoFilter $VideoFilter
$sampleMetricPlan = Get-EOMetricPlan -SourceProbe $sourceProbe -Capabilities $capabilities
foreach ($warning in @($metricPlan.Warnings)) { $warnings.Add([string]$warning) }
$safetyGate = Get-EOSafetyGate -SourceProbe $sourceProbe -MetricPlan $metricPlan -AllowHdrAutoEncode:$AllowHdrAutoEncode -AllowInterlacedAutoEncode:$AllowInterlacedAutoEncode -AllowSecondaryMetricsAutoEncode:$AllowSecondaryMetricsAutoEncode
foreach ($warning in @($safetyGate.Warnings)) { $warnings.Add([string]$warning) }
foreach ($reason in @($safetyGate.Reasons)) { $warnings.Add("AutoEncode gate: $reason") }
if ($AutoEncode -and -not $safetyGate.AutoEncodeAllowed) {
    throw "AutoEncode refused by safety policy:`n - $(@($safetyGate.Reasons) -join "`n - ")"
}

$containerDuration = [double]$sourceProbe.Format.Duration
$samplingDuration = Get-EOSamplingDuration -SourceProbe $sourceProbe
if ($samplingDuration -le 0) { throw 'Unable to determine primary video duration.' }
if ($containerDuration -le 0) { $containerDuration = $samplingDuration }
$durationDeltaTolerance = if ([double]$sourceProbe.Video.FrameRate -gt 0) { [math]::Max(0.05, 2.0 / [double]$sourceProbe.Video.FrameRate) } else { 0.05 }
if (($containerDuration - $samplingDuration) -gt $durationDeltaTolerance) {
    $warnings.Add("Primary video ends $([math]::Round($containerDuration - $samplingDuration,3))s before the container timeline; analysis and quality sampling use the video duration.")
}
$sourceBytes = [long]$sourceProbe.Format.Size
if ($sourceBytes -le 0) { $sourceBytes = [long]$inputItem.Length }

$fingerprint = Get-EOSourceFingerprint -Path $inputPath
$pipelineVersion = 'deterministic-reference-v10-normalized-pts'
$encoderSignature = (@($encoderProfile.Arguments) + @($encoderProfile.AnalysisArguments) + @($encoderProfile.QualityControl,$encoderProfile.SearchMinimum,$encoderProfile.SearchMaximum)) -join '|'
$policySignature = @($policy.MeanVmaf,$policy.WorstSampleVmaf,$policy.P05Vmaf,$policy.MinimumXpsnr,$policy.MinimumSsim,$policy.MinimumPsnr,$policy.MinimumSavingsRatio) -join '|'
$cacheRoot = Get-EODefaultCacheRoot
$cacheKey = Get-EOCacheKey -SourceFingerprint $fingerprint -VideoFilter $VideoFilter -EncoderName $encoderName -EncoderSignature $encoderSignature -FFmpegVersion $capabilities.Version -PolicyName $Profile -PolicySignature $policySignature -PipelineVersion $pipelineVersion
$workRoot = Join-Path (Join-Path $cacheRoot 'work') $cacheKey
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

$analysisWindows = Get-EOAnalysisWindows -Duration $samplingDuration
$usesVmafBaseline = [string]$sampleMetricPlan.VmafRole -eq 'Primary' -and @($sampleMetricPlan.Metrics) -contains 'vmaf'
$maxSearchSampleCount = 8
$maxVerificationSampleCount = 3
$maxSearchEvaluations = 10
$maxVerificationEvaluations = [math]::Max(1, [int]$encoderProfile.SearchMaximum - [int]$encoderProfile.SearchMinimum + 1)
$maxBaselineSampleCount = if ($usesVmafBaseline) { $maxSearchSampleCount + $maxVerificationSampleCount } else { 0 }
$progressState.TotalUnits = [math]::Max(1, $analysisWindows.Count + $maxSearchSampleCount + $maxVerificationSampleCount + $maxBaselineSampleCount +
    ($maxSearchEvaluations * $maxSearchSampleCount) + ($maxVerificationEvaluations * $maxVerificationSampleCount) + 1)
Write-EOProgress -Phase 'INIT' -Action 'work plan ready' -Detail ("complexity $($analysisWindows.Count) windows | references up to $($maxSearchSampleCount + $maxVerificationSampleCount) | search up to $maxSearchEvaluations quality tests | verification up to $maxVerificationEvaluations quality tests")
$features = Get-EOContentFeatures -Path $inputPath -AnalysisWindows $analysisWindows -FFmpegPath $resolvedFFmpeg -ProgressCallback {
    param($Completed,$Total,$Window,$Feature)
    Write-EOProgress -Phase 'ANALYSIS' -Action ("window $Completed/$Total") -Detail ("start $([math]::Round([double]$Window.Start,3))s | motion $([math]::Round([double]$Feature.Motion,2)) detail $([math]::Round([double]$Feature.Detail,2)) noise $([math]::Round([double]$Feature.Noise,2))") -Advance 1 -Live
}
$samplePlan = Select-EOSamples -FeatureWindows $features -Duration $samplingDuration
$actualSearchSampleCount = @($samplePlan.SearchSamples).Count
$actualVerificationSampleCount = @($samplePlan.VerificationSamples).Count
$actualBaselineSampleCount = if ($usesVmafBaseline) { $actualSearchSampleCount + $actualVerificationSampleCount } else { 0 }
$progressState.TotalUnits = [math]::Max(1, $analysisWindows.Count + $actualSearchSampleCount + $actualVerificationSampleCount + $actualBaselineSampleCount +
    ($maxSearchEvaluations * $actualSearchSampleCount) + ($maxVerificationEvaluations * $actualVerificationSampleCount) + 1)
Write-EOProgress -Phase 'PLAN' -Action 'samples selected' -Detail ("search $(@($samplePlan.SearchSamples).Count) | verification $(@($samplePlan.VerificationSamples).Count) | metric role $($sampleMetricPlan.VmafRole)")

if (@($capabilities.Encoders) -notcontains 'ffv1') {
    throw 'FFmpeg does not expose the lossless FFV1 encoder required for deterministic reference samples.'
}

$referenceRoot = Join-Path $workRoot 'reference-samples'
if (Test-Path -LiteralPath $referenceRoot) { Remove-Item -LiteralPath $referenceRoot -Recurse -Force }
New-Item -ItemType Directory -Path $referenceRoot -Force | Out-Null
$referencePaths = @{
    Search = [System.Collections.Generic.List[string]]::new()
    Verification = [System.Collections.Generic.List[string]]::new()
}

Write-EOProgress -Phase 'REFERENCE' -Action 'preparing lossless references' -Detail ("search $actualSearchSampleCount | verification $actualVerificationSampleCount")
foreach ($phase in @('Search','Verification')) {
    $phaseSamples = if ($phase -eq 'Search') { @($samplePlan.SearchSamples) } else { @($samplePlan.VerificationSamples) }
    for ($i = 0; $i -lt $phaseSamples.Count; $i++) {
        $sample = $phaseSamples[$i]
        $referencePath = Join-Path $referenceRoot ("$phase-s$($i + 1).mkv")
        $referenceArgs = @(New-EOReferenceSampleArguments -InputPath $inputPath -OutputPath $referencePath -Start ([double]$sample.Start) -Duration ([double]$sample.Duration) -VideoFilter $VideoFilter)
        Write-EOProgress -Phase 'REFERENCE' -Action ("$phase $($i + 1)/$($phaseSamples.Count)") -Detail ("FFV1 sample | start $([math]::Round([double]$sample.Start,3))s | duration $([math]::Round([double]$sample.Duration,3))s") -Live
        Invoke-EOExternalCommand -Executable $resolvedFFmpeg -Arguments $referenceArgs -Description "$phase reference sample $($i + 1)" | Out-Null
        $referencePaths[$phase].Add($referencePath)
        Write-EOProgress -Phase 'REFERENCE' -Action ("$phase $($i + 1)/$($phaseSamples.Count) ready") -Detail 'lossless reference ready' -Advance 1 -Live
    }
    Write-EOProgress -Phase 'REFERENCE' -Action ("$phase references complete") -Detail ("$($phaseSamples.Count) lossless samples ready")
}

$vmafBaselines = @{
    Search = [System.Collections.Generic.List[object]]::new()
    Verification = [System.Collections.Generic.List[object]]::new()
}
if ([string]$sampleMetricPlan.VmafRole -eq 'Primary' -and @($sampleMetricPlan.Metrics) -contains 'vmaf') {
    $baselineMetricPlan = [pscustomobject]@{
        Metrics = @('vmaf')
        VmafRole = 'Primary'
        AdvisoryToneMapFilter = $sampleMetricPlan.AdvisoryToneMapFilter
        ReferenceMetricFilter = $sampleMetricPlan.ReferenceMetricFilter
        CandidateMetricFilter = $sampleMetricPlan.CandidateMetricFilter
    }
    Write-EOProgress -Phase 'BASELINE' -Action 'calibrating VMAF references' -Detail ("search $actualSearchSampleCount | verification $actualVerificationSampleCount")
    foreach ($phase in @('Search','Verification')) {
        $phaseSamples = if ($phase -eq 'Search') { @($samplePlan.SearchSamples) } else { @($samplePlan.VerificationSamples) }
        for ($i = 0; $i -lt $phaseSamples.Count; $i++) {
            $sample = $phaseSamples[$i]
            $referencePath = $referencePaths[$phase][$i]
            $baselineDirectory = Join-Path $workRoot ("baseline-$Phase-s$($i + 1)")
            if (Test-Path -LiteralPath $baselineDirectory) { Remove-Item -LiteralPath $baselineDirectory -Recurse -Force }
            Write-EOProgress -Phase 'BASELINE' -Action ("$phase $($i + 1)/$($phaseSamples.Count)") -Detail ("self-VMAF calibration | start $([math]::Round([double]$sample.Start,3))s") -Live
            $baseline = Invoke-EOMetrics -ReferencePath $referencePath -CandidatePath $referencePath -MetricPlan $baselineMetricPlan -ReferenceStart 0 -Duration ([double]$sample.Duration) -SampleName ("$Phase-$($i + 1)") -FFmpegPath $resolvedFFmpeg -WorkDirectory $baselineDirectory
            $baseline.Start = [double]$sample.Start
            $vmafBaselines[$phase].Add($baseline)
            $baselineAggregate = Measure-EOMetricAggregate -Samples @($baseline) -VmafRole 'Primary'
            Write-EOProgress -Phase 'BASELINE' -Action ("$phase $($i + 1)/$($phaseSamples.Count) ready") -Detail (Get-EOProgressMetricSummary $baselineAggregate) -Advance 1 -Live
            if (-not $KeepSamples) {
                Remove-Item -LiteralPath $baselineDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Write-EOProgress -Phase 'BASELINE' -Action ("$phase baselines complete") -Detail ("$($phaseSamples.Count) self-VMAF calibrations ready")
    }
}

$populationComplexities = @($features | ForEach-Object {
    Get-EOSampleComplexity ([pscustomobject]@{ Features = $_ })
})

$resolutionClass = Get-EOResolutionClass $sourceProbe.Video
$fpsClass = Get-EOFpsClass ([double]$sourceProbe.Video.FrameRate)
$historySeed = Get-EOHistorySeed -CacheRoot $cacheRoot -Encoder $encoderName -Codec ([string]$sourceProbe.Video.CodecName) -ResolutionClass $resolutionClass -FpsClass $fpsClass -BitDepth ([int]$sourceProbe.Video.BitDepth) -HdrKind ([string]$sourceProbe.Video.HdrKind) -PipelineVersion $pipelineVersion
$auxiliaryKbps = Get-EOAuxiliaryBitrateKbps $sourceProbe

$evaluator = {
    param($Quality,$Samples,$Phase)
    $metricSamples = [System.Collections.Generic.List[object]]::new()
    $sizeSamples = [System.Collections.Generic.List[object]]::new()
    $evaluationFailures = [System.Collections.Generic.List[string]]::new()
    $sampleIndex = 0
    $phaseLabel = if ($Phase -eq 'Verification') { 'VERIFY' } else { 'SEARCH' }
    $sampleCount = @($Samples).Count
    foreach ($sample in @($Samples)) {
        $sampleIndex++
        $sampleDirectory = Join-Path $workRoot ("$Phase-q$Quality-s$sampleIndex-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $sampleDirectory -Force | Out-Null
        $candidatePath = Join-Path $sampleDirectory ('candidate' + $analysisContainerPlan.Extension)
        $referencePath = $referencePaths[$Phase][$sampleIndex - 1]
        $videoOnly = [pscustomobject]@{ Arguments=@('-map','0:v:0'); Warnings=@() }
        $candidateArgs = @(New-EOFinalEncodeArguments -InputPath $referencePath -OutputPath $candidatePath -SourceProbe $sourceProbe -EncoderProfile $encoderProfile -ContainerPlan $analysisContainerPlan -StreamPlan $videoOnly -Quality ([int]$Quality) -Analysis)
        Write-EOProgress -Phase $phaseLabel -Action ("$($encoderProfile.QualityControl)=$Quality sample $sampleIndex/$sampleCount") -Detail ("candidate encode + metrics | start $([math]::Round([double]$sample.Start,3))s | duration $([math]::Round([double]$sample.Duration,3))s") -Live
        try {
            Invoke-EOExternalCommand -Executable $resolvedFFmpeg -Arguments $candidateArgs -Description "candidate sample encode q$Quality" | Out-Null
        } catch {
            $failure = "Candidate sample encode failed for $phaseLabel quality $Quality sample $sampleIndex/${sampleCount}: $($_.Exception.Message)"
            $evaluationFailures.Add($failure)
            Write-EOProgress -Phase $phaseLabel -Action ("$($encoderProfile.QualityControl)=$Quality sample $sampleIndex/$sampleCount failed") -Detail $failure -Advance 1 -Live
            if (-not $KeepSamples) { Remove-Item -LiteralPath $sampleDirectory -Recurse -Force -ErrorAction SilentlyContinue }
            continue
        }

        $metricDirectory = Join-Path $sampleDirectory 'metrics'
        $metric = Invoke-EOMetrics -ReferencePath $referencePath -CandidatePath $candidatePath -MetricPlan $sampleMetricPlan -ReferenceStart 0 -Duration ([double]$sample.Duration) -SampleName ("$Phase-$sampleIndex") -FFmpegPath $resolvedFFmpeg -WorkDirectory $metricDirectory
        $metric.Start = [double]$sample.Start
        $metric | Add-Member -NotePropertyName Complexity -NotePropertyValue (Get-EOSampleComplexity $sample) -Force
        $metricSamples.Add($metric)
        $sizeSamples.Add([pscustomobject]@{ CandidateKbps=$metric.CandidateKbps; Complexity=$metric.Complexity; Duration=[double]$sample.Duration })
        $sampleAggregate = Measure-EOMetricAggregate -Samples @($metric) -VmafRole $sampleMetricPlan.VmafRole
        $bitrateText = if ($null -ne $metric.CandidateKbps) { "bitrate $([math]::Round([double]$metric.CandidateKbps,1)) kbps" } else { 'bitrate unavailable' }
        Write-EOProgress -Phase $phaseLabel -Action ("$($encoderProfile.QualityControl)=$Quality sample $sampleIndex/$sampleCount ready") -Detail ("$(Get-EOProgressMetricSummary $sampleAggregate) | $bitrateText") -Advance 1 -Live

        if (-not $KeepSamples) {
            Remove-Item -LiteralPath $candidatePath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $metricDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $aggregateParameters = @{ Samples=@($metricSamples); VmafRole=$sampleMetricPlan.VmafRole }
    $baselineSamples = @($vmafBaselines[$Phase])
    if ($baselineSamples.Count -and $evaluationFailures.Count -eq 0) { $aggregateParameters.VmafBaselineSamples = $baselineSamples }
    $aggregate = if ($metricSamples.Count) {
        Measure-EOMetricAggregate @aggregateParameters
    } else {
        [pscustomobject]@{
            VmafRole=$sampleMetricPlan.VmafRole; VmafBaselineApplied=$false; FrameCount=0; RelativeFrameCount=0; SampleCount=0
            MeanVmaf=$null; RelativeMeanVmaf=$null; MinimumVmaf=$null; P01Vmaf=$null; P05Vmaf=$null; RelativeP05Vmaf=$null; P10Vmaf=$null
            WorstSampleVmaf=$null; WorstSampleName=$null; RelativeWorstSampleVmaf=$null; RelativeWorstSampleName=$null
            MeanXpsnr=$null; MeanSsim=$null; MeanPsnr=$null; Samples=@()
        }
    }
    $policyDecision = Test-EOQualityPolicy -Aggregate $aggregate -Policy $policy
    $sizeEstimate = if ($evaluationFailures.Count -eq 0) {
        Estimate-EOOutputSize -SampleResults @($sizeSamples) -DurationSeconds $containerDuration -PopulationComplexities $populationComplexities -AuxiliaryBitrateKbps $auxiliaryKbps
    } else {
        $null
    }
    $qualityStatus = if ($policyDecision.Passed -and $evaluationFailures.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $estimatedText = if ($null -ne $sizeEstimate -and $null -ne $sizeEstimate.EstimatedBytes) { "estimated $([math]::Round([double]$sizeEstimate.EstimatedBytes / 1GB,2)) GB" } else { 'estimated size unavailable' }
    $marginText = if ($null -ne $policyDecision.MinimumMargin) { "margin $([math]::Round([double]$policyDecision.MinimumMargin,2))" } else { 'margin unavailable' }
    $failureText = if ($evaluationFailures.Count) { " | failures $($evaluationFailures.Count)" } else { '' }
    Write-EOProgress -Phase $phaseLabel -Action ("$($encoderProfile.QualityControl)=$Quality result") -Detail ("$qualityStatus | $(Get-EOProgressMetricSummary $aggregate) | $marginText | $estimatedText$failureText")
    $allFailures = @($policyDecision.Failures) + @($evaluationFailures | ForEach-Object { [string]$_ })
    return [pscustomobject]@{
        Quality=$Quality; Phase=$Phase; Passed=($policyDecision.Passed -and $evaluationFailures.Count -eq 0); MinimumMargin=$policyDecision.MinimumMargin; AuthoritativeMetric=$policyDecision.AuthoritativeMetric
        MeanVmaf=$aggregate.MeanVmaf; WorstSampleVmaf=$aggregate.WorstSampleVmaf; P05Vmaf=$aggregate.P05Vmaf
        RelativeMeanVmaf=$aggregate.RelativeMeanVmaf; RelativeWorstSampleVmaf=$aggregate.RelativeWorstSampleVmaf; RelativeP05Vmaf=$aggregate.RelativeP05Vmaf
        MeanXpsnr=$aggregate.MeanXpsnr; MeanSsim=$aggregate.MeanSsim; MeanPsnr=$aggregate.MeanPsnr
        EstimatedBytes=if ($null -ne $sizeEstimate) { $sizeEstimate.EstimatedBytes } else { $null }; SizeEstimate=$sizeEstimate; SampleResults=@($metricSamples); AttemptedSampleCount=($metricSamples.Count + $evaluationFailures.Count); Aggregate=$aggregate; Failures=$allFailures
    }
}

Write-EOProgress -Phase 'SEARCH' -Action 'boundary search starting' -Detail ("encoder $encoderName | control $($encoderProfile.QualityControl) | search samples $(@($samplePlan.SearchSamples).Count) | verification samples $(@($samplePlan.VerificationSamples).Count)")
$searchParameters = @{
    EncoderProfile=$encoderProfile; Policy=$policy; SearchSamples=@($samplePlan.SearchSamples); VerificationSamples=@($samplePlan.VerificationSamples)
    Evaluator=$evaluator; SourceBytes=$sourceBytes; MinimumSavingsRatio=[double]$policy.MinimumSavingsRatio; TransformationRequired=$transformationRequired; ForceEncode=$ForceEncode
}
if ($null -ne $historySeed) { $searchParameters.SeedQuality = [int]$historySeed }
$searchResult = Find-EOOptimalQuality @searchParameters
$reportedEvaluationFailures = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($evaluation in @($searchResult.AllEvaluations)) {
    $failureProperty = $evaluation.PSObject.Properties['Failures']
    if ($null -eq $failureProperty) { continue }
    foreach ($failure in @($failureProperty.Value)) {
        if ([string]$failure -notlike 'Candidate sample encode failed*') { continue }
        if (-not [string]::IsNullOrWhiteSpace([string]$failure) -and $reportedEvaluationFailures.Add([string]$failure)) {
            $warnings.Add([string]$failure)
        }
    }
}
$actualSearchWorkUnits = 0
foreach ($evaluation in @($searchResult.SearchEvaluations)) {
    $attemptedProperty = $evaluation.PSObject.Properties['AttemptedSampleCount']
    $actualSearchWorkUnits += if ($attemptedProperty) { [int]$attemptedProperty.Value } else { @($evaluation.SampleResults).Count }
}
$actualVerificationWorkUnits = 0
foreach ($evaluation in @($searchResult.VerificationEvaluations)) {
    $attemptedProperty = $evaluation.PSObject.Properties['AttemptedSampleCount']
    $actualVerificationWorkUnits += if ($attemptedProperty) { [int]$attemptedProperty.Value } else { @($evaluation.SampleResults).Count }
}
$progressState.TotalUnits = [math]::Max(1, $analysisWindows.Count + $actualSearchSampleCount + $actualVerificationSampleCount + $actualBaselineSampleCount + $actualSearchWorkUnits + $actualVerificationWorkUnits + 1)
Write-EOProgress -Phase 'SEARCH' -Action 'quality search complete' -Detail ("search tests $(@($searchResult.SearchEvaluations).Count) | verification tests $(@($searchResult.VerificationEvaluations).Count) | decision $($searchResult.Decision)")
if (-not $KeepSamples) { Remove-Item -LiteralPath $referenceRoot -Recurse -Force -ErrorAction SilentlyContinue }

$finalSizeEstimate = if ($searchResult.PSObject.Properties['SizeEstimate']) { $searchResult.SizeEstimate } elseif ($searchResult.FinalEvaluation -and $searchResult.FinalEvaluation.PSObject.Properties['SizeEstimate']) { $searchResult.FinalEvaluation.SizeEstimate } else { $null }
$sizeEstimateDisagreementRatio = if ($searchResult.PSObject.Properties['SizeEstimateDisagreementRatio']) { $searchResult.SizeEstimateDisagreementRatio } else { $null }
if ($null -ne $sizeEstimateDisagreementRatio -and [double]$sizeEstimateDisagreementRatio -ge 0.25) {
    $sizeEstimatePercent = [math]::Round([double]$sizeEstimateDisagreementRatio * 100.0, 1)
    $sizeEstimateSource = if ($searchResult.PSObject.Properties['SizeEstimateSource']) { [string]$searchResult.SizeEstimateSource } else { 'conservative' }
    $warnings.Add("Search and verification size estimates differ by $sizeEstimatePercent%; the $sizeEstimateSource estimate is used conservatively.")
}
$hardReasons = @('motion','detail','noise','dark','gradient','scene')
$reasonSet = @($samplePlan.SearchSamples.Reasons | ForEach-Object { $_ } | Where-Object { $_ -in $hardReasons } | Sort-Object -Unique)
$coverageScore = [math]::Min(1.0, (@($samplePlan.SearchSamples).Count + @($samplePlan.VerificationSamples).Count) / 8.0)
$diversityScore = [math]::Min(1.0, $reasonSet.Count / 6.0)
$minimumMargin = if ($searchResult.FinalEvaluation) { [double]$searchResult.FinalEvaluation.MinimumMargin } else { -1.0 }
$metricAgreement = if ($metricPlan.VmafRole -eq 'Primary' -and $metricPlan.Metrics.Count -ge 3) { 0.95 } elseif ($metricPlan.VmafRole -eq 'Primary') { 0.82 } elseif (@($metricPlan.Metrics | Where-Object { $_ -in @('xpsnr','ssim','psnr') }).Count -ge 3) { 0.82 } else { 0.68 }
$edgeFlags = [System.Collections.Generic.List[string]]::new()
if ($sourceProbe.Video.IsHdr) { $edgeFlags.Add('HDR') }
if ($sourceProbe.Video.DolbyVision) { $edgeFlags.Add('DolbyVision') }
if ($sourceProbe.Video.IsVfr) { $edgeFlags.Add('VFR') }
if ($sourceProbe.Video.IsInterlaced) { $edgeFlags.Add('Interlace') }
if (-not $capabilities.HasVmaf) { $edgeFlags.Add('MissingVmaf') }
$confidence = Get-EOConfidence -Coverage $coverageScore -Diversity $diversityScore -MinimumMargin $minimumMargin -MetricAgreement $metricAgreement -VerificationPassed:([bool]$searchResult.VerificationPassed) -SearchStable:([bool]$searchResult.SearchStable) -EdgeCaseFlags @($edgeFlags) -MetricConfidencePenalty ([double]$metricPlan.ConfidencePenalty) -SizeEstimateDisagreementRatio $sizeEstimateDisagreementRatio
$confidence = Set-EOConfidenceCeiling -Confidence $confidence -Ceiling ([string]$safetyGate.ConfidenceCeiling)

$finalOutputPath = $null
$finalCommand = @()
$alternatives = $null
$finalEncoderProfile = $encoderProfile
if ($searchResult.Decision -eq 'ENCODE' -and $null -ne $searchResult.SelectedQuality) {
    $selectedSampleKbps = @(
        $searchResult.AllEvaluations |
            Where-Object { [int]$_.Quality -eq [int]$searchResult.SelectedQuality } |
            ForEach-Object { @($_.SampleResults) } |
            ForEach-Object { if ($null -ne $_.CandidateKbps) { [double]$_.CandidateKbps } }
    )
    $requiredVideoKbps = if ($selectedSampleKbps.Count) {
        [double](($selectedSampleKbps | Measure-Object -Maximum).Maximum)
    } elseif ($finalSizeEstimate -and $null -ne $finalSizeEstimate.VideoKbps) {
        [double]$finalSizeEstimate.VideoKbps
    } else {
        0.0
    }
    $finalEncoderProfile = Resolve-EOFinalEncoderProfile -EncoderProfile $encoderProfile -SourceProbe $sourceProbe -RequiredVideoKbps $requiredVideoKbps
    $finalOutputPath = Get-EOSafeOutputPath -InputPath $inputPath -RequestedPath $OutputPath -Extension $containerPlan.Extension
    $finalCommand = @($resolvedFFmpeg) + @(New-EOFinalEncodeArguments -InputPath $inputPath -OutputPath $finalOutputPath -SourceProbe $sourceProbe -EncoderProfile $finalEncoderProfile -ContainerPlan $containerPlan -StreamPlan $streamPlan -Quality ([int]$searchResult.SelectedQuality) -VideoFilter $VideoFilter)
    $selected = [int]$searchResult.SelectedQuality
    $safer = if ($encoderProfile.BetterDirection -eq 'Lower') { $selected-1 } else { $selected+1 }
    $smaller = if ($encoderProfile.BetterDirection -eq 'Lower') { $selected+1 } else { $selected-1 }
    if ($safer -lt $encoderProfile.SearchMinimum -or $safer -gt $encoderProfile.SearchMaximum) { $safer=$null }
    if ($smaller -lt $encoderProfile.SearchMinimum -or $smaller -gt $encoderProfile.SearchMaximum) { $smaller=$null }
    $alternatives = [pscustomobject]@{ Safer=$safer; Smaller=$smaller }
}

$report = New-EOReport -SourceProbe $sourceProbe -ProfileName $Profile -EncoderName $encoderName -EncoderRationale $encoderRationale -SamplePlan $samplePlan -SearchResult $searchResult -SizeEstimate $finalSizeEstimate -Confidence $confidence -Warnings @($warnings) -FinalCommand $finalCommand -Alternatives $alternatives
$reportPath = Join-Path $workRoot 'report.json'
Write-EOReport -Report $report -Path $reportPath | Out-Null
Write-Host (Format-EOHumanReport -Report $report)
Write-Host "`nReport   : $reportPath"
Write-EOProgress -Phase 'REPORT' -Action 'report written' -Detail ("decision $($searchResult.Decision) | path $reportPath")

$cacheEntry = [pscustomobject]@{
    SchemaVersion=1; PipelineVersion=$pipelineVersion; SourceFingerprint=$fingerprint; Decision=$searchResult.Decision; SelectedQuality=$searchResult.SelectedQuality
    Encoder=$encoderName; Profile=$Profile; Confidence=$confidence.Label; Verified=[bool]$searchResult.VerificationPassed
    SavingsRatio=$searchResult.SavingsRatio; EstimatedBytes=$searchResult.EstimatedBytes; ReportPath=$reportPath; RecordedAt=[DateTimeOffset]::UtcNow.ToString('o')
}
Write-EOCacheEntry -CacheRoot $cacheRoot -Key $cacheKey -Entry $cacheEntry | Out-Null
if ($null -ne $searchResult.SelectedQuality -and $searchResult.VerificationPassed) {
    Add-EOHistoryEntry -CacheRoot $cacheRoot -Entry ([pscustomobject]@{
        PipelineVersion=$pipelineVersion; Encoder=$encoderName; Codec=[string]$sourceProbe.Video.CodecName; ResolutionClass=$resolutionClass; FpsClass=$fpsClass
        BitDepth=[int]$sourceProbe.Video.BitDepth; HdrKind=[string]$sourceProbe.Video.HdrKind; SelectedQuality=[int]$searchResult.SelectedQuality; Verified=$true
    })
}

if ($AutoEncode) {
    if ($searchResult.Decision -ne 'ENCODE') { throw "AutoEncode refused because recommendation is $($searchResult.Decision)." }
    if (-not $safetyGate.AutoEncodeAllowed) { throw "AutoEncode refused by safety policy: $(@($safetyGate.Reasons) -join '; ')" }
    $requiredConfidence = if ($BatchMode) { [string]$policy.BatchAutoConfidence } else { [string]$policy.MinimumConfidence }
    if (-not (Test-EOConfidenceRequirement -Actual $confidence.Label -Required $requiredConfidence)) {
        throw "AutoEncode refused: confidence '$($confidence.Label)' is below required '$requiredConfidence'."
    }
    if (-not $finalOutputPath) { throw 'No final output path was generated.' }
    if (Test-Path -LiteralPath $finalOutputPath) { throw "Refusing to overwrite existing output '$finalOutputPath'." }

    $outputDirectory = Split-Path -Parent $finalOutputPath
    $outputStem = [IO.Path]::GetFileNameWithoutExtension($finalOutputPath)
    $outputExtension = [IO.Path]::GetExtension($finalOutputPath)
    $temporaryOutput = Join-Path $outputDirectory ($outputStem + '.partial.' + [guid]::NewGuid().ToString('N') + $outputExtension)
    try {
        $temporaryArgs = @(New-EOFinalEncodeArguments -InputPath $inputPath -OutputPath $temporaryOutput -SourceProbe $sourceProbe -EncoderProfile $finalEncoderProfile -ContainerPlan $containerPlan -StreamPlan $streamPlan -Quality ([int]$searchResult.SelectedQuality) -VideoFilter $VideoFilter)
        Write-EOProgress -Phase 'FINAL' -Action 'encoding output' -Detail ("quality $($searchResult.SelectedQuality) | output $finalOutputPath")
        Invoke-EOExternalCommand -Executable $resolvedFFmpeg -Arguments $temporaryArgs -Description 'final encode' | Out-Null
        $outputProbe = Get-EOSourceProbe -Path $temporaryOutput -FFprobePath $resolvedFFprobe
        $validation = Test-EOOutputValidation -SourceProbe $sourceProbe -OutputProbe $outputProbe -EncoderProfile $finalEncoderProfile
        if (-not $validation.Passed) { throw "Final output validation failed:`n - $($validation.Failures -join "`n - ")" }
        Move-Item -LiteralPath $temporaryOutput -Destination $finalOutputPath
        Write-Host "Output   : $finalOutputPath"
        Write-EOProgress -Phase 'DONE' -Action 'final output validated' -Detail "path $finalOutputPath" -Complete
    } finally {
        if (Test-Path -LiteralPath $temporaryOutput) { Remove-Item -LiteralPath $temporaryOutput -Force -ErrorAction SilentlyContinue }
    }
}

if (-not $AutoEncode) {
    Write-EOProgress -Phase 'DONE' -Action 'analysis complete' -Detail "decision $($searchResult.Decision) | report $reportPath" -Complete
}

return $report
