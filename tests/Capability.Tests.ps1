BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\lib\Capability.psm1'
    if (Test-Path $modulePath) {
        Import-Module $modulePath -Force
    }
}

Describe 'FFmpeg capability discovery' {
    It 'provides the capability module' {
        Test-Path $modulePath | Should -BeTrue
        Get-Command Get-EOCapabilities -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'parses available encoders filters hardware acceleration and encoder options' {
        $runner = {
            param($Executable, [string[]]$Arguments)
            $joined = $Arguments -join ' '
            switch -Regex ($joined) {
                '^-version$' { return 'ffmpeg version 8.0-test Copyright' }
                '^-encoders$' {
                    return @'
Encoders:
 V..... libx265              libx265 H.265 / HEVC
 V....D hevc_nvenc           NVIDIA NVENC hevc encoder
 V....D av1_nvenc            NVIDIA NVENC av1 encoder
 A..... aac                  AAC
'@
                }
                '^-decoders$' {
                    return @'
Decoders:
 VFS..D hevc                 HEVC (High Efficiency Video Coding)
 VFS..D h264                 H.264 / AVC
'@
                }
                '^-filters$' {
                    return @'
Filters:
 .. libvmaf           VV->V      Calculate the VMAF score.
 .. ssim              VV->V      Calculate SSIM.
 .. psnr              VV->V      Calculate PSNR.
 .. xpsnr             VV->V      Calculate XPSNR.
'@
                }
                '^-hwaccels$' {
                    return "Hardware acceleration methods:`ncuda`nd3d11va`n"
                }
                '^-h encoder=hevc_nvenc$' {
                    return @'
Encoder hevc_nvenc [NVIDIA NVENC hevc encoder]:
  -preset            <int>        E..V....... Set the encoding preset
  -tune              <int>        E..V....... Set the tuning info
  -multipass         <int>        E..V....... Set multipass mode
  -spatial-aq        <boolean>    E..V....... set to 1 to enable Spatial AQ
  -temporal-aq       <boolean>    E..V....... set to 1 to enable Temporal AQ
  -aq-strength       <int>        E..V....... AQ strength
  -cq                <float>      E..V....... Set target quality level
'@
                }
                default { return '' }
            }
        }

        $caps = Get-EOCapabilities -FFmpegPath 'ffmpeg-test' -EncoderNames @('hevc_nvenc') -CommandRunner $runner

        $caps.Version | Should -Match '^8\.0-test'
        $caps.Encoders | Should -Contain 'hevc_nvenc'
        $caps.Encoders | Should -Contain 'libx265'
        $caps.Filters | Should -Contain 'libvmaf'
        $caps.Filters | Should -Contain 'xpsnr'
        $caps.HwAccels | Should -Contain 'cuda'
        $caps.EncoderOptions.hevc_nvenc | Should -Contain 'preset'
        $caps.EncoderOptions.hevc_nvenc | Should -Contain 'multipass'
        $caps.EncoderOptions.hevc_nvenc | Should -Contain 'cq'
    }
}
