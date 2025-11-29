module kach::constants {
    // ===== Tranche Identifiers =====

    /// Identifier for the senior tranche
    const TRANCHE_SENIOR: u8 = 0;

    /// Identifier for the junior tranche
    const TRANCHE_JUNIOR: u8 = 1;

    /// Get the senior tranche identifier
    public fun tranche_senior(): u8 {
        TRANCHE_SENIOR
    }

    /// Get the junior tranche identifier
    public fun tranche_junior(): u8 {
        TRANCHE_JUNIOR
    }

    // ===== Trust Score Thresholds =====

    /// Minimum trust score required for standard credit draws (60/100)
    const MIN_TRUST_SCORE_TO_DRAW: u64 = 60;

    /// Minimum trust score required for prefunded credit lines (95/100)
    const MIN_TRUST_SCORE_FOR_PREFUND: u64 = 95;

    /// Get minimum trust score for standard draws
    public fun min_trust_score_to_draw(): u64 {
        MIN_TRUST_SCORE_TO_DRAW
    }

    /// Get minimum trust score for prefunded lines
    public fun min_trust_score_for_prefund(): u64 {
        MIN_TRUST_SCORE_FOR_PREFUND
    }

    // ===== Tranche Loss Limits =====

    /// Maximum share of capital that the junior tranche can lose (basis points)
    const JUNIOR_MAX_LOSS_BPS: u64 = 8000; // 80%

    /// Maximum share of capital that the senior tranche can lose (basis points)
    const SENIOR_MAX_LOSS_BPS: u64 = 2000; // 20%

    /// Get junior tranche max loss in basis points
    public fun junior_max_loss_bps(): u64 {
        JUNIOR_MAX_LOSS_BPS
    }

    /// Get senior tranche max loss in basis points
    public fun senior_max_loss_bps(): u64 {
        SENIOR_MAX_LOSS_BPS
    }

    // ===== Protocol Fees =====

    /// Protocol fee percentage (7% of gross interest per documentation)
    const PROTOCOL_FEE_BPS: u64 = 700; // 7%

    /// Get protocol fee in basis points (for internal use)
    #[view]
    public fun protocol_fee_bps(): u64 {
        PROTOCOL_FEE_BPS
    }

    // ===== Attestator Configuration =====

    /// Extra window after maturity during which attestators can settle, in seconds
    const ATTESTATOR_GRACE_PERIOD_SECONDS: u64 = 21600; // 6 hours

    /// Get attestator grace period in seconds (for internal use)
    #[view]
    public fun attestator_grace_period_seconds(): u64 {
        ATTESTATOR_GRACE_PERIOD_SECONDS
    }
}

