@{
    Conservative = @{
        MeanVmaf               = 98.0
        WorstSampleVmaf        = 97.0
        P05Vmaf                = 95.0
        MinimumXpsnr           = 45.0
        MinimumSsim            = 0.990
        MinimumPsnr            = 45.0
        MinimumSecondaryMetrics = 2
        MinimumConfidence      = 'MEDIUM'
        BatchAutoConfidence    = 'HIGH'
        MinimumSavingsRatio    = 0.12
        ComfortableMargin      = 0.50
        VerificationMargin     = 0.00
    }

    Balanced = @{
        MeanVmaf               = 97.0
        WorstSampleVmaf        = 95.5
        P05Vmaf                = 93.5
        MinimumXpsnr           = 42.0
        MinimumSsim            = 0.985
        MinimumPsnr            = 42.0
        MinimumSecondaryMetrics = 2
        MinimumConfidence      = 'MEDIUM'
        BatchAutoConfidence    = 'MEDIUM'
        MinimumSavingsRatio    = 0.10
        ComfortableMargin      = 0.40
        VerificationMargin     = 0.00
    }

    Aggressive = @{
        MeanVmaf               = 95.0
        WorstSampleVmaf        = 93.0
        P05Vmaf                = 90.0
        MinimumXpsnr           = 39.0
        MinimumSsim            = 0.975
        MinimumPsnr            = 39.0
        MinimumSecondaryMetrics = 2
        MinimumConfidence      = 'MEDIUM'
        BatchAutoConfidence    = 'MEDIUM'
        MinimumSavingsRatio    = 0.08
        ComfortableMargin      = 0.30
        VerificationMargin     = 0.00
    }
}
