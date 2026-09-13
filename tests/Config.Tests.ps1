Describe 'EncodeOptimizer quality profiles' {
    BeforeAll {
        $profilesPath = Join-Path $PSScriptRoot '..\config\quality-profiles.psd1'
    }

    It 'defines Conservative as the default keeper policy' {
        Test-Path $profilesPath | Should -BeTrue
        $profiles = Import-PowerShellDataFile $profilesPath
        $profiles.Conservative.MeanVmaf | Should -Be 98.0
        $profiles.Conservative.WorstSampleVmaf | Should -Be 97.0
        $profiles.Conservative.P05Vmaf | Should -Be 95.0
        $profiles.Conservative.MinimumConfidence | Should -Be 'MEDIUM'
    }

    It 'defines progressively less strict Balanced and Aggressive profiles' {
        $profiles = Import-PowerShellDataFile $profilesPath
        $profiles.Balanced.MeanVmaf | Should -BeLessThan $profiles.Conservative.MeanVmaf
        $profiles.Aggressive.MeanVmaf | Should -BeLessThan $profiles.Balanced.MeanVmaf
        $profiles.Balanced.WorstSampleVmaf | Should -BeLessThan $profiles.Conservative.WorstSampleVmaf
        $profiles.Aggressive.WorstSampleVmaf | Should -BeLessThan $profiles.Balanced.WorstSampleVmaf
    }

    It 'defines initial encoder profiles with search metadata' {
        $encoderPath = Join-Path $PSScriptRoot '..\config\encoder-profiles.psd1'
        Test-Path $encoderPath | Should -BeTrue
        $encoders = Import-PowerShellDataFile $encoderPath
        foreach ($name in 'hevc_nvenc','libx265','h264_nvenc','libx264','av1_nvenc','libsvtav1') {
            $encoders.ContainsKey($name) | Should -BeTrue
            $encoders[$name].QualityControl | Should -Not -BeNullOrEmpty
            $encoders[$name].SearchMinimum | Should -BeLessThan $encoders[$name].SearchMaximum
        }
    }
}
