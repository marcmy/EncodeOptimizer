BeforeAll {
    $safetyPath = Join-Path $PSScriptRoot '..\lib\Safety.psm1'
    $metricsPath = Join-Path $PSScriptRoot '..\lib\Metrics.psm1'
    if (Test-Path $safetyPath) { Import-Module $safetyPath -Force }
    Import-Module $metricsPath -Force
    $profiles = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\config\quality-profiles.psd1')

    function New-SafetyProbe {
        param([switch]$Hdr,[switch]$DolbyVision,[switch]$Interlaced,[switch]$Vfr)
        [pscustomobject]@{
            Video=[pscustomobject]@{ IsHdr=[bool]$Hdr; HdrKind=if($Hdr){'HDR10'}else{'SDR'}; DolbyVision=[bool]$DolbyVision; IsInterlaced=[bool]$Interlaced; IsVfr=[bool]$Vfr; BitDepth=if($Hdr){10}else{8} }
        }
    }
}

Describe 'secondary-metric quality fallback' {
    It 'passes a non-primary-VMAF source on strong XPSNR SSIM and PSNR' {
        $aggregate=[pscustomobject]@{ VmafRole='Unavailable'; MeanVmaf=$null; WorstSampleVmaf=$null; P05Vmaf=$null; MeanXpsnr=48.0; MeanSsim=0.995; MeanPsnr=50.0; SeriousSecondaryAnomaly=$false }
        $decision=Test-EOQualityPolicy -Aggregate $aggregate -Policy $profiles.Conservative
        $decision.Passed | Should -BeTrue
        $decision.AuthoritativeMetric | Should -Be 'Secondary'
    }

    It 'does not let advisory HDR VMAF veto strong native metrics' {
        $aggregate=[pscustomobject]@{ VmafRole='Advisory'; MeanVmaf=92.0; WorstSampleVmaf=90.0; P05Vmaf=88.0; MeanXpsnr=47.0; MeanSsim=0.994; MeanPsnr=49.0; SeriousSecondaryAnomaly=$false }
        (Test-EOQualityPolicy -Aggregate $aggregate -Policy $profiles.Conservative).Passed | Should -BeTrue
    }

    It 'rejects weak secondary metrics when VMAF is not authoritative' {
        $aggregate=[pscustomobject]@{ VmafRole='Unavailable'; MeanVmaf=$null; WorstSampleVmaf=$null; P05Vmaf=$null; MeanXpsnr=39.0; MeanSsim=0.970; MeanPsnr=40.0; SeriousSecondaryAnomaly=$false }
        $decision=Test-EOQualityPolicy -Aggregate $aggregate -Policy $profiles.Conservative
        $decision.Passed | Should -BeFalse
        $decision.Failures -join ' ' | Should -Match 'XPSNR|SSIM|PSNR'
    }
}

Describe 'edge-case auto-encode safety gate' {
    It 'provides the safety gate command' {
        Test-Path $safetyPath | Should -BeTrue
        Get-Command Get-EOSafetyGate -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'allows ordinary progressive SDR with primary VMAF' {
        $gate=Get-EOSafetyGate -SourceProbe (New-SafetyProbe) -MetricPlan ([pscustomobject]@{ VmafRole='Primary'; Metrics=@('vmaf','xpsnr','ssim','psnr') })
        $gate.AnalyzeAllowed | Should -BeTrue
        $gate.AutoEncodeAllowed | Should -BeTrue
    }

    It 'hard-blocks Dolby Vision auto-transcode in this release' {
        $gate=Get-EOSafetyGate -SourceProbe (New-SafetyProbe -Hdr -DolbyVision) -MetricPlan ([pscustomobject]@{ VmafRole='Advisory'; Metrics=@('vmaf','xpsnr') }) -AllowHdrAutoEncode
        $gate.AutoEncodeAllowed | Should -BeFalse
        $gate.HardBlock | Should -BeTrue
        $gate.Reasons -join ' ' | Should -Match 'Dolby Vision'
    }

    It 'requires an explicit override for HDR and caps confidence' {
        $source=New-SafetyProbe -Hdr
        $plan=[pscustomobject]@{ VmafRole='Advisory'; Metrics=@('vmaf','xpsnr','ssim','psnr') }
        $default=Get-EOSafetyGate -SourceProbe $source -MetricPlan $plan
        $override=Get-EOSafetyGate -SourceProbe $source -MetricPlan $plan -AllowHdrAutoEncode
        $default.AutoEncodeAllowed | Should -BeFalse
        $override.AutoEncodeAllowed | Should -BeTrue
        $override.ConfidenceCeiling | Should -Be 'MEDIUM'
    }

    It 'requires an explicit override for interlaced input' {
        $source=New-SafetyProbe -Interlaced
        $plan=[pscustomobject]@{ VmafRole='Primary'; Metrics=@('vmaf','xpsnr') }
        (Get-EOSafetyGate -SourceProbe $source -MetricPlan $plan).AutoEncodeAllowed | Should -BeFalse
        (Get-EOSafetyGate -SourceProbe $source -MetricPlan $plan -AllowInterlacedAutoEncode).AutoEncodeAllowed | Should -BeTrue
    }

    It 'allows VFR without forcing CFR but records a warning' {
        $gate=Get-EOSafetyGate -SourceProbe (New-SafetyProbe -Vfr) -MetricPlan ([pscustomobject]@{ VmafRole='Primary'; Metrics=@('vmaf','xpsnr') })
        $gate.AutoEncodeAllowed | Should -BeTrue
        $gate.Warnings -join ' ' | Should -Match 'VFR|variable'
    }

    It 'requires an explicit override for secondary-only metric auto-encoding' {
        $source=New-SafetyProbe
        $plan=[pscustomobject]@{ VmafRole='Unavailable'; Metrics=@('xpsnr','ssim','psnr') }
        (Get-EOSafetyGate -SourceProbe $source -MetricPlan $plan).AutoEncodeAllowed | Should -BeFalse
        (Get-EOSafetyGate -SourceProbe $source -MetricPlan $plan -AllowSecondaryMetricsAutoEncode).AutoEncodeAllowed | Should -BeTrue
    }
}
