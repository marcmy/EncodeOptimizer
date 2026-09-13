@{
    Conservative = @{
        MeanVmaf             = 98.0
        WorstSampleVmaf      = 97.0
        P05Vmaf              = 95.0
        MinimumConfidence    = 'MEDIUM'
        BatchAutoConfidence  = 'HIGH'
        MinimumSavingsRatio  = 0.12
        ComfortableMargin    = 0.50
        VerificationMargin   = 0.00
    }

    Balanced = @{
        MeanVmaf             = 97.0
        WorstSampleVmaf      = 95.5
        P05Vmaf              = 93.5
        MinimumConfidence    = 'MEDIUM'
        BatchAutoConfidence  = 'MEDIUM'
        MinimumSavingsRatio  = 0.10
        ComfortableMargin    = 0.40
        VerificationMargin   = 0.00
    }

    Aggressive = @{
        MeanVmaf             = 95.0
        WorstSampleVmaf      = 93.0
        P05Vmaf              = 90.0
        MinimumConfidence    = 'MEDIUM'
        BatchAutoConfidence  = 'MEDIUM'
        MinimumSavingsRatio  = 0.08
        ComfortableMargin    = 0.30
        VerificationMargin   = 0.00
    }
}
