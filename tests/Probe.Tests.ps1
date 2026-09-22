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

    It 'does not infer HDR10 from an empty content-light metadata block' {
        $json = @'
{
  "streams": [
    {
      "index": 0,
      "codec_type": "video",
      "codec_name": "hevc",
      "profile": "Main 10",
      "width": 1920,
      "height": 1080,
      "pix_fmt": "yuv420p10le",
      "r_frame_rate": "30000/1001",
      "avg_frame_rate": "30000/1001",
      "time_base": "1/1000",
      "color_primaries": "bt2020",
      "color_transfer": "smpte2084",
      "color_space": "bt2020nc",
      "side_data_list": [
        { "side_data_type": "Content light level metadata" }
      ]
    }
  ],
  "format": {
    "format_name": "matroska,webm",
    "duration": "10",
    "size": "1000000"
  }
}
'@

        $probe = ConvertFrom-EOFFprobeJson -Json $json -Path 'empty-cll.mkv'

        $probe.Video.IsHdr | Should -BeTrue
        $probe.Video.HdrKind | Should -Be 'PQ'
        $probe.Video.MaxCLL | Should -BeNullOrEmpty
        $probe.Video.MaxFALL | Should -BeNullOrEmpty
    }

    It 'uses a Matroska stream DURATION tag when stream duration is unavailable' {
        $json = @'
{
  "streams": [
    {
      "index": 0,
      "codec_type": "video",
      "codec_name": "h264",
      "pix_fmt": "yuv420p",
      "r_frame_rate": "60000/1001",
      "avg_frame_rate": "60000/1001",
      "time_base": "1/1000",
      "tags": {
        "DURATION": "00:00:10.411000000"
      }
    },
    {
      "index": 1,
      "codec_type": "audio",
      "codec_name": "aac",
      "tags": {
        "DURATION": "00:00:20.021000000"
      }
    }
  ],
  "format": {
    "format_name": "matroska,webm",
    "duration": "20.021000",
    "size": "1000000"
  }
}
'@

        $probe = ConvertFrom-EOFFprobeJson -Json $json -Path 'duration-tag.mkv'

        $probe.Format.Duration | Should -Be 20.021
        $probe.Video.Duration | Should -BeGreaterThan 10.4109
        $probe.Video.Duration | Should -BeLessThan 10.4111
    }
}
