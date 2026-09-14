BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\lib\Streams.psm1'
    if (Test-Path $modulePath) { Import-Module $modulePath -Force }

    function New-StreamProbe {
        param(
            [string]$FormatName = 'mov,mp4,m4a,3gp,3g2,mj2',
            [string]$VideoCodec = 'hevc',
            [int]$BitDepth = 8,
            [string]$PixelFormat = 'yuv420p',
            [string]$SubtitleCodec = ''
        )
        $subs = if ($SubtitleCodec) { @([pscustomobject]@{ Index = 2; CodecName = $SubtitleCodec }) } else { @() }
        [pscustomobject]@{
            Path = 'input.mp4'
            Video = [pscustomobject]@{
                Index = 0; CodecName = $VideoCodec; BitDepth = $BitDepth; PixelFormat = $PixelFormat
                IsHdr = ($BitDepth -gt 8); DolbyVision = $false; IsVfr = $false
                ColorRange = 'tv'; ColorSpace = 'bt709'; ColorTransfer = 'bt709'; ColorPrimaries = 'bt709'
            }
            Audio = @([pscustomobject]@{ Index = 1; CodecName = 'aac' })
            Subtitles = $subs
            Attachments = @()
            Data = @()
            Chapters = @()
            Format = [pscustomobject]@{ Name = $FormatName }
        }
    }
}

