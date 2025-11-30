module kach::trust_score {
    use std::signer;
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use kach::governance;

    /// Error when a signer without admin rights attempts to mutate trust scores.
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Error when initializing a score for an attestator-pool pair that already has one.
    const E_TRUST_SCORE_EXISTS: u64 = 2;
    /// Error when attempting to access a non-existent trust score record.
    const E_TRUST_SCORE_NOT_FOUND: u64 = 3;
    /// Error when loan amount exceeds earned capacity (anti-gaming check).
    const E_EXCEEDS_EARNED_CAPACITY: u64 = 4;
    /// Error when attestator is not approved for this pool.
    const E_NOT_APPROVED_FOR_POOL: u64 = 5;

    /// Bootstrap period: first N loans exempt from anti-gaming earned capacity check
    const BOOTSTRAP_LOAN_COUNT: u64 = 10;

    /// Repayment status constants
    const STATUS_ON_TIME: u8 = 0;
    const STATUS_LATE: u8 = 1;
    const STATUS_DEFAULT: u8 = 2;

    /// Minimum trust score required for standard credit draws (60/100)
    const MIN_TRUST_SCORE_TO_DRAW: u64 = 60;

    /// Minimum trust score required for prefunded credit lines (95/100)
    const MIN_TRUST_SCORE_FOR_PREFUND: u64 = 95;

    /// Pool-specific Trust Score for an attestator
    /// Tracks performance within a specific pool (asset-specific)
    /// Stored at a unique address derived from (attestator, pool) pair
    struct TrustScore has key {
        attestator_address: address,
        pool_address: address,

        // Volume tracking in native token amounts (no scaling/normalization)
        // Uses actual token decimals from pool's fungible asset
        good_volume: u128, // Sum of on-time repayments (with time decay)
        late_volume: u128, // Sum of late repayments (with time decay)
        default_volume: u128, // Sum of defaulted amounts (with time decay)

        // Count tracking
        on_time_count: u64,
        late_count: u64,
        default_count: u64,
        total_loans: u64, // Total loans ever drawn from this pool

        // Pool-specific approval and limits
        approved_credit_limit: u64, // Max credit for this pool (in pool's native token)
        is_approved: bool, // Is attestator approved for this pool?

        // Decay tracking
        last_update: u64, // Timestamp of last repayment update

        // Timestamps
        created_at: u64
    }

    /// Global registry tracking all trust scores
    struct TrustScoreRegistry has key {
        admin_address: address,
        total_scores: u64 // Total number of (attestator, pool) trust scores
    }

    /// Events
    #[event]
    struct TrustScoreInitialized has drop, store {
        attestator: address,
        pool_address: address,
        approved_credit_limit: u64,
        timestamp: u64
    }

    #[event]
    struct TrustScoreUpdated has drop, store {
        attestator: address,
        pool_address: address,
        old_score: u64,
        new_score: u64,
        status: u8, // STATUS_ON_TIME, STATUS_LATE, or STATUS_DEFAULT
        loan_amount: u64,
        timestamp: u64
    }

    #[event]
    struct AttestatorApprovedForPool has drop, store {
        attestator: address,
        pool_address: address,
        approved_by: address,
        timestamp: u64
    }

    #[event]
    struct AttestatorRevokedFromPool has drop, store {
        attestator: address,
        pool_address: address,
        revoked_by: address,
        timestamp: u64
    }

    /// Initialize the global trust score registry
    public entry fun initialize_registry(admin: &signer) {
        let admin_addr = signer::address_of(admin);

        let registry = TrustScoreRegistry { admin_address: admin_addr, total_scores: 0 };

        move_to(admin, registry);
    }

    /// Initialize trust score for an attestator in a specific pool
    /// Called by pool admin when approving an attestator
    public fun initialize_trust_score(
        admin: &signer,
        attestator_address: address,
        pool_address: address,
        approved_credit_limit: u64,
        governance_address: address
    ) acquires TrustScoreRegistry {
        let admin_addr = signer::address_of(admin);

        // Verify admin authorization
        let registry = borrow_global_mut<TrustScoreRegistry>(governance_address);
        assert!(admin_addr == registry.admin_address, E_NOT_AUTHORIZED);

        // Verify trust score doesn't already exist for this (attestator, pool) pair
        assert!(
            !exists<TrustScore>(attestator_address),
            E_TRUST_SCORE_EXISTS
        );

        // Create trust score at attestator's address
        // Note: In production, you might want to use a separate address space
        // derived from hash(attestator_address, pool_address) for true separation
        let trust_score = TrustScore {
            attestator_address,
            pool_address,
            good_volume: 0,
            late_volume: 0,
            default_volume: 0,
            on_time_count: 0,
            late_count: 0,
            default_count: 0,
            total_loans: 0,
            approved_credit_limit,
            is_approved: true,
            last_update: timestamp::now_seconds(),
            created_at: timestamp::now_seconds()
        };

        move_to(admin, trust_score);

        registry.total_scores += 1;

        event::emit(
            TrustScoreInitialized {
                attestator: attestator_address,
                pool_address,
                approved_credit_limit,
                timestamp: timestamp::now_seconds()
            }
        );

        event::emit(
            AttestatorApprovedForPool {
                attestator: attestator_address,
                pool_address,
                approved_by: admin_addr,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Approve an existing attestator for a new pool
    public entry fun approve_for_pool(
        admin: &signer,
        attestator_address: address,
        pool_address: address,
        approved_credit_limit: u64,
        governance_address: address
    ) acquires TrustScore, TrustScoreRegistry {
        let admin_addr = signer::address_of(admin);

        let registry = borrow_global<TrustScoreRegistry>(governance_address);
        assert!(admin_addr == registry.admin_address, E_NOT_AUTHORIZED);

        // If trust score exists, update it; otherwise create new one
        if (exists<TrustScore>(attestator_address)) {
            let score = borrow_global_mut<TrustScore>(attestator_address);
            score.is_approved = true;
            score.approved_credit_limit = approved_credit_limit;
        } else {
            initialize_trust_score(
                admin,
                attestator_address,
                pool_address,
                approved_credit_limit,
                governance_address
            );
            return
        };

        event::emit(
            AttestatorApprovedForPool {
                attestator: attestator_address,
                pool_address,
                approved_by: admin_addr,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Revoke attestator approval for a pool
    public entry fun revoke_from_pool(
        admin: &signer,
        attestator_address: address,
        pool_address: address,
        governance_address: address
    ) acquires TrustScore, TrustScoreRegistry {
        let admin_addr = signer::address_of(admin);

        let registry = borrow_global<TrustScoreRegistry>(governance_address);
        assert!(admin_addr == registry.admin_address, E_NOT_AUTHORIZED);

        assert!(exists<TrustScore>(attestator_address), E_TRUST_SCORE_NOT_FOUND);

        let score = borrow_global_mut<TrustScore>(attestator_address);
        score.is_approved = false;

        event::emit(
            AttestatorRevokedFromPool {
                attestator: attestator_address,
                pool_address,
                revoked_by: admin_addr,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Update trust score after a repayment event
    /// Called by credit engine or pool after settlement
    public fun update_trust_score(
        attestator_address: address,
        pool_address: address,
        loan_amount: u64, // Amount in pool's native token (no conversion needed)
        status: u8, // STATUS_ON_TIME, STATUS_LATE, or STATUS_DEFAULT
        governance_address: address
    ) acquires TrustScore {
        assert!(exists<TrustScore>(attestator_address), E_TRUST_SCORE_NOT_FOUND);

        let score = borrow_global_mut<TrustScore>(attestator_address);

        // Verify this score is for the correct pool
        assert!(score.pool_address == pool_address, E_NOT_APPROVED_FOR_POOL);

        let old_trust_score = calculate_trust_score_internal(score, governance_address);

        // Apply time decay to existing volumes
        let current_time = timestamp::now_seconds();
        apply_time_decay(score, current_time, governance_address);

        // Update volumes and counts based on payment status
        let loan_amount_u128 = (loan_amount as u128);

        if (status == STATUS_ON_TIME) {
            score.good_volume += loan_amount_u128;
            score.on_time_count += 1;
        } else if (status == STATUS_LATE) {
            score.late_volume += loan_amount_u128;
            score.late_count += 1;
        } else if (status == STATUS_DEFAULT) {
            score.default_volume += loan_amount_u128;
            score.default_count += 1;
        };

        score.total_loans += 1;
        score.last_update = current_time;

        let new_trust_score = calculate_trust_score_internal(score, governance_address);

        event::emit(
            TrustScoreUpdated {
                attestator: attestator_address,
                pool_address,
                old_score: old_trust_score,
                new_score: new_trust_score,
                status,
                loan_amount,
                timestamp: current_time
            }
        );
    }

    /// Apply time-based decay to volumes
    /// Older repayments have less weight in trust score calculation
    fun apply_time_decay(
        score: &mut TrustScore, current_time: u64, governance_address: address
    ) {
        let time_since_update = current_time - score.last_update;

        // Get decay parameters from governance
        let decay_rate_bps =
            governance::get_trust_score_decay_rate_bps(governance_address);
        let decay_period_seconds =
            governance::get_trust_score_decay_period_seconds(governance_address);

        // Only apply decay if enough time has passed
        if (time_since_update < decay_period_seconds) { return };

        // Calculate decay multiplier: decay_rate_bps / 10000 per period
        // Number of periods = time_since_update / decay_period_seconds
        let periods = time_since_update / decay_period_seconds;

        // Decay multiplier = (1 - decay_rate)^periods
        // Simplified: multiply by (10000 - decay_rate_bps) / 10000 for each period
        let decay_factor = 10000 - decay_rate_bps;

        let i = 0;
        while (i < periods && i < 100) { // Cap at 100 periods to prevent overflow
            score.good_volume = (score.good_volume * (decay_factor as u128)) / 10000;
            score.late_volume = (score.late_volume * (decay_factor as u128)) / 10000;
            score.default_volume = (score.default_volume * (decay_factor as u128)) / 10000;
            i += 1;
        };
    }

    /// Calculate trust score (internal, returns 0-100)
    fun calculate_trust_score_internal(
        score: &TrustScore, governance_address: address
    ): u64 {
        let total_volume = score.good_volume + score.late_volume + score.default_volume;

        // If no history, return neutral score
        if (total_volume == 0) {
            return 50
        };

        // Get weight parameters from governance
        let on_time_weight =
            governance::get_trust_score_on_time_weight(governance_address);
        let late_weight = governance::get_trust_score_late_weight(governance_address);
        let default_weight =
            governance::get_trust_score_default_weight(governance_address);

        // Calculate weighted score (0-100 scale)
        // Score = (good_volume * on_time_weight - late_volume * late_weight - default_volume * default_weight) / total_volume
        // Normalized to 0-100 range

        let positive_contribution = (score.good_volume * (on_time_weight as u128)) / 100;
        let negative_contribution =
            (score.late_volume * (late_weight as u128)) / 100
                + (score.default_volume * (default_weight as u128)) / 100;

        let net_score =
            if (positive_contribution > negative_contribution) {
                ((positive_contribution - negative_contribution) * 100) / total_volume
            } else { 0 };

        // Clamp to 0-100
        if (net_score > 100) { 100 }
        else {
            (net_score as u64)
        }
    }

    /// Get maximum loan amount allowed (anti-gaming check)
    /// During bootstrap period (first N loans): returns approved_credit_limit
    /// After bootstrap: returns min(approved_limit, k * good_volume)
    #[view]
    public fun get_max_loan_amount(
        attestator_address: address, pool_address: address, governance_address: address
    ): u64 acquires TrustScore {
        assert!(exists<TrustScore>(attestator_address), E_TRUST_SCORE_NOT_FOUND);

        let score = borrow_global<TrustScore>(attestator_address);
        assert!(score.pool_address == pool_address, E_NOT_APPROVED_FOR_POOL);
        assert!(score.is_approved, E_NOT_APPROVED_FOR_POOL);

        // During bootstrap period, use approved limit
        if (score.total_loans < BOOTSTRAP_LOAN_COUNT) {
            return score.approved_credit_limit
        };

        // After bootstrap: max loan = min(approved_limit, multiplier * good_volume)
        let multiplier = governance::get_trust_score_loan_multiplier(governance_address);
        let earned_capacity = ((score.good_volume * (multiplier as u128)) / 100 as u64);

        if (earned_capacity < score.approved_credit_limit) {
            earned_capacity
        } else {
            score.approved_credit_limit
        }
    }

    /// Get current trust score for an attestator in a specific pool
    #[view]
    public fun get_trust_score(
        attestator_address: address, pool_address: address, governance_address: address
    ): u64 acquires TrustScore {
        if (!exists<TrustScore>(attestator_address)) {
            return 0
        };

        let score = borrow_global<TrustScore>(attestator_address);

        // Verify correct pool
        if (score.pool_address != pool_address) {
            return 0
        };

        if (!score.is_approved) {
            return 0
        };

        calculate_trust_score_internal(score, governance_address)
    }

    /// Check if attestator is eligible for standard credit (score >= 60)
    #[view]
    public fun is_eligible_for_standard_credit(
        attestator_address: address, pool_address: address, governance_address: address
    ): bool acquires TrustScore {
        let score = get_trust_score(
            attestator_address, pool_address, governance_address
        );
        score >= MIN_TRUST_SCORE_TO_DRAW
    }

    /// Check if attestator is eligible for prefund credit (score >= 95)
    #[view]
    public fun is_eligible_for_prefund_credit(
        attestator_address: address, pool_address: address, governance_address: address
    ): bool acquires TrustScore {
        let score = get_trust_score(
            attestator_address, pool_address, governance_address
        );
        score >= MIN_TRUST_SCORE_FOR_PREFUND
    }

    /// Check if attestator is approved for a specific pool
    #[view]
    public fun is_approved_for_pool(
        attestator_address: address, pool_address: address
    ): bool acquires TrustScore {
        if (!exists<TrustScore>(attestator_address)) {
            return false
        };

        let score = borrow_global<TrustScore>(attestator_address);
        score.pool_address == pool_address && score.is_approved
    }

    /// Get detailed trust score breakdown for a pool
    #[view]
    public fun get_trust_score_details(
        attestator_address: address, pool_address: address, governance_address: address
    ): (
        u64, // current_score
        u64, // total_loans
        u64, // on_time_count
        u64, // late_count
        u64, // default_count
        u128, // good_volume
        u128, // late_volume
        u128, // default_volume
        u64, // approved_credit_limit
        bool // is_approved
    ) acquires TrustScore {
        if (!exists<TrustScore>(attestator_address)) {
            return (0, 0, 0, 0, 0, 0, 0, 0, 0, false)
        };

        let score = borrow_global<TrustScore>(attestator_address);

        if (score.pool_address != pool_address) {
            return (0, 0, 0, 0, 0, 0, 0, 0, 0, false)
        };

        let current_score = calculate_trust_score_internal(score, governance_address);

        (
            current_score,
            score.total_loans,
            score.on_time_count,
            score.late_count,
            score.default_count,
            score.good_volume,
            score.late_volume,
            score.default_volume,
            score.approved_credit_limit,
            score.is_approved
        )
    }

    /// Get volume data (native token amounts, no scaling)
    #[view]
    public fun get_volume_data(
        attestator_address: address, pool_address: address
    ): (u128, u128, u128) acquires TrustScore {
        if (!exists<TrustScore>(attestator_address)) {
            return (0, 0, 0)
        };

        let score = borrow_global<TrustScore>(attestator_address);

        if (score.pool_address != pool_address) {
            return (0, 0, 0)
        };

        (score.good_volume, score.late_volume, score.default_volume)
    }

    /// Get minimum trust score for standard draws
    public fun min_trust_score_to_draw(): u64 {
        MIN_TRUST_SCORE_TO_DRAW
    }

    /// Get minimum trust score for prefunded lines
    public fun min_trust_score_for_prefund(): u64 {
        MIN_TRUST_SCORE_FOR_PREFUND
    }

    /// Get bootstrap loan count threshold
    #[view]
    public fun get_bootstrap_loan_count(): u64 {
        BOOTSTRAP_LOAN_COUNT
    }

    /// Get status constants
    #[view]
    public fun get_status_on_time(): u8 {
        STATUS_ON_TIME
    }

    #[view]
    public fun get_status_late(): u8 {
        STATUS_LATE
    }

    #[view]
    public fun get_status_default(): u8 {
        STATUS_DEFAULT
    }
}

