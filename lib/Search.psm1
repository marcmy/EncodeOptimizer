Set-StrictMode -Version Latest

function Get-EOSearchProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Limit-EOScore {
    param([double]$Value)
    return [math]::Max(0.0, [math]::Min(1.0, $Value))
}

function Estimate-EOOutputSize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $SampleResults,
        [Parameter(Mandatory)] [double] $DurationSeconds,
        [double] $AuxiliaryBitrateKbps = 0.0,
        [double] $ContainerOverheadRatio = 0.005
    )

    if ($DurationSeconds -le 0) { throw 'DurationSeconds must be greater than zero.' }
    $usable = @($SampleResults | Where-Object { $null -ne (Get-EOSearchProperty $_ 'CandidateKbps') -and [double](Get-EOSearchProperty $_ 'CandidateKbps') -gt 0 })
    if ($usable.Count -eq 0) { throw 'At least one sample with CandidateKbps is required.' }

    $weightedTotal = 0.0
    $weightTotal = 0.0
    $bitrates = [System.Collections.Generic.List[double]]::new()
    foreach ($sample in $usable) {
        $kbps = [double](Get-EOSearchProperty $sample 'CandidateKbps')
        $complexity = Limit-EOScore ([double](Get-EOSearchProperty $sample 'Complexity' 0.5))
        $sampleDuration = [math]::Max(0.25, [double](Get-EOSearchProperty $sample 'Duration' 1.0))
        # Difficult samples deserve more influence, but never enough to let one clip dominate.
        $weight = $sampleDuration * (0.5 + $complexity)
        $weightedTotal += $kbps * $weight
        $weightTotal += $weight
        $bitrates.Add($kbps)
    }

    $videoKbps = $weightedTotal / $weightTotal
    $mean = ($bitrates | Measure-Object -Average).Average
    $stddev = 0.0
    if ($bitrates.Count -gt 1 -and $mean -gt 0) {
        $variance = (($bitrates | ForEach-Object { [math]::Pow($_ - $mean, 2) }) | Measure-Object -Average).Average
        $stddev = [math]::Sqrt($variance)
    }
    $coefficientVariation = if ($mean -gt 0) { $stddev / $mean } else { 0.0 }
    $uncertainty = [math]::Max(0.08, [math]::Min(0.30, 0.75 * $coefficientVariation))

    $overhead = [math]::Max(0.0, $ContainerOverheadRatio)
    $totalKbps = $videoKbps + [math]::Max(0.0, $AuxiliaryBitrateKbps)
    $estimatedBytes = ($DurationSeconds * $totalKbps * 1000.0 / 8.0) * (1.0 + $overhead)
    $lowerKbps = ($videoKbps * (1.0 - $uncertainty)) + [math]::Max(0.0, $AuxiliaryBitrateKbps)
    $upperKbps = ($videoKbps * (1.0 + $uncertainty)) + [math]::Max(0.0, $AuxiliaryBitrateKbps)

    return [pscustomobject]@{
        VideoKbps              = $videoKbps
        AuxiliaryKbps          = [double]$AuxiliaryBitrateKbps
        TotalKbps              = $totalKbps
        EstimatedBytes         = [long][math]::Round($estimatedBytes)
        LowerBytes             = [long][math]::Round(($DurationSeconds * $lowerKbps * 1000.0 / 8.0) * (1.0 + $overhead))
        UpperBytes             = [long][math]::Round(($DurationSeconds * $upperKbps * 1000.0 / 8.0) * (1.0 + $overhead))
        UncertaintyRatio       = $uncertainty
        ContainerOverheadRatio = $overhead
        SampleCount            = $usable.Count
    }
}

function Get-EOConfidence {
    [CmdletBinding()]
    param(
        [double] $Coverage = 0.0,
        [double] $Diversity = 0.0,
        [double] $MinimumMargin = -1.0,
        [double] $MetricAgreement = 0.0,
        [switch] $VerificationPassed,
        [switch] $SearchStable,
        [string[]] $EdgeCaseFlags = @(),
        [double] $MetricConfidencePenalty = 0.0
    )

    $coverageScore = Limit-EOScore $Coverage
    $diversityScore = Limit-EOScore $Diversity
    $marginScore = Limit-EOScore (($MinimumMargin + 0.2) / 1.0)
    $agreementScore = Limit-EOScore $MetricAgreement

    $score = 0.20*$coverageScore + 0.18*$diversityScore + 0.20*$marginScore + 0.17*$agreementScore
    if ($VerificationPassed) { $score += 0.15 }
    if ($SearchStable) { $score += 0.10 }

    $reasons = [System.Collections.Generic.List[string]]::new()
    if (-not $VerificationPassed) { $reasons.Add('Independent verification did not pass cleanly.') }
    if (-not $SearchStable) { $reasons.Add('Search and verification were not stable at the same boundary.') }
    if ($coverageScore -lt 0.7) { $reasons.Add('Temporal/content coverage is limited.') }
    if ($diversityScore -lt 0.7) { $reasons.Add('Sample diversity is limited.') }
    if ($MinimumMargin -lt 0.25) { $reasons.Add('Quality margin is close to the policy boundary.') }

    $edgePenalties = @{
        HDR = 0.12
        DolbyVision = 0.50
        VFR = 0.05
        Interlace = 0.12
        MissingVmaf = 0.12
        MetricAlignment = 0.20
        AmbiguousColor = 0.15
    }
    foreach ($flag in @($EdgeCaseFlags | Select-Object -Unique)) {
        $reasons.Add("Edge case: $flag")
        if ($edgePenalties.ContainsKey($flag)) { $score -= [double]$edgePenalties[$flag] } else { $score -= 0.05 }
    }
    $score -= [math]::Max(0.0, $MetricConfidencePenalty)
    $score = Limit-EOScore $score

    $label = if ($score -ge 0.80) { 'HIGH' } elseif ($score -ge 0.60) { 'MEDIUM' } else { 'LOW' }
    return [pscustomobject]@{
        Label = $label
        Score = $score
        Reasons = @($reasons)
        Coverage = $coverageScore
        Diversity = $diversityScore
        MinimumMargin = $MinimumMargin
        MetricAgreement = $agreementScore
        VerificationPassed = [bool]$VerificationPassed
        SearchStable = [bool]$SearchStable
        EdgeCaseFlags = @($EdgeCaseFlags)
    }
}

