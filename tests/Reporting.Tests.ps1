BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\lib\Reporting.psm1'
    if (Test-Path $modulePath) { Import-Module $modulePath -Force }
}

Describe 'optimizer reporting' {
    It 'provides human and machine-readable reporting commands' {
        Test-Path $modulePath | Should -BeTrue
        foreach ($name in 'New-EOReport','Format-EOHumanReport','Write-EOReport','Join-EOCommandLine') {
            Get-Command $name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    It 'captures source samples candidates metrics savings confidence warnings command alternatives and rationale' {
        $source = [pscustomobject]@{
            Path = 'D:\video.mp4'
            Video = [pscustomobject]@{ CodecName='hevc'; Profile='Main'; Width=1280; Height=720; FrameRate=29.97; BitDepth=8; PixelFormat='yuv420p'; IsHdr=$false; HdrKind='SDR'; IsVfr=$false }
            Format = [pscustomobject]@{ Duration=600.0; Size=100000000; BitRate=1333333 }
            Audio=@([pscustomobject]@{ CodecName='aac' }); Subtitles=@(); Attachments=@(); Chapters=@()
        }
        $samples = [pscustomobject]@{
            SearchSamples=@([pscustomobject]@{ Start=10.0; Duration=10.0; Reasons=@('motion') })
            VerificationSamples=@([pscustomobject]@{ Start=400.0; Duration=10.0; Reasons=@('verification') })
        }
        $search = [pscustomobject]@{
            Decision='ENCODE'; SelectedQuality=16; SavingsRatio=0.32; EstimatedBytes=68000000
            Rationale=@('Quality 16 passed independent verification.')
            AllEvaluations=@(
                [pscustomobject]@{
                    Quality=18; Phase='Search'; Passed=$false; MeanVmaf=97.5; WorstSampleVmaf=96.7; P05Vmaf=94.8
                    Aggregate=[pscustomobject]@{ Samples=@(
                        [pscustomobject]@{ Name='Search-1'; Start=10.0; Duration=10.0; FrameCount=600; MeanVmaf=96.7; P05Vmaf=94.8; MinimumVmaf=73.0; CandidateBytes=1250000; CandidateKbps=1000.0 }
                    ) }
                },
                [pscustomobject]@{
                    Quality=16; Phase='Search'; Passed=$true; MeanVmaf=98.1; WorstSampleVmaf=97.4; P05Vmaf=95.5
                    Aggregate=[pscustomobject]@{ Samples=@(
                        [pscustomobject]@{ Name='Search-1'; Start=10.0; Duration=10.0; FrameCount=600; MeanVmaf=97.4; P05Vmaf=95.5; MinimumVmaf=80.0; CandidateBytes=1375000; CandidateKbps=1100.0 }
                    ) }
                }
            )
            FinalEvaluation=[pscustomobject]@{ Quality=16; MeanVmaf=98.1; WorstSampleVmaf=97.4; P05Vmaf=95.5; MeanXpsnr=47.2; MeanSsim=0.993; MeanPsnr=49.8 }
        }
        $confidence = [pscustomobject]@{ Label='HIGH'; Score=0.91; Reasons=@() }
        $size = [pscustomobject]@{ EstimatedBytes=68000000; LowerBytes=62000000; UpperBytes=75000000; VideoKbps=760.0 }
        $report = New-EOReport -SourceProbe $source -ProfileName 'Conservative' -EncoderName 'hevc_nvenc' -EncoderRationale @('Hardware HEVC preferred for HEVC source.') -SamplePlan $samples -SearchResult $search -SizeEstimate $size -Confidence $confidence -Warnings @('example warning') -FinalCommand @('ffmpeg','-i','D:\video.mp4','-c:v','hevc_nvenc','-cq','16','out.mp4') -Alternatives ([pscustomobject]@{ Safer=15; Smaller=17 })

        $report.SchemaVersion | Should -Be 2
        $report.Source.Video.Codec | Should -Be 'hevc'
        $report.Samples.Search.Count | Should -Be 1
        $report.Candidates.Count | Should -Be 2
        $report.Candidates[0].Samples.Count | Should -Be 1
        $report.Candidates[0].Samples[0].Name | Should -Be 'Search-1'
        $report.Candidates[0].Samples[0].FrameCount | Should -Be 600
        $report.Candidates[0].Samples[0].P05Vmaf | Should -Be 94.8
        $report.Candidates[0].Samples[0].CandidateKbps | Should -Be 1000.0
        $report.Selected.Metrics.MeanVmaf | Should -Be 98.1
        $report.EstimatedSavings.Ratio | Should -Be 0.32
        $report.Confidence.Label | Should -Be 'HIGH'
        $report.Warnings | Should -Contain 'example warning'
        $report.FinalCommand.Text | Should -Match 'hevc_nvenc'
        $report.Alternatives.Safer | Should -Be 15
        $report.Rationale -join ' ' | Should -Match 'passed independent verification'
    }

    It 'renders KEEP_SOURCE rationale prominently in the human report' {
        $report = [pscustomobject]@{
            Decision='KEEP_SOURCE'; Profile='Conservative'; Encoder=[pscustomobject]@{ Name='hevc_nvenc'; Rationale=@() }
            Source=[pscustomobject]@{ Path='video.mp4'; Video=[pscustomobject]@{ Codec='hevc'; Resolution='1280x720'; Fps=29.97; BitDepth=8; HdrKind='SDR' }; SizeBytes=100000000; Duration=600 }
            Selected=$null; EstimatedSavings=[pscustomobject]@{ Ratio=0.05; EstimatedBytes=95000000; LowerBytes=92000000; UpperBytes=99000000 }
            Confidence=[pscustomobject]@{ Label='HIGH'; Score=0.9; Reasons=@() }; Warnings=@(); Rationale=@('Estimated savings are below the configured threshold.')
            Samples=[pscustomobject]@{ Search=@(); Verification=@() }; Candidates=@(); FinalCommand=[pscustomobject]@{ Text=''; Arguments=@() }; Alternatives=$null
        }
        $text = Format-EOHumanReport -Report $report
        $text | Should -Match 'KEEP_SOURCE'
        $text | Should -Match 'below the configured threshold'
    }
}
