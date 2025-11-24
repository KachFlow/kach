module kach::trust_score {
    use std::signer;
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use kach::governance;

    /// Error when a signer without admin rights attempts to mutate trust scores.
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Error when initializing a score for a borrower that already has one.
    const E_TRUST_SCORE_EXISTS: u64 = 2;
    /// Error when attempting to access a non-existent trust score record.
    const E_TRUST_SCORE_NOT_FOUND: u64 = 3;
    /// Error when loan amount exceeds earned capacity (anti-gaming check).
    const E_EXCEEDS_EARNED_CAPACITY: u64 = 4;

    /// Score threshold for standard credit access (with attestation).
    const CUTOFF_SCORE_STANDARD: u64 = 60;
    /// Score threshold for prefund access (no upfront attestation).
    const CUTOFF_SCORE_PREFUND: u64 = 95;

    /// Bootstrap period: first N loans exempt from anti-gaming earned capacity check
    const BOOTSTRAP_LOAN_COUNT: u64 = 10;

    /// Scaling factor for fixed-point math (6 decimals precision)
    const SCALE: u128 = 1_000_000;

    /// Repayment status constants
    const STATUS_ON_TIME: u8 = 0;
    const STATUS_LATE: u8 = 1;
    const STATUS_DEFAULT: u8 = 2;

    /// Hybrid volume-weighted Trust Score
    /// Tracks both amount-weighted volumes (with decay) and payment counts
    struct TrustScore has key {
        borrower_address: address,

        // Volume tracking (decayed over time, scaled by SCALE for precision)
        good_volume: u128,      // Sum of on-time repayments (effective amount, decayed)
        late_volume: u128,      // Sum of late repayments (effective amount, decayed)
        default_volume: u128,   // Sum of defaulted amounts (effective amount, decayed)

        // Count tracking
        on_time_count: u64,
        late_count: u64,
        default_count: u64,
        total_loans: u64,       // Total loans ever drawn

        // Admin-approved credit limit (set at registration)
        approved_credit_limit: u64,

        // Decay tracking
        last_update: u64,       // Timestamp of last repayment update

        // Timestamps
        created_at: u64,
    }

    /// Global registry
    struct TrustScoreRegistry has key {
        admin_address: address,
        total_scores: u64,
    }

    /// Trust score parameters (stored in governance, queried at runtime)
    /// These are stored in governance module for tunability

    /// Events
    #[event]
    struct TrustScoreInitialized has drop, store {
        borrower: address,
        approved_credit_limit: u64,
        timestamp: u64,
    }

    #[event]
    struct TrustScoreUpdated has drop, store {
        borrower: address,
        old_score: u64,
        new_score: u64,
        status: u8,  // STATUS_ON_TIME, STATUS_LATE, or STATUS_DEFAULT
        loan_amount: u64,
        timestamp: u64,
    }

    #[event]
    struct MaxLoanCapacityUpdated has drop, store {
        borrower: address,
        old_capacity: u64,
        new_capacity: u64,
        timestamp: u64,
    }

    /// Initialize trust score registry
    public entry fun initialize_registry(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        let registry = TrustScoreRegistry {
            admin_address: admin_addr,
            total_scores: 0
        };
        move_to(admin, registry);
    }

    /// Initialize trust score for a new borrower (admin only)
    /// approved_credit_limit: initial credit limit set by admin (e.g., $1M)
    public fun initialize_trust_score(
        admin: &signer,
        borrower_address: address,
        approved_credit_limit: u64
    ) acquires TrustScoreRegistry {
        let admin_addr = signer::address_of(admin);

        // Verify admin
        let registry = borrow_global_mut<TrustScoreRegistry>(admin_addr);
        assert!(admin_addr == registry.admin_address, E_NOT_AUTHORIZED);

        // Verify doesn't exist
        assert!(!exists<TrustScore>(borrower_address), E_TRUST_SCORE_EXISTS);

        let trust_score = TrustScore {
            borrower_address,
            good_volume: 0,
            late_volume: 0,
            default_volume: 0,
            on_time_count: 0,
            late_count: 0,
            default_count: 0,
            total_loans: 0,
            approved_credit_limit,
            last_update: timestamp::now_seconds(),
            created_at: timestamp::now_seconds(),
        };

        move_to(admin, trust_score);
        registry.total_scores += 1;

        event::emit(TrustScoreInitialized {
            borrower: borrower_address,
            approved_credit_limit,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Update trust score based on repayment behavior
    /// Called by credit_engine or attestator when repayment occurs
    public fun update_trust_score(
        borrower_address: address,
        loan_amount: u64,
        status: u8,  // STATUS_ON_TIME, STATUS_LATE, or STATUS_DEFAULT
        governance_address: address
    ) acquires TrustScore {
        assert!(exists<TrustScore>(borrower_address), E_TRUST_SCORE_NOT_FOUND);
        let trust_score = borrow_global_mut<TrustScore>(borrower_address);

        let old_score = calculate_trust_score_internal(trust_score, governance_address);

        // Apply decay to existing volumes
        apply_decay(trust_score, governance_address);

        // Calculate effective amount using per-loan weighting
        let effective_amount = calculate_effective_amount(loan_amount, governance_address);

        // Update volumes and counts based on status
        if (status == STATUS_ON_TIME) {
            trust_score.good_volume = trust_score.good_volume + effective_amount;
            trust_score.on_time_count = trust_score.on_time_count + 1;
        } else if (status == STATUS_LATE) {
            trust_score.late_volume = trust_score.late_volume + effective_amount;
            trust_score.late_count = trust_score.late_count + 1;
        } else if (status == STATUS_DEFAULT) {
            trust_score.default_volume = trust_score.default_volume + effective_amount;
            trust_score.default_count = trust_score.default_count + 1;
        };

        trust_score.total_loans = trust_score.total_loans + 1;
        trust_score.last_update = timestamp::now_seconds();

        let new_score = calculate_trust_score_internal(trust_score, governance_address);

        event::emit(TrustScoreUpdated {
            borrower: borrower_address,
            old_score,
            new_score,
            status,
            loan_amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Apply recency decay to all volumes
    /// decay = decay_factor ^ (dt / decay_interval)
    fun apply_decay(trust_score: &mut TrustScore, governance_address: address) {
        let now = timestamp::now_seconds();
        let dt = now - trust_score.last_update;

        if (dt == 0) return;  // No time passed, no decay

        // Get decay parameters from governance
        let decay_factor_bps = governance::get_trust_decay_factor_bps(governance_address);
        let decay_interval_seconds = governance::get_trust_decay_interval_seconds(governance_address);

        // Calculate decay: decay_factor ^ (dt / interval)
        // Using approximation: decay ≈ 1 - (1 - decay_factor) * (dt / interval) for small dt
        // For now, simplified: apply decay_factor once per interval passed
        let intervals_passed = dt / decay_interval_seconds;

        if (intervals_passed > 0) {
            // Apply decay: volume *= (decay_factor_bps / 10000) ^ intervals_passed
            // Simplified: multiply by decay_factor once per interval
            let i = 0;
            while (i < intervals_passed && i < 100) {  // Cap at 100 intervals for safety
                trust_score.good_volume = (trust_score.good_volume * (decay_factor_bps as u128)) / 10000;
                trust_score.late_volume = (trust_score.late_volume * (decay_factor_bps as u128)) / 10000;
                trust_score.default_volume = (trust_score.default_volume * (decay_factor_bps as u128)) / 10000;
                i = i + 1;
            };
        };
    }

    /// Calculate effective amount for per-loan weighting
    /// effective_amount = loan_amount ^ p (using power parameter from governance)
    /// Returns scaled by SCALE for precision
    fun calculate_effective_amount(loan_amount: u64, governance_address: address): u128 {
        let power_bps = governance::get_trust_power_bps(governance_address);

        // If power = 1.0 (10000 bps), return loan_amount directly (scaled)
        if (power_bps == 10000) {
            return (loan_amount as u128) * SCALE
        };

        // For p < 1, use approximation: amount^p ≈ amount * (p + (1-p) * log_scale)
        // Simplified for now: just use linear scaling with power adjustment
        // Full implementation would need proper power function

        // Simple approximation: scale linearly by power
        let scaled_amount = (loan_amount as u128) * (power_bps as u128) / 10000;
        scaled_amount * SCALE
    }

    /// Calculate current trust score using hybrid volume + count model
    fun calculate_trust_score_internal(
        trust_score: &TrustScore,
        governance_address: address
    ): u64 {
        // Get scoring parameters from governance
        let base_score = 70u64;  // Starting score
        let w_late_bps = governance::get_trust_w_late_bps(governance_address);
        let w_default_bps = governance::get_trust_w_default_bps(governance_address);
        let volume_weight_bps = governance::get_trust_volume_weight_bps(governance_address);
        let count_weight_bps = 10000 - volume_weight_bps;  // Remaining weight goes to counts
        let epsilon = 1000u128 * SCALE;  // Small value to prevent division by zero

        // 1. Calculate volume-based score
        let weighted_bad_volume =
            (trust_score.late_volume * (w_late_bps as u128) / 10000) +
            (trust_score.default_volume * (w_default_bps as u128) / 10000);

        let volume_denominator = trust_score.good_volume + epsilon;
        let volume_penalty = (weighted_bad_volume * 100 * SCALE) / volume_denominator;

        let base_score_scaled = (base_score as u128) * SCALE;
        let volume_score_raw = if (base_score_scaled > volume_penalty) {
            base_score_scaled - volume_penalty
        } else {
            0u128
        };
        let volume_score = (volume_score_raw / SCALE) as u64;

        // 2. Calculate count-based score
        let weighted_bad_counts =
            (trust_score.late_count * w_late_bps / 10000) +
            (trust_score.default_count * w_default_bps / 10000);

        let count_denominator = trust_score.on_time_count + 1;  // +1 as epsilon
        let count_penalty = (weighted_bad_counts * 100) / count_denominator;
        let count_score = if (base_score > count_penalty) {
            base_score - count_penalty
        } else {
            0u64
        };

        // 3. Calculate confidence multiplier based on history depth
        // confidence = 1 + log(1 + total_loans) / c
        // Approximation: confidence = 1 + (total_loans / confidence_divisor)
        let confidence_divisor = governance::get_trust_confidence_divisor(governance_address);
        let confidence_bonus_bps = if (confidence_divisor > 0) {
            // confidence = 1.0 + (total_loans / divisor)
            // In bps: 10000 + (total_loans * 10000 / divisor)
            10000 + ((trust_score.total_loans * 10000) / confidence_divisor)
        } else {
            10000  // No confidence scaling
        };

        // Cap confidence at 2.0× (20000 bps)
        let confidence_bps = if (confidence_bonus_bps > 20000) {
            20000
        } else {
            confidence_bonus_bps
        };

        // 4. Combine volume and count scores
        let combined_raw =
            ((volume_score as u128) * (volume_weight_bps as u128) / 10000) +
            ((count_score as u128) * (count_weight_bps as u128) / 10000);

        // 5. Apply confidence multiplier
        let final_score_raw = (combined_raw * (confidence_bps as u128)) / 10000;

        // 6. Clamp to [0, 100]
        let final_score = (final_score_raw as u64);
        if (final_score > 100) {
            100
        } else {
            final_score
        }
    }

    /// Get maximum loan amount allowed (anti-gaming check)
    /// During bootstrap period (first N loans): returns approved_credit_limit
    /// After bootstrap: returns min(approved_limit, k * good_volume)
    #[view]
    public fun get_max_loan_amount(
        borrower_address: address,
        governance_address: address
    ): u64 acquires TrustScore {
        if (!exists<TrustScore>(borrower_address)) {
            return 0
        };

        let trust_score = borrow_global<TrustScore>(borrower_address);

        // During bootstrap period: use approved limit
        if (trust_score.total_loans < BOOTSTRAP_LOAN_COUNT) {
            return trust_score.approved_credit_limit
        };

        // After bootstrap: apply anti-gaming earned capacity check
        let k_bps = governance::get_trust_anti_gaming_k_bps(governance_address);
        let earned_capacity = (trust_score.good_volume * (k_bps as u128)) / (10000 * SCALE);
        let earned_capacity_u64 = (earned_capacity as u64);

        // Return minimum of approved limit and earned capacity
        if (trust_score.approved_credit_limit < earned_capacity_u64) {
            trust_score.approved_credit_limit
        } else {
            earned_capacity_u64
        }
    }

    /// Check if loan amount is within earned capacity (called before draw)
    public fun check_loan_capacity(
        borrower_address: address,
        loan_amount: u64,
        governance_address: address
    ) acquires TrustScore {
        let max_allowed = get_max_loan_amount(borrower_address, governance_address);
        assert!(loan_amount <= max_allowed, E_EXCEEDS_EARNED_CAPACITY);
    }

    /// Get current trust score
    #[view]
    public fun get_trust_score(
        borrower_address: address,
        governance_address: address
    ): u64 acquires TrustScore {
        if (!exists<TrustScore>(borrower_address)) {
            return 0
        };

        let trust_score = borrow_global<TrustScore>(borrower_address);
        calculate_trust_score_internal(trust_score, governance_address)
    }

    /// Check if borrower is eligible for standard credit (score >= 60)
    #[view]
    public fun is_eligible_for_standard_credit(
        borrower_address: address,
        governance_address: address
    ): bool acquires TrustScore {
        let score = get_trust_score(borrower_address, governance_address);
        score >= CUTOFF_SCORE_STANDARD
    }

    /// Check if borrower is eligible for prefund credit (score >= 95)
    #[view]
    public fun is_eligible_for_prefund_credit(
        borrower_address: address,
        governance_address: address
    ): bool acquires TrustScore {
        let score = get_trust_score(borrower_address, governance_address);
        score >= CUTOFF_SCORE_PREFUND
    }

    /// Get detailed trust score breakdown
    #[view]
    public fun get_trust_score_details(
        borrower_address: address,
        governance_address: address
    ): (u64, u64, u64, u64, u64, u64, u64, u64) acquires TrustScore {
        assert!(exists<TrustScore>(borrower_address), E_TRUST_SCORE_NOT_FOUND);
        let trust_score = borrow_global<TrustScore>(borrower_address);

        let current_score = calculate_trust_score_internal(trust_score, governance_address);

        // Calculate max loan inline to avoid double borrow
        let max_loan = if (trust_score.total_loans < BOOTSTRAP_LOAN_COUNT) {
            trust_score.approved_credit_limit
        } else {
            let k_bps = governance::get_trust_anti_gaming_k_bps(governance_address);
            let earned_capacity = (trust_score.good_volume * (k_bps as u128)) / (10000 * SCALE);
            let earned_capacity_u64 = (earned_capacity as u64);
            if (trust_score.approved_credit_limit < earned_capacity_u64) {
                trust_score.approved_credit_limit
            } else {
                earned_capacity_u64
            }
        };

        (
            current_score,
            trust_score.total_loans,
            trust_score.on_time_count,
            trust_score.late_count,
            trust_score.default_count,
            trust_score.approved_credit_limit,
            max_loan,
            trust_score.created_at
        )
    }

    /// Get volume data (scaled amounts)
    #[view]
    public fun get_volume_data(
        borrower_address: address
    ): (u128, u128, u128) acquires TrustScore {
        assert!(exists<TrustScore>(borrower_address), E_TRUST_SCORE_NOT_FOUND);
        let trust_score = borrow_global<TrustScore>(borrower_address);

        (
            trust_score.good_volume / SCALE,  // Return in regular units
            trust_score.late_volume / SCALE,
            trust_score.default_volume / SCALE
        )
    }

    /// Admin function to update approved credit limit
    public entry fun update_approved_credit_limit(
        admin: &signer,
        borrower_address: address,
        new_limit: u64
    ) acquires TrustScore, TrustScoreRegistry {
        let admin_addr = signer::address_of(admin);

        // Verify admin
        let registry = borrow_global<TrustScoreRegistry>(admin_addr);
        assert!(admin_addr == registry.admin_address, E_NOT_AUTHORIZED);

        assert!(exists<TrustScore>(borrower_address), E_TRUST_SCORE_NOT_FOUND);
        let trust_score = borrow_global_mut<TrustScore>(borrower_address);

        trust_score.approved_credit_limit = new_limit;
    }

    /// Get bootstrap loan count threshold
    #[view]
    public fun get_bootstrap_threshold(): u64 {
        BOOTSTRAP_LOAN_COUNT
    }

    /// Get status constants
    #[view]
    public fun get_status_on_time(): u8 { STATUS_ON_TIME }

    #[view]
    public fun get_status_late(): u8 { STATUS_LATE }

    #[view]
    public fun get_status_default(): u8 { STATUS_DEFAULT }
}