function Invoke-EOSearchEvaluator {
    param(
        [scriptblock]$Evaluator,
        [int]$Quality,
        [object[]]$Samples,
        [string]$Phase
    )
    $result = & $Evaluator $Quality $Samples $Phase
    if ($null -eq $result) { throw "Evaluator returned no result for quality $Quality ($Phase)." }
    if ($null -eq (Get-EOSearchProperty $result 'Passed')) { throw 'Evaluator results must expose a Passed property.' }
    if ($null -eq (Get-EOSearchProperty $result 'Quality')) {
        $result | Add-Member -NotePropertyName Quality -NotePropertyValue $Quality -Force
    }
    if ($null -eq (Get-EOSearchProperty $result 'Phase')) {
        $result | Add-Member -NotePropertyName Phase -NotePropertyValue $Phase -Force
    }
    return $result
}

function Find-EOOptimalQuality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $EncoderProfile,
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] [object[]] $SearchSamples,
        [Parameter(Mandatory)] [object[]] $VerificationSamples,
        [Parameter(Mandatory)] [scriptblock] $Evaluator,
        [long] $SourceBytes = 0,
        [Nullable[double]] $MinimumSavingsRatio,
        [Nullable[int]] $SeedQuality,
        [int] $MaxSearchEvaluations = 10,
        [switch] $TransformationRequired,
        [switch] $ForceEncode
    )

    $minimum = [int](Get-EOSearchProperty $EncoderProfile 'SearchMinimum')
    $maximum = [int](Get-EOSearchProperty $EncoderProfile 'SearchMaximum')
    if ($minimum -gt $maximum) { throw 'EncoderProfile SearchMinimum must not exceed SearchMaximum.' }
    $direction = [string](Get-EOSearchProperty $EncoderProfile 'BetterDirection' 'Lower')
    if ($direction -notin @('Lower','Higher')) { throw "Unsupported BetterDirection '$direction'." }
    $start = if ($null -ne $SeedQuality) { [int]$SeedQuality } else { [int](Get-EOSearchProperty $EncoderProfile 'DefaultStart' ([math]::Floor(($minimum+$maximum)/2))) }
    $start = [math]::Max($minimum, [math]::Min($maximum, $start))
    $maxEvals = [math]::Max(1, $MaxSearchEvaluations)
    $requiredSavings = if ($null -ne $MinimumSavingsRatio) { [double]$MinimumSavingsRatio } else { [double](Get-EOSearchProperty $Policy 'MinimumSavingsRatio' 0.12) }

    $searchResults = [System.Collections.Generic.List[object]]::new()
    $searchCache = @{}
    function Evaluate-Search([int]$Quality) {
        if ($searchCache.ContainsKey($Quality)) { return $searchCache[$Quality] }
        if ($searchResults.Count -ge $maxEvals) { return $null }
        $result = Invoke-EOSearchEvaluator -Evaluator $Evaluator -Quality $Quality -Samples $SearchSamples -Phase 'Search'
        $searchCache[$Quality] = $result
        $searchResults.Add($result)
        return $result
    }

    $first = Evaluate-Search $start
    $bestQuality = $null
    $low = $minimum
    $high = $maximum

    if ($direction -eq 'Lower') {
        # Lower numeric values are safer/better. The optimal compression point is the highest passing value.
        if ([bool]$first.Passed) {
            $bestQuality = $start
            $low = $start + 1
        } else {
            $high = $start - 1
        }
        while ($low -le $high -and $searchResults.Count -lt $maxEvals) {
            $candidate = [int][math]::Floor(($low + $high) / 2.0)
            $result = Evaluate-Search $candidate
            if ($null -eq $result) { break }
            if ([bool]$result.Passed) {
                $bestQuality = $candidate
                $low = $candidate + 1
            } else {
                $high = $candidate - 1
            }
        }
    } else {
        # Higher numeric values are safer/better. The optimal compression point is the lowest passing value.
        if ([bool]$first.Passed) {
            $bestQuality = $start
            $high = $start - 1
        } else {
            $low = $start + 1
        }
        while ($low -le $high -and $searchResults.Count -lt $maxEvals) {
            $candidate = [int][math]::Floor(($low + $high) / 2.0)
            $result = Evaluate-Search $candidate
            if ($null -eq $result) { break }
            if ([bool]$result.Passed) {
                $bestQuality = $candidate
                $high = $candidate - 1
            } else {
                $low = $candidate + 1
            }
        }
    }

    $rationale = [System.Collections.Generic.List[string]]::new()
    $verificationResults = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $bestQuality) {
        $rationale.Add('No tested quality setting satisfied the search quality policy.')
        return [pscustomobject]@{
            Decision = 'KEEP_SOURCE'
            SelectedQuality = $null
            SearchEvaluations = @($searchResults)
            VerificationEvaluations = @()
            AllEvaluations = @($searchResults)
            FinalEvaluation = $null
            EstimatedBytes = $null
            SavingsRatio = $null
            MinimumSavingsRatio = $requiredSavings
            Rationale = @($rationale)
            SearchStable = $false
            VerificationPassed = $false
        }
    }

    $selectedQuality = [int]$bestQuality
    $searchWinner = $searchCache[$selectedQuality]
    $verified = $false
    $initialVerificationQuality = $selectedQuality

    if ($VerificationSamples.Count -eq 0) {
        $verified = $true
        $rationale.Add('No independent verification samples were available; confidence must be reduced.')
    } else {
        while ($selectedQuality -ge $minimum -and $selectedQuality -le $maximum) {
            $verify = Invoke-EOSearchEvaluator -Evaluator $Evaluator -Quality $selectedQuality -Samples $VerificationSamples -Phase 'Verification'
            $verificationResults.Add($verify)
            if ([bool]$verify.Passed) { $verified = $true; break }
            $next = if ($direction -eq 'Lower') { $selectedQuality - 1 } else { $selectedQuality + 1 }
            if ($next -lt $minimum -or $next -gt $maximum) { break }
            $selectedQuality = $next
        }
    }

    if (-not $verified) {
        $rationale.Add('Independent verification could not find a safe quality setting.')
        return [pscustomobject]@{
            Decision = 'KEEP_SOURCE'
            SelectedQuality = $null
            SearchEvaluations = @($searchResults)
            VerificationEvaluations = @($verificationResults)
            AllEvaluations = @($searchResults) + @($verificationResults)
            FinalEvaluation = $null
            EstimatedBytes = $null
            SavingsRatio = $null
            MinimumSavingsRatio = $requiredSavings
            Rationale = @($rationale)
            SearchStable = $false
            VerificationPassed = $false
        }
    }

    if ($selectedQuality -ne $initialVerificationQuality) {
        $rationale.Add("Independent verification required a safer setting: $initialVerificationQuality -> $selectedQuality.")
    }

    $finalResult = if ($verificationResults.Count) { $verificationResults[-1] } elseif ($searchCache.ContainsKey($selectedQuality)) { $searchCache[$selectedQuality] } else { $searchWinner }
    $estimatedBytes = Get-EOSearchProperty $finalResult 'EstimatedBytes'
    if ($null -eq $estimatedBytes -and $searchCache.ContainsKey($selectedQuality)) { $estimatedBytes = Get-EOSearchProperty $searchCache[$selectedQuality] 'EstimatedBytes' }
    $savingsRatio = if ($SourceBytes -gt 0 -and $null -ne $estimatedBytes) { 1.0 - ([double]$estimatedBytes / [double]$SourceBytes) } else { $null }

    $decision = 'ENCODE'
    if (-not $TransformationRequired -and -not $ForceEncode -and $null -ne $savingsRatio -and $savingsRatio -lt $requiredSavings) {
        $decision = 'KEEP_SOURCE'
        $rationale.Add("Estimated savings of $([math]::Round($savingsRatio*100,1))% are below the required $([math]::Round($requiredSavings*100,1))% threshold.")
    } elseif ($decision -eq 'ENCODE') {
        $rationale.Add("Quality $selectedQuality passed independent verification.")
    }

    return [pscustomobject]@{
        Decision = $decision
        SelectedQuality = $selectedQuality
        SearchEvaluations = @($searchResults)
        VerificationEvaluations = @($verificationResults)
        AllEvaluations = @($searchResults) + @($verificationResults)
        FinalEvaluation = $finalResult
        EstimatedBytes = $estimatedBytes
        SavingsRatio = $savingsRatio
        MinimumSavingsRatio = $requiredSavings
        Rationale = @($rationale)
        SearchStable = ($selectedQuality -eq $initialVerificationQuality)
        VerificationPassed = $verified
    }
}

Export-ModuleMember -Function Find-EOOptimalQuality, Estimate-EOOutputSize, Get-EOConfidence
