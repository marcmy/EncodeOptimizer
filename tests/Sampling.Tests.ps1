BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\lib\Sampling.psm1'
    if (Test-Path $modulePath) { Import-Module $modulePath -Force }

    function New-FeatureWindow {
        param(
            [double]$Start,
            [double]$Motion = 0.2,
            [double]$Detail = 0.2,
            [double]$Noise = 0.1,
            [double]$Dark = 0.1,
            [double]$Gradient = 0.1,
            [double]$Scene = 0.1,
            [double]$Static = 0.0,
            [double]$Black = 0.0
        )
        [pscustomobject]@{
            Start = $Start; Duration = 10.0; Motion = $Motion; Detail = $Detail; Noise = $Noise
            Dark = $Dark; Gradient = $Gradient; Scene = $Scene; Static = $Static; Black = $Black
        }
    }
}

Describe 'content-aware sample selection' {
    It 'does not mistake temporal motion variance for image noise when bit-plane noise is low' {
        $window = [pscustomobject]@{ Start = 12.345; Duration = 4.0 }
        $runner = {
            param($Executable, $Arguments)
            @'
lavfi.signalstats.YAVG=100
lavfi.signalstats.YLOW=20
lavfi.signalstats.YHIGH=220
lavfi.signalstats.YDIF=1
lavfi.bitplanenoise.0.1=0.015
lavfi.scd.score=0
lavfi.signalstats.YAVG=100
lavfi.signalstats.YLOW=20
lavfi.signalstats.YHIGH=220
lavfi.signalstats.YDIF=40
lavfi.bitplanenoise.0.1=0.020
lavfi.scd.score=0
lavfi.signalstats.YAVG=100
lavfi.signalstats.YLOW=20
lavfi.signalstats.YHIGH=220
lavfi.signalstats.YDIF=2
lavfi.bitplanenoise.0.1=0.018
lavfi.scd.score=0
'@
        }

        $feature = @(Get-EOContentFeatures -Path 'synthetic.mp4' -AnalysisWindows @($window) -FFmpegPath 'ffmpeg' -CommandRunner $runner)[0]

        $feature.Motion | Should -BeGreaterThan 0.4
        $feature.Noise | Should -BeLessThan 0.25
    }

    It 'provides disjoint search and verification samples with broad temporal coverage' {
        Get-Command Select-EOSamples -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $windows = 0..11 | ForEach-Object { New-FeatureWindow -Start ($_ * 10) -Motion (0.15 + ($_ % 4) * 0.1) -Detail (0.2 + ($_ % 3) * 0.1) }
        $selection = Select-EOSamples -FeatureWindows $windows -Duration 120 -SearchCount 6 -VerificationCount 2 -SampleDuration 10

        $selection.SearchSamples.Count | Should -Be 6
        $selection.VerificationSamples.Count | Should -Be 2
        $searchStarts = @($selection.SearchSamples.Start)
        $verifyStarts = @($selection.VerificationSamples.Start)
        @($searchStarts | Where-Object { $verifyStarts -contains $_ }).Count | Should -Be 0
        ($searchStarts | Measure-Object -Minimum).Minimum | Should -BeLessThan 30
        ($searchStarts | Measure-Object -Maximum).Maximum | Should -BeGreaterThan 80
    }

    It 'keeps independent verification clips temporally non-overlapping when enough windows exist' {
        $windows = 0..11 | ForEach-Object { New-FeatureWindow -Start ($_ * 5) }
        $selection = Select-EOSamples -FeatureWindows $windows -Duration 65 -SearchCount 4 -VerificationCount 2 -SampleDuration 10

        $selection.VerificationSamples.Count | Should -Be 2
        foreach ($verify in $selection.VerificationSamples) {
            foreach ($search in $selection.SearchSamples) {
                $overlaps = ([double]$verify.Start -lt ([double]$search.Start + [double]$search.Duration)) -and
                            ([double]$search.Start -lt ([double]$verify.Start + [double]$verify.Duration))
                $overlaps | Should -BeFalse
            }
        }
    }

    It 'deliberately includes difficult motion detail noise dark gradient and scene-change content' {
        $windows = @(
            (New-FeatureWindow 0),
            (New-FeatureWindow 10 -Motion 1.0),
            (New-FeatureWindow 20 -Detail 1.0),
            (New-FeatureWindow 30 -Noise 1.0),
            (New-FeatureWindow 40 -Dark 1.0),
            (New-FeatureWindow 50 -Gradient 1.0),
            (New-FeatureWindow 60 -Scene 1.0),
            (New-FeatureWindow 70),
            (New-FeatureWindow 80),
            (New-FeatureWindow 90)
        )
        $selection = Select-EOSamples -FeatureWindows $windows -Duration 100 -SearchCount 7 -VerificationCount 2 -SampleDuration 10
        $reasons = @($selection.SearchSamples | ForEach-Object { $_.Reasons })

        $reasons | Should -Contain 'motion'
        $reasons | Should -Contain 'detail'
        $reasons | Should -Contain 'noise'
        $reasons | Should -Contain 'dark'
        $reasons | Should -Contain 'gradient'
        $reasons | Should -Contain 'scene'
    }

    It 'de-weights black and frozen content when informative alternatives exist' {
        $windows = @(
            (New-FeatureWindow 0 -Black 1.0),
            (New-FeatureWindow 10 -Static 1.0),
            (New-FeatureWindow 20 -Motion 0.8),
            (New-FeatureWindow 30 -Detail 0.8),
            (New-FeatureWindow 40 -Noise 0.7),
            (New-FeatureWindow 50 -Scene 0.8),
            (New-FeatureWindow 60 -Dark 0.7),
            (New-FeatureWindow 70 -Gradient 0.7)
        )
        $selection = Select-EOSamples -FeatureWindows $windows -Duration 80 -SearchCount 4 -VerificationCount 2 -SampleDuration 10
        @($selection.SearchSamples | Where-Object { $_.Start -in @(0,10) }).Count | Should -Be 0
    }

    It 'adapts clip length and count safely for short sources' {
        $windows = @((New-FeatureWindow 0 -Motion 0.6), (New-FeatureWindow 8 -Detail 0.7))
        $selection = Select-EOSamples -FeatureWindows $windows -Duration 18 -SearchCount 6 -VerificationCount 2 -SampleDuration 10

        $selection.SearchSamples.Count | Should -BeGreaterThan 0
        ($selection.SearchSamples.Count + $selection.VerificationSamples.Count) | Should -BeLessOrEqual 2
        @($selection.SearchSamples + $selection.VerificationSamples | Where-Object { ($_.Start + $_.Duration) -gt 18.0001 }).Count | Should -Be 0
    }

    It 'creates deterministic analysis windows across the full duration' {
        Get-Command Get-EOAnalysisWindows -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $windows = Get-EOAnalysisWindows -Duration 100 -WindowDuration 10 -WindowCount 8
        $windows.Count | Should -Be 8
        $windows[0].Start | Should -Be 0
        $windows[-1].Start | Should -Be 90
    }
}
