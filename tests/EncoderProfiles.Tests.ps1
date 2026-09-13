BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\lib\EncoderProfiles.psm1'
    if (Test-Path $modulePath) { Import-Module $modulePath -Force }

    function New-TestCapabilities {
        param([string[]]$Encoders, [hashtable]$Options = @{})
        [pscustomobject]@{ Encoders = $Encoders; EncoderOptions = $Options }
    }

    function New-TestProbe {
        param([string]$Codec, [int]$BitDepth = 8, [bool]$Hdr = $false, [string]$PixelFormat = 'yuv420p')
        [pscustomobject]@{
            Video = [pscustomobject]@{
                CodecName = $Codec
                BitDepth = $BitDepth
                IsHdr = $Hdr
                DolbyVision = $false
                PixelFormat = $PixelFormat
                Width = 1920
                Height = 1080
                FrameRate = 29.97
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
        $profile.Arguments | Should -Not -Contain '-temporal-aq'
        $profile.Arguments | Should -Not -Contain '-multipass'
    }
}
