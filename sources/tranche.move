module kach::tranche {
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use kach::pool;
    use kach::governance;

    /// Identifier used when referring to the senior tranche.
    const TRANCHE_SENIOR: u8 = 0;
    /// Identifier used when referring to the junior tranche.
    const TRANCHE_JUNIOR: u8 = 1;

    /// Error when a caller lacks the privileges to execute tranche operations.
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Error when an invalid tranche identifier is supplied.
    const E_INVALID_TRANCHE: u64 = 2;
    /// Error when a tranche does not have enough capital to fulfill an action.
    const E_INSUFFICIENT_FUNDS: u64 = 3;

    /// Maximum share of capital that the junior tranche can lose (basis points).
    const JUNIOR_MAX_LOSS_BPS: u64 = 8000;
    /// Maximum share of capital that the senior tranche can lose (basis points).
    const SENIOR_MAX_LOSS_BPS: u64 = 2000;

    /// Protocol fee percentage (7% of gross interest per documentation)
    const PROTOCOL_FEE_BPS: u64 = 700; // 7%

    /// Events
    #[event]
    struct YieldDistributed has drop, store {
        pool_address: address,
        total_interest: u64,
        protocol_reserve_share: u64,
        senior_share: u64,
        junior_share: u64,
        timestamp: u64
    }

    #[event]
    struct LossAllocated has drop, store {
        pool_address: address,
        total_loss: u64,
        protocol_reserve_absorbed: u64,
        junior_absorbed: u64,
        senior_absorbed: u64,
        timestamp: u64
    }

    #[event]
    struct NAVUpdated has drop, store {
        pool_address: address,
        tranche: u8,
        old_multiplier: u128,
        new_multiplier: u128,
        timestamp: u64
    }

    /// Distribute yield from interest to tranches
    /// Called after PRT repayment
    /// Uses dynamic capital-weighted distribution per documentation:
    /// - Multipliers calculated based on actual pool composition
    /// - Junior multiplier = 1.0 + (protection_ratio × base_risk_premium)
    /// - Senior multiplier = 1.0 - (junior_ratio × base_risk_premium)
    /// - Protocol fee: 7% of gross interest
    public fun distribute_yield<FA>(
        pool_address: address,
        total_interest: u64,
        governance_address: address
    ) {
        // Calculate protocol reserve share (7% per documentation)
        let protocol_share = (total_interest as u128) * (PROTOCOL_FEE_BPS as u128) / 10000;
        let protocol_share_u64 = (protocol_share as u64);

        // Add to protocol reserve
        pool::add_to_reserve<FA>(pool_address, protocol_share_u64);

        // Remaining yield for tranches after protocol fee
        let tranche_yield = total_interest - protocol_share_u64;

        // Get actual tranche deposits
        let senior_deposits = pool::get_tranche_deposits<FA>(pool_address, TRANCHE_SENIOR);
        let junior_deposits = pool::get_tranche_deposits<FA>(pool_address, TRANCHE_JUNIOR);

        // Get base risk premium from governance (e.g., 3000 bps = 30% = 0.3)
        let base_risk_premium_bps = governance::get_base_risk_premium_bps(governance_address);

        // Calculate dynamic multipliers based on pool composition
        // Protection ratio = how many dollars of senior each junior dollar protects
        // Junior multiplier = 1.0 + (protection_ratio × base_risk_premium)
        // Senior multiplier = 1.0 - (inverse_ratio × base_risk_premium)

        let senior_share: u64;
        let junior_share: u64;

        if (senior_deposits == 0 && junior_deposits == 0) {
            // No deposits, no distribution
            senior_share = 0;
            junior_share = 0;
        } else if (junior_deposits == 0) {
            // Only senior depositors, they get all yield
            senior_share = tranche_yield;
            junior_share = 0;
        } else if (senior_deposits == 0) {
            // Only junior depositors, they get all yield
            senior_share = 0;
            junior_share = tranche_yield;
        } else {
            // Both tranches have deposits, calculate dynamic weights
            // Using scaled math to avoid decimals: multiply by 10000 for precision

            // protection_ratio = senior / junior (scaled by 10000)
            let protection_ratio_scaled = (senior_deposits as u128) * 10000 / (junior_deposits as u128);

            // junior_multiplier = 1.0 + (protection_ratio × base_risk_premium)
            // = 10000 + (protection_ratio_scaled × base_risk_premium_bps / 10000)
            let junior_multiplier = 10000 + (protection_ratio_scaled * (base_risk_premium_bps as u128) / 10000);

            // inverse_ratio = junior / senior (scaled by 10000)
            let inverse_ratio_scaled = (junior_deposits as u128) * 10000 / (senior_deposits as u128);

            // senior_multiplier = 1.0 - (inverse_ratio × base_risk_premium)
            // = 10000 - (inverse_ratio_scaled × base_risk_premium_bps / 10000)
            let senior_multiplier_calc = (inverse_ratio_scaled * (base_risk_premium_bps as u128) / 10000);
            let senior_multiplier = if (10000 > senior_multiplier_calc) {
                10000 - senior_multiplier_calc
            } else {
                1 // Minimum 0.0001× to avoid zero division
            };

            // Calculate weighted capital (scaled by 10000)
            let senior_weight = (senior_deposits as u128) * senior_multiplier;
            let junior_weight = (junior_deposits as u128) * junior_multiplier;
            let total_weight = senior_weight + junior_weight;

            // Distribute yield proportionally by weighted capital
            senior_share = ((tranche_yield as u128) * senior_weight / total_weight as u64);
            junior_share = ((tranche_yield as u128) * junior_weight / total_weight as u64);
        };

        // Update NAV multipliers for each tranche
        update_nav_for_yield<FA>(
            pool_address,
            TRANCHE_SENIOR,
            senior_share
        );

        update_nav_for_yield<FA>(
            pool_address,
            TRANCHE_JUNIOR,
            junior_share
        );

        event::emit(
            YieldDistributed {
                pool_address,
                total_interest,
                protocol_reserve_share: protocol_share_u64,
                senior_share,
                junior_share,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Allocate losses across tranches using waterfall
    /// Per documentation (tranches.mdx):
    /// 1. Protocol Reserve absorbs first
    /// 2. Junior tranche (up to 80% of junior capital)
    /// 3. Senior tranche (up to 20% of senior capital, if needed)
    public fun allocate_loss<FA>(pool_address: address, total_loss: u64) {
        let remaining_loss = total_loss;

        // Step 0: Protocol reserve absorbs first
        let (_, _, protocol_reserve_balance, _, _, _) =
            pool::get_pool_stats<FA>(pool_address);

        let protocol_absorbed =
            if (protocol_reserve_balance >= remaining_loss) {
                remaining_loss
            } else {
                protocol_reserve_balance
            };

        remaining_loss -= protocol_absorbed;

        // Deduct from protocol reserve
        if (protocol_absorbed > 0) {
            pool::deduct_from_reserve<FA>(pool_address, protocol_absorbed);
        };

        let junior_absorbed = 0u64;
        let senior_absorbed = 0u64;

        if (remaining_loss > 0) {
            // Step 1: Junior tranche absorbs (up to 80% of junior deposits)
            (remaining_loss, junior_absorbed) = absorb_loss_in_tranche<FA>(
                pool_address,
                TRANCHE_JUNIOR,
                remaining_loss,
                JUNIOR_MAX_LOSS_BPS
            );
        };

        if (remaining_loss > 0) {
            // Step 2: Senior tranche absorbs (up to 20% of senior deposits)
            (_, senior_absorbed) = absorb_loss_in_tranche<FA>(
                pool_address,
                TRANCHE_SENIOR,
                remaining_loss,
                SENIOR_MAX_LOSS_BPS
            );
            // If still remaining loss, protocol is insolvent
            // This should trigger emergency procedures
        };

        event::emit(
            LossAllocated {
                pool_address,
                total_loss,
                protocol_reserve_absorbed: protocol_absorbed,
                junior_absorbed,
                senior_absorbed,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Internal: Absorb loss in a specific tranche
    /// Returns (remaining_loss, absorbed_amount)
    fun absorb_loss_in_tranche<FA>(
        pool_address: address,
        tranche: u8,
        loss_amount: u64,
        max_loss_bps: u64
    ): (u64, u64) {
        // Get tranche deposits from pool
        let tranche_deposits = pool::get_tranche_deposits<FA>(pool_address, tranche);

        // Max loss this tranche can absorb
        let max_absorbable = (tranche_deposits as u128) * (max_loss_bps as u128) / 10000;
        let max_absorbable_u64 = (max_absorbable as u64);

        let absorbed =
            if (loss_amount <= max_absorbable_u64) {
                loss_amount
            } else {
                max_absorbable_u64
            };

        let remaining = loss_amount - absorbed;

        // Update NAV multiplier (decrease for loss)
        update_nav_for_loss<FA>(pool_address, tranche, absorbed);

        (remaining, absorbed)
    }

    /// Update NAV multiplier when yield is distributed
    fun update_nav_for_yield<FA>(
        pool_address: address, tranche: u8, yield_amount: u64
    ) {
        let old_multiplier = pool::get_nav_multiplier<FA>(pool_address, tranche);

        // Get tranche deposits from pool module
        let tranche_deposits = pool::get_tranche_deposits<FA>(pool_address, tranche);

        if (tranche_deposits == 0) { return };

        // New multiplier = old_multiplier * (1 + yield/deposits)
        // NAV multipliers are scaled by 1e18
        let yield_ratio =
            (yield_amount as u128) * 1_000_000_000_000_000_000
                / (tranche_deposits as u128);
        let new_multiplier = old_multiplier + yield_ratio;

        pool::update_nav_multiplier<FA>(pool_address, tranche, new_multiplier);

        event::emit(
            NAVUpdated {
                pool_address,
                tranche,
                old_multiplier,
                new_multiplier,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Update NAV multiplier when loss is allocated
    fun update_nav_for_loss<FA>(
        pool_address: address, tranche: u8, loss_amount: u64
    ) {
        let old_multiplier = pool::get_nav_multiplier<FA>(pool_address, tranche);

        // Get tranche deposits from pool module
        let tranche_deposits = pool::get_tranche_deposits<FA>(pool_address, tranche);

        if (tranche_deposits == 0) { return };

        // New multiplier = old_multiplier * (1 - loss/deposits)
        let loss_ratio =
            (loss_amount as u128) * 1_000_000_000_000_000_000
                / (tranche_deposits as u128);

        // Ensure we don't go negative
        let new_multiplier =
            if (old_multiplier > loss_ratio) {
                old_multiplier - loss_ratio
            } else { 0 };

        pool::update_nav_multiplier<FA>(pool_address, tranche, new_multiplier);

        event::emit(
            NAVUpdated {
                pool_address,
                tranche,
                old_multiplier,
                new_multiplier,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Calculate current dynamic multipliers for a pool based on composition
    /// Returns (senior_multiplier_bps, junior_multiplier_bps) scaled by 10000
    /// Example: If senior multiplier is 0.925, returns 9250
    #[view]
    public fun calculate_current_multipliers<FA>(
        pool_address: address,
        governance_address: address
    ): (u64, u64) {
        let senior_deposits = pool::get_tranche_deposits<FA>(pool_address, TRANCHE_SENIOR);
        let junior_deposits = pool::get_tranche_deposits<FA>(pool_address, TRANCHE_JUNIOR);
        let base_risk_premium_bps = governance::get_base_risk_premium_bps(governance_address);

        if (junior_deposits == 0) {
            return (10000, 0) // Senior gets 1.0×, junior N/A
        };

        if (senior_deposits == 0) {
            return (0, 10000) // Junior gets 1.0×, senior N/A
        };

        // protection_ratio = senior / junior (scaled by 10000)
        let protection_ratio_scaled = (senior_deposits as u128) * 10000 / (junior_deposits as u128);

        // junior_multiplier = 1.0 + (protection_ratio × base_risk_premium)
        let junior_multiplier = 10000 + (protection_ratio_scaled * (base_risk_premium_bps as u128) / 10000);

        // inverse_ratio = junior / senior (scaled by 10000)
        let inverse_ratio_scaled = (junior_deposits as u128) * 10000 / (senior_deposits as u128);

        // senior_multiplier = 1.0 - (inverse_ratio × base_risk_premium)
        let senior_multiplier_calc = (inverse_ratio_scaled * (base_risk_premium_bps as u128) / 10000);
        let senior_multiplier = if (10000 > senior_multiplier_calc) {
            10000 - senior_multiplier_calc
        } else {
            1
        };

        ((senior_multiplier as u64), (junior_multiplier as u64))
    }

    /// Get max loss a tranche can absorb (in bps of tranche capital)
    #[view]
    public fun get_max_loss_bps(tranche: u8): u64 {
        if (tranche == TRANCHE_JUNIOR) {
            JUNIOR_MAX_LOSS_BPS
        } else {
            SENIOR_MAX_LOSS_BPS
        }
    }

    /// Get protocol fee in basis points (7%)
    #[view]
    public fun get_protocol_fee_bps(): u64 {
        PROTOCOL_FEE_BPS
    }
}

