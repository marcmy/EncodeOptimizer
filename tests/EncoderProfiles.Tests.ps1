BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\lib\EncoderProfiles.psm1'
    if (Test-Path $modulePath) { Import-Module $modulePath -Force }

    function New-TestCapabilities {
        param([string[]]$Encoders, [hashtable]$Options = @{})
        [pscustomobject]@{ Encoders = $Encoders; EncoderOptions = $Options }
    }

    function New-TestProbe {
        param(
            [string]$Codec,
            [int]$BitDepth = 8,
            [bool]$Hdr = $false,
            [string]$PixelFormat = 'yuv420p',
            [int]$Width = 1920,
            [int]$Height = 1080,
            [double]$FrameRate = 29.97
        )
        [pscustomobject]@{
            Video = [pscustomobject]@{
                CodecName = $Codec
                BitDepth = $BitDepth
                IsHdr = $Hdr
                DolbyVision = $false
                PixelFormat = $PixelFormat
                Width = $Width
                Height = $Height
                FrameRate = $FrameRate
            }
        }
    }
}

Describe 'automatic encoder policy' {
    It 'prefers HEVC NVENC for an HEVC source when available' {
        Get-Command Get-EOEncoderCandidates -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $caps = New-TestCapabilities @('hevc_nvenc','libx265','h264_nvenc')
        $result = @(Get-EOEncoderCandidates -SourceProbe (New-TestProbe 'hevc') -Capabilities $caps)
        $result[0] | Should -Be 'hevc_nvenc'
        $result | Should -Contain 'libx265'
    }

    It 'falls back from an encoder that cannot preserve combined bit depth and chroma' {
        $caps = New-TestCapabilities @('hevc_nvenc','libx265')
        $probe = New-TestProbe 'hevc' 10 $false 'yuv422p10le'
        $result = @(Get-EOEncoderCandidates -SourceProbe $probe -Capabilities $caps)

        $result[0] | Should -Be 'libx265'
        $result | Should -Not -Contain 'hevc_nvenc'
    }

    It 'does not silently downgrade an AV1 source to HEVC' {
        $caps = New-TestCapabilities @('hevc_nvenc','libx265')
        $result = @(Get-EOEncoderCandidates -SourceProbe (New-TestProbe 'av1') -Capabilities $caps)
        $result | Should -Be @('KEEP_SOURCE')
    }

    It 'does not select an HDR-unsafe H264 path for a 10-bit HDR source' {
        $caps = New-TestCapabilities @('h264_nvenc','libx264')
        $result = @(Get-EOEncoderCandidates -SourceProbe (New-TestProbe 'hevc' 10 $true 'yuv420p10le') -Capabilities $caps)
        $result | Should -Be @('KEEP_SOURCE')
    }

    It 'honors an explicit encoder override when the encoder exists' {
        $caps = New-TestCapabilities @('hevc_nvenc','libx265')
        $result = @(Get-EOEncoderCandidates -SourceProbe (New-TestProbe 'hevc') -Capabilities $caps -Encoder 'libx265')
        $result | Should -Be @('libx265')
    }

    It 'prunes preferred NVENC options that the installed FFmpeg build does not expose' {
        $options = @{ hevc_nvenc = @('preset','tune','cq','spatial-aq') }
        $caps = New-TestCapabilities @('hevc_nvenc') $options
        $profile = Resolve-EOEncoderProfile -Name 'hevc_nvenc' -Capabilities $caps -SourceProbe (New-TestProbe 'hevc')
        $profile.Arguments | Should -Contain '-preset'
        $profile.Arguments | Should -Contain '-spatial-aq'
        $profile.Arguments | Should -Contain '-b:v'
        $profile.Arguments | Should -Not -Contain '-temporal-aq'
        $profile.Arguments | Should -Not -Contain '-multipass'
    }

    It 'gives temporary HEVC NVENC search encodes maximum level and tier headroom' {
        $options = @{ hevc_nvenc = @('preset','tune','cq','rc','multipass','spatial-aq','temporal-aq','aq-strength','level','tier') }
        $caps = New-TestCapabilities @('hevc_nvenc') $options
        $profile = Resolve-EOEncoderProfile -Name 'hevc_nvenc' -Capabilities $caps -SourceProbe (New-TestProbe 'h264' 8 $false 'yuv420p' 1920 1080 59.94)

        ($profile.Arguments -join '|') | Should -Not -Match '\|-level\|'
        ($profile.AnalysisArguments -join '|') | Should -Match '\|-level\|6\.2(?:\||$)'
        ($profile.AnalysisArguments -join '|') | Should -Match '\|-tier\|high(?:\||$)'
    }

    It 'uses the lowest HEVC NVENC final level that preserves measured bitrate headroom' {
        $options = @{ hevc_nvenc = @('preset','tune','cq','rc','multipass','spatial-aq','temporal-aq','aq-strength','level','tier') }
        $caps = New-TestCapabilities @('hevc_nvenc') $options

        $probe = New-TestProbe 'h264' 8 $false 'yuv420p' 1920 1080 59.94
        $profile = Resolve-EOEncoderProfile -Name 'hevc_nvenc' -Capabilities $caps -SourceProbe $probe
        $moderate = Resolve-EOFinalEncoderProfile -EncoderProfile $profile -SourceProbe $probe -RequiredVideoKbps 12000
        $hard = Resolve-EOFinalEncoderProfile -EncoderProfile $profile -SourceProbe $probe -RequiredVideoKbps 75000

        ($moderate.Arguments -join '|') | Should -Match '\|-level\|4\.1(?:\||$)'
        ($hard.Arguments -join '|') | Should -Match '\|-level\|6\.1(?:\||$)'
        ($hard.Arguments -join '|') | Should -Not -Match '\|-tier\|high(?:\||$)'
    }

    It 'uses HEVC High tier only when Level 6.2 Main headroom is insufficient' {
        $options = @{ hevc_nvenc = @('preset','tune','cq','level','tier') }
        $caps = New-TestCapabilities @('hevc_nvenc') $options
        $probe = New-TestProbe 'h264' 8 $false 'yuv420p' 3840 2160 59.94
        $profile = Resolve-EOEncoderProfile -Name 'hevc_nvenc' -Capabilities $caps -SourceProbe $probe
        $final = Resolve-EOFinalEncoderProfile -EncoderProfile $profile -SourceProbe $probe -RequiredVideoKbps 180000

        ($final.Arguments -join '|') | Should -Match '\|-level\|6\.2(?:\||$)'
        ($final.Arguments -join '|') | Should -Match '\|-tier\|high(?:\||$)'
    }
}
