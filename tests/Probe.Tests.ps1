BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\lib\Probe.psm1'
    if (Test-Path $modulePath) {
        Import-Module $modulePath -Force
    }
}

Describe 'ffprobe normalization' {
    It 'provides the probe parser module' {
        Test-Path $modulePath | Should -BeTrue
        Get-Command ConvertFrom-EOFFprobeJson -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'normalizes an SDR HEVC source' {
        $json = Get-Content (Join-Path $PSScriptRoot 'fixtures\ffprobe-hevc-sdr.json') -Raw
        $probe = ConvertFrom-EOFFprobeJson -Json $json -Path 'sample.mp4'

        $probe.Video.CodecName | Should -Be 'hevc'
        $probe.Video.CodecTag | Should -Be 'hvc1'
        $probe.Video.Profile | Should -Be 'Main'
        $probe.Video.Width | Should -Be 1280
        $probe.Video.Height | Should -Be 720
        $probe.Video.BitDepth | Should -Be 8
        $probe.Video.FrameRate | Should -BeGreaterThan 29.96
        $probe.Video.FrameRate | Should -BeLessThan 29.98
        $probe.Video.IsVfr | Should -BeFalse
        $probe.Video.IsHdr | Should -BeFalse
        $probe.Video.ColorPrimaries | Should -Be 'bt709'
        $probe.Audio.Count | Should -Be 1
        $probe.Video.Disposition.Default | Should -Be 1
    }

    It 'detects VFR and HDR10 metadata without reducing it to SDR assumptions' {
        $json = Get-Content (Join-Path $PSScriptRoot 'fixtures\ffprobe-vfr-hdr10.json') -Raw
        $probe = ConvertFrom-EOFFprobeJson -Json $json -Path 'hdr.mkv'

        $probe.Video.BitDepth | Should -Be 10
        $probe.Video.IsVfr | Should -BeTrue
        $probe.Video.IsHdr | Should -BeTrue
        $probe.Video.HdrKind | Should -Be 'HDR10'
        $probe.Video.ColorPrimaries | Should -Be 'bt2020'
        $probe.Video.ColorTransfer | Should -Be 'smpte2084'
        $probe.Video.MaxCLL | Should -Be 1000
        $probe.Video.MaxFALL | Should -Be 400
        $probe.Subtitles.Count | Should -Be 1
        $probe.Chapters.Count | Should -Be 1
    }
}
