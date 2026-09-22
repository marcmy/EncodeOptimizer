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
$pipelineVersion = 'deterministic-reference-v9-analysis-matroska'
$encoderSignature = (@($encoderProfile.Arguments) + @($encoderProfile.AnalysisArguments) + @($encoderProfile.QualityControl,$encoderProfile.SearchMinimum,$encoderProfile.SearchMaximum)) -join '|'
$policySignature = @($policy.MeanVmaf,$policy.WorstSampleVmaf,$policy.P05Vmaf,$policy.MinimumXpsnr,$policy.MinimumSsim,$policy.MinimumPsnr,$policy.MinimumSavingsRatio) -join '|'
$cacheRoot = Get-EODefaultCacheRoot
$cacheKey = Get-EOCacheKey -SourceFingerprint $fingerprint -VideoFilter $VideoFilter -EncoderName $encoderName -EncoderSignature $encoderSignature -FFmpegVersion $capabilities.Version -PolicyName $Profile -PolicySignature $policySignature -PipelineVersion $pipelineVersion
$workRoot = Join-Path (Join-Path $cacheRoot 'work') $cacheKey
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

$analysisWindows = Get-EOAnalysisWindows -Duration $samplingDuration
Write-Host "Analyzing content complexity ($($analysisWindows.Count) windows)..."
$features = Get-EOContentFeatures -Path $inputPath -AnalysisWindows $analysisWindows -FFmpegPath $resolvedFFmpeg
$samplePlan = Select-EOSamples -FeatureWindows $features -Duration $samplingDuration

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