Describe 'container and stream preservation' {
    It 'keeps MP4 for compatible HEVC and requests hvc1 tagging' {
        Get-Command Get-EOContainerPlan -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $probe = New-StreamProbe
        $encoder = [pscustomobject]@{ Name = 'hevc_nvenc'; Codec = 'hevc'; Hardware = $true }
        $plan = Get-EOContainerPlan -SourceProbe $probe -EncoderProfile $encoder
        $plan.Container | Should -Be 'mp4'
        $plan.Extension | Should -Be '.mp4'
        $plan.VideoTag | Should -Be 'hvc1'
    }

    It 'falls back to Matroska rather than dropping an incompatible subtitle' {
        $probe = New-StreamProbe -SubtitleCodec 'subrip'
        $encoder = [pscustomobject]@{ Name = 'hevc_nvenc'; Codec = 'hevc'; Hardware = $true }
        $plan = Get-EOContainerPlan -SourceProbe $probe -EncoderProfile $encoder
        $plan.Container | Should -Be 'mkv'
        $plan.Warnings -join ' ' | Should -Match 'subtitle'
    }

    It 'maps auxiliary streams for lossless copy' {
        $probe = New-StreamProbe -FormatName 'matroska,webm' -SubtitleCodec 'subrip'
        $probe.Attachments = @([pscustomobject]@{ Index = 3; CodecName = 'ttf' })
        $container = [pscustomobject]@{ Container = 'mkv'; Extension = '.mkv'; VideoTag = $null; Warnings = @() }
        $plan = Get-EOStreamPlan -SourceProbe $probe -ContainerPlan $container
        $joined = $plan.Arguments -join ' '
        $joined | Should -Match '-map 0:a\?'
        $joined | Should -Match '-map 0:s\?'
        $joined | Should -Match '-map 0:t\?'
        $joined | Should -Match '-c:a copy'
        $joined | Should -Match '-c:s copy'
        $joined | Should -Match '-map_metadata 0'
        $joined | Should -Match '-map_chapters 0'
    }

    It 'builds a 10-bit filtered HEVC command without forcing CFR' {
        $probe = New-StreamProbe -BitDepth 10 -PixelFormat 'yuv420p10le'
        $probe.Video.ColorSpace = 'bt2020nc'
        $probe.Video.ColorTransfer = 'smpte2084'
        $probe.Video.ColorPrimaries = 'bt2020'
        $encoder = [pscustomobject]@{
            Name = 'hevc_nvenc'; Codec = 'hevc'; Hardware = $true; QualityOption = '-cq';
            PixelFormats = @('yuv420p','p010le'); Arguments = @('-preset','p7','-tune','hq')
        }
        $container = [pscustomobject]@{ Container = 'mp4'; Extension = '.mp4'; VideoTag = 'hvc1'; Warnings = @() }
        $stream = Get-EOStreamPlan -SourceProbe $probe -ContainerPlan $container
        $args = New-EOFinalEncodeArguments -InputPath 'in.mp4' -OutputPath 'out.mp4' -SourceProbe $probe -EncoderProfile $encoder -ContainerPlan $container -StreamPlan $stream -Quality 16 -VideoFilter 'crop=404:720:438:0'
        $joined = $args -join ' '

        $joined | Should -Match '-vf crop=404:720:438:0'
        $joined | Should -Match '-c:v hevc_nvenc'
        $joined | Should -Match '-cq 16'
        $joined | Should -Match '-pix_fmt p010le'
        $joined | Should -Match '-tag:v hvc1'
        $joined | Should -Match '-color_trc smpte2084'
        $joined | Should -Not -Match '(^|\s)-r(\s|$)'
    }

    It 'preserves source frame timestamps on final encodes' {
        $probe = New-StreamProbe
        $encoder = [pscustomobject]@{
            Name = 'hevc_nvenc'; Codec = 'hevc'; Hardware = $true; QualityOption = '-cq';
            PixelFormats = @('yuv420p'); Arguments = @('-preset','p7')
        }
        $container = [pscustomobject]@{ Container = 'mkv'; Extension = '.mkv'; VideoTag = $null; Warnings = @() }
        $stream = [pscustomobject]@{ Arguments = @('-map','0:v:0'); Warnings = @() }

        $args = @(New-EOFinalEncodeArguments -InputPath 'in.mkv' -OutputPath 'out.mkv' -SourceProbe $probe -EncoderProfile $encoder -ContainerPlan $container -StreamPlan $stream -Quality 18)

        ($args -join '|') | Should -Match '\|-fps_mode\|passthrough\|out\.mkv$'
    }

    It 'uses analysis-specific encoder arguments for temporary search candidates' {
        $probe = New-StreamProbe
        $encoder = [pscustomobject]@{
            Name='hevc_nvenc'; Codec='hevc'; Hardware=$true; QualityOption='-cq'
            PixelFormats=@('yuv420p'); Arguments=@('-preset','p7'); AnalysisArguments=@('-preset','p7','-level','6.2','-tier','high')
        }
        $container = [pscustomobject]@{ Container='mkv'; Extension='.mkv'; VideoTag=$null; Warnings=@() }
        $stream = [pscustomobject]@{ Arguments=@('-map','0:v:0'); Warnings=@() }

        $args = @(New-EOFinalEncodeArguments -InputPath 'in.mkv' -OutputPath 'out.mkv' -SourceProbe $probe -EncoderProfile $encoder -ContainerPlan $container -StreamPlan $stream -Quality 18 -Analysis)
        ($args -join '|') | Should -Match '\|-level\|6\.2\|-tier\|high(?:\||$)'
    }

    It 'refuses to silently reduce 8-bit chroma from 4:2:2 to 4:2:0' {
        $probe = New-StreamProbe -BitDepth 8 -PixelFormat 'yuv422p'
        $encoder = [pscustomobject]@{
            Name='libx264'; Codec='h264'; Hardware=$false; QualityOption='-crf'
            PixelFormats=@('yuv420p'); Arguments=@('-preset','slow')
        }
        $container = [pscustomobject]@{ Container='mkv'; Extension='.mkv'; VideoTag=$null; Warnings=@() }
        $stream = Get-EOStreamPlan -SourceProbe $probe -ContainerPlan $container

        { New-EOFinalEncodeArguments -InputPath 'in.mkv' -OutputPath 'out.mkv' -SourceProbe $probe -EncoderProfile $encoder -ContainerPlan $container -StreamPlan $stream -Quality 16 } |
            Should -Throw '*chroma*'
    }

    It 'refuses to silently reduce 10-bit chroma from 4:2:2 to p010 4:2:0' {
        $probe = New-StreamProbe -BitDepth 10 -PixelFormat 'yuv422p10le'
        $encoder = [pscustomobject]@{
            Name='hevc_nvenc'; Codec='hevc'; Hardware=$true; QualityOption='-cq'
            PixelFormats=@('yuv420p','p010le'); Arguments=@('-preset','p7')
        }
        $container = [pscustomobject]@{ Container='mkv'; Extension='.mkv'; VideoTag=$null; Warnings=@() }
        $stream = Get-EOStreamPlan -SourceProbe $probe -ContainerPlan $container

        { New-EOFinalEncodeArguments -InputPath 'in.mkv' -OutputPath 'out.mkv' -SourceProbe $probe -EncoderProfile $encoder -ContainerPlan $container -StreamPlan $stream -Quality 16 } |
            Should -Throw '*chroma*'
    }

    It 'refuses to silently reduce bit depth from 12-bit to a 10-bit fallback' {
        $probe = New-StreamProbe -BitDepth 12 -PixelFormat 'yuv420p12le'
        $encoder = [pscustomobject]@{
            Name='libx265'; Codec='hevc'; Hardware=$false; QualityOption='-crf'
            PixelFormats=@('yuv420p','yuv420p10le'); Arguments=@('-preset','slow')
        }
        $container = [pscustomobject]@{ Container='mkv'; Extension='.mkv'; VideoTag=$null; Warnings=@() }
        $stream = Get-EOStreamPlan -SourceProbe $probe -ContainerPlan $container

        { New-EOFinalEncodeArguments -InputPath 'in.mkv' -OutputPath 'out.mkv' -SourceProbe $probe -EncoderProfile $encoder -ContainerPlan $container -StreamPlan $stream -Quality 16 } |
            Should -Throw '*bit depth*'
    }

    It 'inserts a sample seek window without collapsing argument tokens' {
        Get-Command Add-EOSampleWindowArguments -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $base = @('-hide_banner','-i','input.mp4','-map','0:v:0','-c:v','libx264','-crf','18','output.mp4')
        $result = @(Add-EOSampleWindowArguments -Arguments $base -Start 2 -Duration 10)

        $result.Count | Should -Be 14
        ($result -join '|') | Should -BeExactly '-hide_banner|-ss|2|-t|10|-i|input.mp4|-map|0:v:0|-c:v|libx264|-crf|18|output.mp4'
    }

    It 'builds a deterministic lossless reference sample with one seek and one user transform' {
        Get-Command New-EOReferenceSampleArguments -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $result = @(New-EOReferenceSampleArguments -InputPath 'input.mkv' -OutputPath 'reference.mkv' -Start 2.137 -Duration 3 -VideoFilter 'crop=160:180:80:0')

        ($result -join '|') | Should -BeExactly '-hide_banner|-nostdin|-ss|2.137|-i|input.mkv|-t|3|-map|0:v:0|-an|-sn|-dn|-vf|crop=160:180:80:0|-c:v|ffv1|-level|3|-g|1|-fps_mode|passthrough|reference.mkv'
    }
}
