@{
    hevc_nvenc = @{
        Codec            = 'hevc'
        QualityControl   = 'CQ'
        QualityOption    = '-cq'
        SearchMinimum    = 10
        SearchMaximum    = 30
        DefaultStart     = 18
        BetterDirection  = 'Lower'
        Hardware         = $true
        SupportsHdr      = $true
        PixelFormats     = @('yuv420p','p010le','yuv444p','p016le')
        PreferredArgs    = @('-preset','p7','-tune','hq','-rc','vbr','-b:v','0','-multipass','fullres','-spatial-aq','1','-temporal-aq','1','-aq-strength','8')
    }

    libx265 = @{
        Codec            = 'hevc'
        QualityControl   = 'CRF'
        QualityOption    = '-crf'
        SearchMinimum    = 10
        SearchMaximum    = 30
        DefaultStart     = 18
        BetterDirection  = 'Lower'
        Hardware         = $false
        SupportsHdr      = $true
        PixelFormats     = @('yuv420p','yuv420p10le','yuv422p','yuv422p10le','yuv444p','yuv444p10le')
        PreferredArgs    = @('-preset','slow')
    }

    h264_nvenc = @{
        Codec            = 'h264'
        QualityControl   = 'CQ'
        QualityOption    = '-cq'
        SearchMinimum    = 10
        SearchMaximum    = 30
        DefaultStart     = 18
        BetterDirection  = 'Lower'
        Hardware         = $true
        SupportsHdr      = $false
        PixelFormats     = @('yuv420p','yuv444p')
        PreferredArgs    = @('-preset','p7','-tune','hq','-rc','vbr','-b:v','0','-multipass','fullres','-spatial-aq','1','-temporal-aq','1','-aq-strength','8')
    }

    libx264 = @{
        Codec            = 'h264'
        QualityControl   = 'CRF'
        QualityOption    = '-crf'
        SearchMinimum    = 10
        SearchMaximum    = 30
        DefaultStart     = 18
        BetterDirection  = 'Lower'
        Hardware         = $false
        SupportsHdr      = $false
        PixelFormats     = @('yuv420p','yuv422p','yuv444p')
        PreferredArgs    = @('-preset','slow')
    }

    av1_nvenc = @{
        Codec            = 'av1'
        QualityControl   = 'CQ'
        QualityOption    = '-cq'
        SearchMinimum    = 10
        SearchMaximum    = 40
        DefaultStart     = 24
        BetterDirection  = 'Lower'
        Hardware         = $true
        SupportsHdr      = $true
        PixelFormats     = @('yuv420p','p010le')
        PreferredArgs    = @('-preset','p7','-tune','hq','-rc','vbr','-b:v','0','-multipass','fullres','-spatial-aq','1','-temporal-aq','1','-aq-strength','8')
    }

    libsvtav1 = @{
        Codec            = 'av1'
        QualityControl   = 'CRF'
        QualityOption    = '-crf'
        SearchMinimum    = 12
        SearchMaximum    = 45
        DefaultStart     = 28
        BetterDirection  = 'Lower'
        Hardware         = $false
        SupportsHdr      = $true
        PixelFormats     = @('yuv420p','yuv420p10le')
        PreferredArgs    = @('-preset','6')
    }
}