Write-Host 'Preparing deterministic lossless reference samples...'
foreach ($phase in @('Search','Verification')) {
    $phaseSamples = if ($phase -eq 'Search') { @($samplePlan.SearchSamples) } else { @($samplePlan.VerificationSamples) }
    for ($i = 0; $i -lt $phaseSamples.Count; $i++) {
        $sample = $phaseSamples[$i]
        $referencePath = Join-Path $referenceRoot ("$phase-s$($i + 1).mkv")
        $referenceArgs = @(New-EOReferenceSampleArguments -InputPath $inputPath -OutputPath $referencePath -Start ([double]$sample.Start) -Duration ([double]$sample.Duration) -VideoFilter $VideoFilter)
        Invoke-EOExternalCommand -Executable $resolvedFFmpeg -Arguments $referenceArgs -Description "$phase reference sample $($i + 1)" | Out-Null
        $referencePaths[$phase].Add($referencePath)
    }
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
    Write-Host 'Calibrating VMAF reference baselines...'
    foreach ($phase in @('Search','Verification')) {
        $phaseSamples = if ($phase -eq 'Search') { @($samplePlan.SearchSamples) } else { @($samplePlan.VerificationSamples) }
        for ($i = 0; $i -lt $phaseSamples.Count; $i++) {
            $sample = $phaseSamples[$i]
            $referencePath = $referencePaths[$phase][$i]
            $baselineDirectory = Join-Path $workRoot ("baseline-$Phase-s$($i + 1)")
            if (Test-Path -LiteralPath $baselineDirectory) { Remove-Item -LiteralPath $baselineDirectory -Recurse -Force }
            $baseline = Invoke-EOMetrics -ReferencePath $referencePath -CandidatePath $referencePath -MetricPlan $baselineMetricPlan -ReferenceStart 0 -Duration ([double]$sample.Duration) -SampleName ("$Phase-$($i + 1)") -FFmpegPath $resolvedFFmpeg -WorkDirectory $baselineDirectory
            $baseline.Start = [double]$sample.Start
            $vmafBaselines[$phase].Add($baseline)
            if (-not $KeepSamples) {
                Remove-Item -LiteralPath $baselineDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
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
    $sampleIndex = 0
    foreach ($sample in @($Samples)) {
        $sampleIndex++
        $sampleDirectory = Join-Path $workRoot ("$Phase-q$Quality-s$sampleIndex-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $sampleDirectory -Force | Out-Null
        $candidatePath = Join-Path $sampleDirectory ('candidate' + $analysisContainerPlan.Extension)
        $referencePath = $referencePaths[$Phase][$sampleIndex - 1]
        $videoOnly = [pscustomobject]@{ Arguments=@('-map','0:v:0'); Warnings=@() }
        $candidateArgs = @(New-EOFinalEncodeArguments -InputPath $referencePath -OutputPath $candidatePath -SourceProbe $sourceProbe -EncoderProfile $encoderProfile -ContainerPlan $analysisContainerPlan -StreamPlan $videoOnly -Quality ([int]$Quality) -Analysis)
        Invoke-EOExternalCommand -Executable $resolvedFFmpeg -Arguments $candidateArgs -Description "candidate sample encode q$Quality" | Out-Null

        $metricDirectory = Join-Path $sampleDirectory 'metrics'
        $metric = Invoke-EOMetrics -ReferencePath $referencePath -CandidatePath $candidatePath -MetricPlan $sampleMetricPlan -ReferenceStart 0 -Duration ([double]$sample.Duration) -SampleName ("$Phase-$sampleIndex") -FFmpegPath $resolvedFFmpeg -WorkDirectory $metricDirectory
        $metric.Start = [double]$sample.Start
        $metric | Add-Member -NotePropertyName Complexity -NotePropertyValue (Get-EOSampleComplexity $sample) -Force
        $metricSamples.Add($metric)
        $sizeSamples.Add([pscustomobject]@{ CandidateKbps=$metric.CandidateKbps; Complexity=$metric.Complexity; Duration=[double]$sample.Duration })

        if (-not $KeepSamples) {
            Remove-Item -LiteralPath $candidatePath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $metricDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $aggregateParameters = @{ Samples=@($metricSamples); VmafRole=$sampleMetricPlan.VmafRole }
    $baselineSamples = @($vmafBaselines[$Phase])
    if ($baselineSamples.Count) { $aggregateParameters.VmafBaselineSamples = $baselineSamples }
    $aggregate = Measure-EOMetricAggregate @aggregateParameters
    $policyDecision = Test-EOQualityPolicy -Aggregate $aggregate -Policy $policy
    $sizeEstimate = Estimate-EOOutputSize -SampleResults @($sizeSamples) -DurationSeconds $containerDuration -PopulationComplexities $populationComplexities -AuxiliaryBitrateKbps $auxiliaryKbps
    return [pscustomobject]@{
        Quality=$Quality; Phase=$Phase; Passed=$policyDecision.Passed; MinimumMargin=$policyDecision.MinimumMargin; AuthoritativeMetric=$policyDecision.AuthoritativeMetric
        MeanVmaf=$aggregate.MeanVmaf; WorstSampleVmaf=$aggregate.WorstSampleVmaf; P05Vmaf=$aggregate.P05Vmaf
        RelativeMeanVmaf=$aggregate.RelativeMeanVmaf; RelativeWorstSampleVmaf=$aggregate.RelativeWorstSampleVmaf; RelativeP05Vmaf=$aggregate.RelativeP05Vmaf
        MeanXpsnr=$aggregate.MeanXpsnr; MeanSsim=$aggregate.MeanSsim; MeanPsnr=$aggregate.MeanPsnr
        EstimatedBytes=$sizeEstimate.EstimatedBytes; SizeEstimate=$sizeEstimate; SampleResults=@($metricSamples); Aggregate=$aggregate; Failures=@($policyDecision.Failures)
    }
}

Write-Host "Searching $($encoderProfile.QualityControl) boundary with $encoderName..."
$searchParameters = @{
    EncoderProfile=$encoderProfile; Policy=$policy; SearchSamples=@($samplePlan.SearchSamples); VerificationSamples=@($samplePlan.VerificationSamples)
    Evaluator=$evaluator; SourceBytes=$sourceBytes; MinimumSavingsRatio=[double]$policy.MinimumSavingsRatio; TransformationRequired=$transformationRequired; ForceEncode=$ForceEncode
}
if ($null -ne $historySeed) { $searchParameters.SeedQuality = [int]$historySeed }
$searchResult = Find-EOOptimalQuality @searchParameters
if (-not $KeepSamples) { Remove-Item -LiteralPath $referenceRoot -Recurse -Force -ErrorAction SilentlyContinue }

$finalSizeEstimate = if ($searchResult.FinalEvaluation -and $searchResult.FinalEvaluation.PSObject.Properties['SizeEstimate']) { $searchResult.FinalEvaluation.SizeEstimate } else { $null }
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
$confidence = Get-EOConfidence -Coverage $coverageScore -Diversity $diversityScore -MinimumMargin $minimumMargin -MetricAgreement $metricAgreement -VerificationPassed:([bool]$searchResult.VerificationPassed) -SearchStable:([bool]$searchResult.SearchStable) -EdgeCaseFlags @($edgeFlags) -MetricConfidencePenalty ([double]$metricPlan.ConfidencePenalty)
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
        Write-Host "`nEncoding to temporary output..."
        Invoke-EOExternalCommand -Executable $resolvedFFmpeg -Arguments $temporaryArgs -Description 'final encode' | Out-Null
        $outputProbe = Get-EOSourceProbe -Path $temporaryOutput -FFprobePath $resolvedFFprobe
        $validation = Test-EOOutputValidation -SourceProbe $sourceProbe -OutputProbe $outputProbe -EncoderProfile $finalEncoderProfile
        if (-not $validation.Passed) { throw "Final output validation failed:`n - $($validation.Failures -join "`n - ")" }
        Move-Item -LiteralPath $temporaryOutput -Destination $finalOutputPath
        Write-Host "Output   : $finalOutputPath"
    } finally {
        if (Test-Path -LiteralPath $temporaryOutput) { Remove-Item -LiteralPath $temporaryOutput -Force -ErrorAction SilentlyContinue }
    }
}

return $report
