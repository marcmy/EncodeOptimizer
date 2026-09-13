BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\lib\Search.psm1'
    if (Test-Path $modulePath) { Import-Module $modulePath -Force }
    $profiles = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\config\quality-profiles.psd1')

    function New-TestEncoderProfile {
        [pscustomobject]@{
            Name = 'hevc_nvenc'
            QualityControl = 'CQ'
            QualityOption = '-cq'
            SearchMinimum = 10
            SearchMaximum = 30
            DefaultStart = 18
            BetterDirection = 'Lower'
            Hardware = $true
        }
    }

    function New-FakeResult {
        param([int]$Quality, [bool]$Passed, [string]$Phase, [long]$EstimatedBytes = 70000000)
        [pscustomobject]@{
            Quality = $Quality
            Passed = $Passed
            Phase = $Phase
            MinimumMargin = if ($Passed) { 0.4 + ((18 - $Quality) * 0.1) } else { -0.3 }
            MeanVmaf = if ($Passed) { 98.2 } else { 97.4 }
            WorstSampleVmaf = if ($Passed) { 97.3 } else { 96.2 }
            P05Vmaf = if ($Passed) { 95.4 } else { 94.2 }
            EstimatedBytes = $EstimatedBytes
        }
    }
}

Describe 'adaptive quality search' {
    It 'provides the search module and public commands' {
        Test-Path $modulePath | Should -BeTrue
        foreach ($name in 'Find-EOOptimalQuality','Estimate-EOOutputSize','Get-EOConfidence') {
            Get-Command $name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    It 'finds the smallest worst passing CQ without brute-forcing the range' {
        $encoder = New-TestEncoderProfile
        $evaluator = {
            param($Quality, $Samples, $Phase)
            New-FakeResult -Quality $Quality -Passed:($Quality -le 17) -Phase $Phase
        }
        $result = Find-EOOptimalQuality -EncoderProfile $encoder -Policy $profiles.Conservative -SearchSamples @('s1','s2') -VerificationSamples @('v1') -Evaluator $evaluator -SourceBytes 100000000 -MinimumSavingsRatio 0.12

        $result.Decision | Should -Be 'ENCODE'
        $result.SelectedQuality | Should -Be 17
        $result.SearchEvaluations.Count | Should -BeLessThan 10
        @($result.SearchEvaluations.Quality | Sort-Object -Unique).Count | Should -Be $result.SearchEvaluations.Count
    }

    It 'moves one or more steps safer when independent verification rejects the search winner' {
        $encoder = New-TestEncoderProfile
        $evaluator = {
            param($Quality, $Samples, $Phase)
            $passes = if ($Phase -eq 'Verification') { $Quality -le 16 } else { $Quality -le 17 }
            New-FakeResult -Quality $Quality -Passed:$passes -Phase $Phase
        }
        $result = Find-EOOptimalQuality -EncoderProfile $encoder -Policy $profiles.Conservative -SearchSamples @('s1') -VerificationSamples @('v1','v2') -Evaluator $evaluator -SourceBytes 100000000

        $result.SelectedQuality | Should -Be 16
        $result.VerificationEvaluations[0].Quality | Should -Be 17
        $result.VerificationEvaluations[-1].Quality | Should -Be 16
        $result.VerificationEvaluations[-1].Passed | Should -BeTrue
    }

    It 'returns KEEP_SOURCE when measured savings are below policy and no transform requires an encode' {
        $encoder = New-TestEncoderProfile
        $evaluator = {
            param($Quality, $Samples, $Phase)
            New-FakeResult -Quality $Quality -Passed:($Quality -le 17) -Phase $Phase -EstimatedBytes 95000000
        }
        $result = Find-EOOptimalQuality -EncoderProfile $encoder -Policy $profiles.Conservative -SearchSamples @('s1') -VerificationSamples @('v1') -Evaluator $evaluator -SourceBytes 100000000 -MinimumSavingsRatio 0.12

        $result.Decision | Should -Be 'KEEP_SOURCE'
        $result.SavingsRatio | Should -BeLessThan 0.12
        $result.Rationale -join ' ' | Should -Match 'savings'
    }

    It 'does not KEEP_SOURCE merely for low savings when a requested transform makes re-encoding mandatory' {
        $encoder = New-TestEncoderProfile
        $evaluator = {
            param($Quality, $Samples, $Phase)
            New-FakeResult -Quality $Quality -Passed:($Quality -le 17) -Phase $Phase -EstimatedBytes 98000000
        }
        $result = Find-EOOptimalQuality -EncoderProfile $encoder -Policy $profiles.Conservative -SearchSamples @('s1') -VerificationSamples @('v1') -Evaluator $evaluator -SourceBytes 100000000 -MinimumSavingsRatio 0.12 -TransformationRequired

        $result.Decision | Should -Be 'ENCODE'
        $result.SelectedQuality | Should -Be 17
    }
}

Describe 'output-size estimation' {
    It 'complexity-weights sample bitrate and returns an uncertainty range plus copied-stream overhead' {
        $samples = @(
            [pscustomobject]@{ CandidateKbps = 900.0; Complexity = 0.25; Duration = 10.0 },
            [pscustomobject]@{ CandidateKbps = 1500.0; Complexity = 1.00; Duration = 10.0 },
            [pscustomobject]@{ CandidateKbps = 1100.0; Complexity = 0.60; Duration = 10.0 }
        )
        $estimate = Estimate-EOOutputSize -SampleResults $samples -DurationSeconds 600 -AuxiliaryBitrateKbps 128 -ContainerOverheadRatio 0.005

        $estimate.VideoKbps | Should -BeGreaterThan 1100
        $estimate.EstimatedBytes | Should -BeGreaterThan 0
        $estimate.LowerBytes | Should -BeLessThan $estimate.EstimatedBytes
        $estimate.UpperBytes | Should -BeGreaterThan $estimate.EstimatedBytes
        $estimate.AuxiliaryKbps | Should -Be 128
    }
}

Describe 'recommendation confidence' {
    It 'grades broad stable verification with healthy margin as HIGH' {
        $confidence = Get-EOConfidence -Coverage 0.95 -Diversity 0.90 -MinimumMargin 0.8 -MetricAgreement 0.95 -VerificationPassed -SearchStable
        $confidence.Label | Should -Be 'HIGH'
        $confidence.Score | Should -BeGreaterOrEqual 0.80
    }

    It 'drops confidence for edge cases and unstable verification' {
        $confidence = Get-EOConfidence -Coverage 0.70 -Diversity 0.65 -MinimumMargin 0.1 -MetricAgreement 0.70 -EdgeCaseFlags @('HDR','Interlace','MissingVmaf') -MetricConfidencePenalty 0.20
        $confidence.Label | Should -Be 'LOW'
        $confidence.Reasons -join ' ' | Should -Match 'HDR|Interlace|MissingVmaf'
    }
}
