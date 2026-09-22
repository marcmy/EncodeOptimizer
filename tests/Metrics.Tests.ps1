BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\lib\Metrics.psm1'
    if (Test-Path $modulePath) { Import-Module $modulePath -Force }
    $profiles = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\config\quality-profiles.psd1')

    function New-MetricSample {
        param(
            [string]$Name,
            [double[]]$Vmaf,
            [double]$Xpsnr = 48.0,
            [double]$Ssim = 0.993,
            [double]$Psnr = 49.0,
            [double]$Start = 0.0,
            [double]$Duration = 10.0,
            [double]$CandidateKbps = 1234.5
        )
        [pscustomobject]@{
            Name = $Name
            Start = $Start
            Duration = $Duration
            CandidateBytes = [long]($CandidateKbps * $Duration * 1000.0 / 8.0)
            CandidateKbps = $CandidateKbps
            Frames = @($Vmaf | ForEach-Object {
                [pscustomobject]@{ Vmaf = [double]$_; Xpsnr = $Xpsnr; Ssim = $Ssim; Psnr = $Psnr }
            })
        }
    }
}

Describe 'source-relative metric planning' {
    It 'provides the metric module and public commands' {
        Test-Path $modulePath | Should -BeTrue
        foreach ($name in 'Get-EOMetricPlan','Invoke-EOMetrics','Measure-EOMetricAggregate','Test-EOQualityPolicy') {
            Get-Command $name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    It 'escapes Windows metric log paths for FFmpeg filter options' {
        InModuleScope Metrics {
            $escaped = ConvertTo-EOFilterPath 'C:\metrics work\vmaf.json'
            $escaped | Should -BeExactly 'C\:/metrics work/vmaf.json'
            $escaped | Should -Not -Match '\\\\'
        }
    }

    It 'parses numbered FFmpeg XPSNR records without treating the summary as a frame' {
        $statsPath = Join-Path $TestDrive 'xpsnr.log'
        @(
            'n:    1  XPSNR y: 10.2977  XPSNR u: 13.1923  XPSNR v: 12.5126'
            ''
            'n:    2  XPSNR y: inf  XPSNR u: inf  XPSNR v: inf'
            'XPSNR average, 2 frames  y: 55.1488  u: 60.0000  v: 60.0000  (minimum: 10.2977)'
        ) | Set-Content -LiteralPath $statsPath

        $parsed = InModuleScope Metrics { Read-EOStatsFile -Path $using:statsPath -Metric 'xpsnr' }

        $parsed.Count | Should -Be 2
        $parsed[0] | Should -Be 10.2977
        $parsed[1] | Should -Be 100.0
    }

    It 'applies the requested user transform to both reference and encode paths exactly once' {
        $source = [pscustomobject]@{ Video = [pscustomobject]@{ IsHdr = $false; BitDepth = 8; PixelFormat = 'yuv420p'; Width = 1280; Height = 720; IsVfr = $false } }
        $caps = [pscustomobject]@{ Filters = @('libvmaf','xpsnr','ssim','psnr') }
        $plan = Get-EOMetricPlan -SourceProbe $source -Capabilities $caps -VideoFilter 'crop=404:720:438:0'

        $plan.ReferenceUserTransform | Should -Be 'crop=404:720:438:0'
        $plan.EncodeUserTransform | Should -Be 'crop=404:720:438:0'
        $plan.CandidateMetricFilter | Should -Not -Match 'crop=404:720:438:0'
    }

    It 'uses a 10-bit SDR comparison representation and all available quality metrics' {
        $source = [pscustomobject]@{ Video = [pscustomobject]@{ IsHdr = $false; BitDepth = 8; PixelFormat = 'yuv420p'; Width = 1920; Height = 1080; IsVfr = $false } }
        $caps = [pscustomobject]@{ Filters = @('libvmaf','xpsnr','ssim','psnr') }
        $plan = Get-EOMetricPlan -SourceProbe $source -Capabilities $caps

        $plan.ComparisonPixelFormat | Should -Be 'yuv420p10le'
        $plan.VmafRole | Should -Be 'Primary'
        $plan.Metrics | Should -Contain 'vmaf'
        $plan.Metrics | Should -Contain 'xpsnr'
        $plan.Metrics | Should -Contain 'ssim'
        $plan.Metrics | Should -Contain 'psnr'
    }

    It 'keeps HDR native and marks SDR-model VMAF as advisory rather than authoritative' {
        $source = [pscustomobject]@{ Video = [pscustomobject]@{ IsHdr = $true; BitDepth = 10; PixelFormat = 'yuv420p10le'; Width = 3840; Height = 2160; IsVfr = $false; ColorTransfer = 'smpte2084' } }
        $caps = [pscustomobject]@{ Filters = @('libvmaf','xpsnr','ssim','psnr','zscale','tonemap') }
        $plan = Get-EOMetricPlan -SourceProbe $source -Capabilities $caps

        $plan.ComparisonPixelFormat | Should -Be 'yuv420p10le'
        $plan.VmafRole | Should -Be 'Advisory'
        $plan.ConfidencePenalty | Should -BeGreaterThan 0
        $plan.PreserveHdrNativeMetrics | Should -BeTrue
    }
}

Describe 'metric aggregation and quality policy' {
    It 'normalizes primary VMAF against the reference self-score before applying policy thresholds' {
        $candidate = New-MetricSample 'high-motion' (@(1..100 | ForEach-Object { 96.73 }))
        $baseline = New-MetricSample 'high-motion' (@(1..100 | ForEach-Object { 97.92 }))

        $agg = Measure-EOMetricAggregate -Samples @($candidate) -VmafBaselineSamples @($baseline)
        $decision = Test-EOQualityPolicy -Aggregate $agg -Policy $profiles.Conservative

        [math]::Round([double]$agg.MeanVmaf, 2) | Should -Be 96.73
        $agg.RelativeMeanVmaf | Should -BeGreaterThan 98.8
        $agg.RelativeWorstSampleVmaf | Should -BeGreaterThan 98.8
        $agg.RelativeP05Vmaf | Should -BeGreaterThan 98.8
        $decision.Passed | Should -BeTrue
    }

    It 'tolerates a one-frame encoder tail mismatch when applying the VMAF baseline' {
        $candidateValues = @(1..101 | ForEach-Object { 96.73 })
        $baselineValues = @(1..100 | ForEach-Object { 97.92 })
        $candidate = New-MetricSample 'tail-rounding' $candidateValues
        $baseline = New-MetricSample 'tail-rounding' $baselineValues

        $agg = Measure-EOMetricAggregate -Samples @($candidate) -VmafBaselineSamples @($baseline)

        $agg.VmafBaselineApplied | Should -BeTrue
        $agg.RelativeFrameCount | Should -Be 100
        $agg.RelativeMeanVmaf | Should -BeGreaterThan 98.8
    }

    It 'computes pooled percentiles and worst-sample mean deterministically' {
        $samples = @(
            (New-MetricSample 'easy' (@(1..50 | ForEach-Object { 99.0 }))),
            (New-MetricSample 'hard' (@(1..50 | ForEach-Object { if ($_ -le 5) { 96.0 } else { 98.0 } })))
        )
        $agg = Measure-EOMetricAggregate -Samples $samples

        $agg.FrameCount | Should -Be 100
        $agg.MeanVmaf | Should -BeGreaterThan 98.3
        $agg.P05Vmaf | Should -Be 96.0
        $agg.P10Vmaf | Should -BeGreaterOrEqual 98.0
        $agg.WorstSampleVmaf | Should -Be 97.8
        $agg.WorstSampleName | Should -Be 'hard'
        $hard = @($agg.Samples | Where-Object Name -eq 'hard')[0]
        $hard.FrameCount | Should -Be 50
        $hard.P05Vmaf | Should -Be 96.0
        $hard.CandidateKbps | Should -Be 1234.5
    }

    It 'tolerates one pathological frame when mean worst-sample and P05 remain healthy' {
        $values = @(60.0) + @(1..99 | ForEach-Object { 99.0 })
        $agg = Measure-EOMetricAggregate -Samples @((New-MetricSample 'single-outlier' $values))
        $decision = Test-EOQualityPolicy -Aggregate $agg -Policy $profiles.Conservative

        $agg.MinimumVmaf | Should -Be 60.0
        $agg.P05Vmaf | Should -Be 99.0
        $decision.Passed | Should -BeTrue
    }

    It 'rejects a sustained bad sequence even when the overall mean still looks acceptable' {
        $values = @(1..10 | ForEach-Object { 90.0 }) + @(1..90 | ForEach-Object { 99.0 })
        $agg = Measure-EOMetricAggregate -Samples @((New-MetricSample 'sustained-drop' $values))
        $decision = Test-EOQualityPolicy -Aggregate $agg -Policy $profiles.Conservative

        $agg.MeanVmaf | Should -BeGreaterThan 98.0
        $agg.P05Vmaf | Should -Be 90.0
        $decision.Passed | Should -BeFalse
        $decision.Failures -join ' ' | Should -Match 'P05'
    }
}
